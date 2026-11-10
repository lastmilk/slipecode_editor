// 会员订单 + 微信支付（JSAPI）
//
// 流程：
//   App  POST /api/billing/wechat/order            创建订单，返回支付页链接
//   App  打开 https://ser1996.niav.cn/pay?order=…  微信内置浏览器中完成支付
//   页面 公众号网页授权(snsapi_base) → openid → JSAPI 下单 → WeixinJSBridge 调起支付
//   微信 POST /api/pay/wechat/notify               回调验签 → 会员/积分到账
//
// 支付页域名必须是 ser1996.niav.cn（微信支付授权目录 / 网页授权域名）。

import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto';

import {
  JWT_SECRET,
  MEMBERSHIP_CYCLES,
  MEMBERSHIP_PLANS,
  activeMembership,
  addMonths,
  billingCycleById,
  membershipPlanById,
  membershipSnapshot,
  wechatPayConfig,
  wechatPayReady,
} from '../config.js';
import { bumpStat, getDb, saveDb } from '../db.js';
import { readJson, readRaw, remoteIp, sendJson } from '../http.js';
import { requireAdmin, requireUser } from '../security.js';
import {
  buildJsapiPayParams,
  buildWechatOauthUrl,
  createJsapiPrepay,
  exchangeCodeForOpenid,
  parseWechatNotify,
  queryOrder,
} from '../services/wechat_pay.js';
import { applyCredits, getCredits, settleMembershipCredits } from './me.js';

const OPENID_COOKIE = 'slipe_wx_openid';
const OPENID_COOKIE_MAX_AGE = 60 * 60 * 24 * 30;
const PREPAY_REUSE_MS = 2 * 60 * 60 * 1000;
const MAX_PENDING_ORDERS = 5;
const STATE_TTL_MS = 10 * 60 * 1000;

// ---------------------------------------------------------------------------
// 通用工具
// ---------------------------------------------------------------------------

function pad2(n) {
  return String(n).padStart(2, '0');
}

/** 商户订单号：S + yyyyMMddHHmmss + 8 位随机（25 字符，符合 6-32 位要求） */
function newOutTradeNo() {
  const d = new Date();
  const ts =
    `${d.getFullYear()}${pad2(d.getMonth() + 1)}${pad2(d.getDate())}` +
    `${pad2(d.getHours())}${pad2(d.getMinutes())}${pad2(d.getSeconds())}`;
  return `S${ts}${randomBytes(4).toString('hex').toUpperCase()}`;
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;',
  })[ch]);
}

function yuan(fen) {
  return (Number(fen || 0) / 100).toFixed(2);
}

function parseCookies(req) {
  const out = {};
  const raw = String(req.headers.cookie || '');
  for (const pair of raw.split(';')) {
    const index = pair.indexOf('=');
    if (index <= 0) continue;
    const key = pair.slice(0, index).trim();
    const value = pair.slice(index + 1).trim();
    if (!key) continue;
    try {
      out[key] = decodeURIComponent(value);
    } catch {
      out[key] = value;
    }
  }
  return out;
}

function findOrder(outTradeNo) {
  return (getDb().payOrders || []).find((o) => o.outTradeNo === outTradeNo) || null;
}

function publicOrder(order) {
  return {
    outTradeNo: order.outTradeNo,
    planId: order.planId,
    planName: order.planName,
    cycleId: order.cycleId,
    cycleName: order.cycleName,
    months: order.months,
    amount: order.amount,
    amountFen: order.amountFen,
    status: order.status,
    createdAt: order.createdAt,
    paidAt: order.paidAt || null,
    transactionId: order.transactionId || '',
  };
}

/** 支付页状态签名，防止 OAuth state 被伪造 */
function signState(orderNo) {
  const ts = Date.now();
  const sig = createHmac('sha256', JWT_SECRET)
    .update(`${orderNo}.${ts}`)
    .digest('hex')
    .slice(0, 32);
  return `${orderNo}.${ts}.${sig}`;
}

function verifyState(state) {
  const parts = String(state || '').split('.');
  if (parts.length !== 3) return '';
  const [orderNo, tsText, sig] = parts;
  const ts = Number(tsText);
  if (!Number.isFinite(ts) || Math.abs(Date.now() - ts) > STATE_TTL_MS) return '';
  const expected = createHmac('sha256', JWT_SECRET)
    .update(`${orderNo}.${ts}`)
    .digest('hex')
    .slice(0, 32);
  if (sig.length !== expected.length) return '';
  try {
    if (!timingSafeEqual(Buffer.from(sig), Buffer.from(expected))) return '';
  } catch {
    return '';
  }
  return orderNo;
}

function sendHtml(res, status, html) {
  res.writeHead(status, {
    'Content-Type': 'text/html; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
  });
  res.end(html);
}

// ---------------------------------------------------------------------------
// 订单：用户下单
// ---------------------------------------------------------------------------

export async function handleCreateWechatOrder(req, res) {
  const user = requireUser(req);
  const body = await readJson(req);
  const plan = membershipPlanById(body.planId);
  const cycle = billingCycleById(body.cycleId || 'month');

  if (!plan || plan.free) {
    return sendJson(res, 400, { error: '请选择有效的付费档位' });
  }
  if (!cycle) {
    return sendJson(res, 400, { error: '请选择有效的付费周期' });
  }
  const price = Number(plan.prices?.[cycle.id] || 0);
  if (!(price > 0)) {
    return sendJson(res, 400, { error: '该档位暂未开放购买' });
  }
  if (!wechatPayReady()) {
    return sendJson(res, 503, {
      error: '微信支付尚未配置完成，请联系管理员',
      code: 'WECHAT_PAY_NOT_CONFIGURED',
    });
  }

  const db = getDb();
  if (!Array.isArray(db.payOrders)) db.payOrders = [];
  const now = Date.now();
  const recentPending = db.payOrders.filter(
    (o) =>
      o.userId === user.id &&
      o.status === 'pending' &&
      now - Date.parse(o.createdAt || 0) < 30 * 60 * 1000,
  );
  if (recentPending.length >= MAX_PENDING_ORDERS) {
    return sendJson(res, 429, { error: '待支付订单过多，请稍后再试' });
  }

  const amountFen = Math.round(price * 100);
  const order = {
    id: `po_${randomBytes(6).toString('hex')}`,
    outTradeNo: newOutTradeNo(),
    userId: user.id,
    userEmail: user.email,
    planId: plan.id,
    planName: plan.name,
    cycleId: cycle.id,
    cycleName: cycle.name,
    months: cycle.months,
    amount: price,
    amountFen,
    status: 'pending',
    prepayId: '',
    prepayAt: 0,
    createdAt: new Date(now).toISOString(),
    paidAt: null,
    transactionId: '',
    note: '',
  };
  db.payOrders.push(order);
  // 只保留最近 5000 条订单，避免 db.json 无限增长
  if (db.payOrders.length > 5000) {
    db.payOrders.splice(0, db.payOrders.length - 5000);
  }
  await saveDb();

  const cfg = wechatPayConfig();
  sendJson(res, 200, {
    ok: true,
    order: publicOrder(order),
    payUrl: `${cfg.pageBase}/pay?order=${encodeURIComponent(order.outTradeNo)}`,
    appId: cfg.appId,
  });
}

/** 用户查询订单（主动向微信查单并结算） */
export async function handleGetWechatOrder(req, res) {
  const user = requireUser(req);
  const url = new URL(req.url, 'http://localhost');
  const outTradeNo = String(url.searchParams.get('outTradeNo') || '').trim();
  const order = findOrder(outTradeNo);
  if (!order || order.userId !== user.id) {
    return sendJson(res, 404, { error: '订单不存在' });
  }

  let warning = '';
  if (order.status === 'pending') {
    // 客户端会轮询，这里做 4 秒节流，避免频繁请求微信查单接口
    const lastQueryAt = Number(order.lastQueryAt || 0);
    if (Date.now() - lastQueryAt >= 4000) {
      order.lastQueryAt = Date.now();
      try {
        const data = await queryOrder(order.outTradeNo);
        if (data.trade_state === 'SUCCESS') {
          await markOrderPaid({
            outTradeNo: order.outTradeNo,
            transactionId: data.transaction_id,
            amountTotal: data.amount?.total,
            source: 'query',
          });
        } else if (['CLOSED', 'REVOKED', 'PAYERROR'].includes(data.trade_state)) {
          order.status = 'closed';
          order.note = `微信支付状态：${data.trade_state}`;
          await saveDb();
        }
      } catch (err) {
        warning = err.message || '查单失败';
      }
    }
  }

  await settleMembershipCredits(user);
  sendJson(res, 200, {
    status: order.status,
    order: publicOrder(order),
    credits: getCredits(user),
    membership: membershipSnapshot(user),
    warning,
  });
}

// ---------------------------------------------------------------------------
// 订单：支付成功结算（幂等）
// ---------------------------------------------------------------------------

function activateMembership(user, order) {
  const plan = membershipPlanById(order.planId);
  if (!plan) return;
  const now = Date.now();
  const current = activeMembership(user);
  const base = current ? Date.parse(current.expiresAt) : now;
  const expiresAt = addMonths(base, order.months).toISOString();

  if (!current) {
    user.membership = {
      planId: plan.id,
      startedAt: new Date(now).toISOString(),
      expiresAt,
      nextCreditGrantAt: addMonths(now, 1).toISOString(),
      lastOrderNo: order.outTradeNo,
    };
    applyCredits(
      user,
      plan.monthlyCredits,
      'membership',
      `${plan.name} 会员开通 · 首月积分`,
    );
    return;
  }

  // 续费 / 升级：立即生效并延长有效期，月度积分按原节奏发放
  const changedPlan = current.planId !== plan.id;
  user.membership.planId = plan.id;
  user.membership.expiresAt = expiresAt;
  user.membership.lastOrderNo = order.outTradeNo;
  if (!user.membership.nextCreditGrantAt) {
    user.membership.nextCreditGrantAt = addMonths(now, 1).toISOString();
  }
  if (changedPlan) {
    order.note = `档位变更：${current.planId} → ${plan.id}`;
  }
}

/**
 * 标记订单已支付并入账（回调 / 主动查单共用）。
 * 幂等：重复调用不会重复发放。
 */
export async function markOrderPaid({
  outTradeNo,
  transactionId,
  amountTotal,
  source,
}) {
  const order = findOrder(outTradeNo);
  if (!order) return { ok: false, reason: 'not_found' };
  if (order.status === 'paid') {
    return { ok: true, duplicated: true, order };
  }
  if (order.status !== 'pending') {
    return { ok: false, reason: `order_${order.status}`, order };
  }

  const paidFen = Number(amountTotal);
  if (Number.isFinite(paidFen) && paidFen > 0 && paidFen !== order.amountFen) {
    order.status = 'mismatch';
    order.note = `金额不一致：应付 ${order.amountFen} 分，实付 ${paidFen} 分`;
    await saveDb();
    return { ok: false, reason: 'amount_mismatch', order };
  }

  const user = getDb().users.find((u) => u.id === order.userId);
  if (!user) {
    order.status = 'failed';
    order.note = '下单用户不存在';
    await saveDb();
    return { ok: false, reason: 'user_not_found', order };
  }

  order.status = 'paid';
  order.paidAt = new Date().toISOString();
  order.transactionId = String(transactionId || '');
  order.paidSource = source || '';
  activateMembership(user, order);

  bumpStat('payments');
  bumpStat('paymentFen', order.amountFen);
  await saveDb();
  return { ok: true, order, user };
}

// ---------------------------------------------------------------------------
// 微信支付回调
// ---------------------------------------------------------------------------

export async function handleWechatNotify(req, res) {
  let raw;
  try {
    raw = await readRaw(req, { limit: 512 * 1024 });
  } catch {
    return sendJson(res, 413, { code: 'FAIL', message: '请求体过大' });
  }

  let parsed;
  try {
    parsed = await parseWechatNotify(req.headers, raw);
  } catch (err) {
    console.warn('[wechat-pay] 回调验签/解密失败：', err.message);
    return sendJson(res, 401, { code: 'FAIL', message: '验签失败' });
  }

  if (parsed.eventType !== 'TRANSACTION.SUCCESS') {
    return sendJson(res, 200, { code: 'SUCCESS', message: '已接收' });
  }

  const tx = parsed.transaction || {};
  const cfg = wechatPayConfig();
  if (tx.mchid !== cfg.mchId || tx.appid !== cfg.appId) {
    console.warn('[wechat-pay] 回调商户信息不匹配：', tx.mchid, tx.appid);
    return sendJson(res, 200, { code: 'SUCCESS', message: '已接收' });
  }

  const result = await markOrderPaid({
    outTradeNo: tx.out_trade_no,
    transactionId: tx.transaction_id,
    amountTotal: tx.amount?.total,
    source: 'notify',
  });
  if (!result.ok) {
    console.warn('[wechat-pay] 订单入账失败：', tx.out_trade_no, result.reason);
    // 金额异常 / 订单不存在时返回成功，避免微信无限重试；由后台人工核对
    if (result.reason === 'amount_mismatch' || result.reason === 'not_found') {
      return sendJson(res, 200, { code: 'SUCCESS', message: '已接收' });
    }
    return sendJson(res, 500, { code: 'FAIL', message: '处理失败' });
  }
  return sendJson(res, 200, { code: 'SUCCESS', message: '成功' });
}

// ---------------------------------------------------------------------------
// 支付页面（ser1996.niav.cn/pay）
// ---------------------------------------------------------------------------

function pageShell({ title, body, script = '' }) {
  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<meta name="theme-color" content="#07c160">
<title>${escapeHtml(title)}</title>
<style>
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  html, body { margin: 0; height: 100%; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", Arial, sans-serif;
    background: #f2f4f7; color: #111; display: flex; align-items: center; justify-content: center;
    padding: 20px;
  }
  .card {
    width: 100%; max-width: 420px; background: #fff; border-radius: 18px; padding: 26px 22px 22px;
    box-shadow: 0 12px 32px rgba(17, 24, 39, .08);
  }
  .brand { display: flex; align-items: center; gap: 8px; font-size: 13px; color: #6b7280; margin-bottom: 18px; }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: #07c160; }
  .amount { font-size: 40px; font-weight: 700; letter-spacing: -.5px; margin: 4px 0 6px; }
  .amount small { font-size: 18px; font-weight: 600; margin-right: 2px; }
  .title { font-size: 15px; font-weight: 600; margin-bottom: 4px; }
  .meta { font-size: 12px; color: #8a8f99; word-break: break-all; }
  .divider { height: 1px; background: #eef0f3; margin: 18px 0; }
  .btn {
    width: 100%; border: 0; border-radius: 12px; padding: 14px 16px; font-size: 16px; font-weight: 600;
    background: #07c160; color: #fff; margin-top: 6px;
  }
  .btn:disabled { opacity: .55; }
  .btn.ghost { background: #f0f2f5; color: #374151; }
  .status { font-size: 13px; color: #6b7280; text-align: center; margin-top: 14px; min-height: 20px; }
  .status.ok { color: #07c160; font-weight: 600; }
  .status.err { color: #e5484d; }
  .linkbox {
    margin-top: 14px; padding: 12px; background: #f7f8fa; border: 1px dashed #d9dde3; border-radius: 10px;
    font-size: 12px; color: #4b5563; word-break: break-all; line-height: 1.5;
  }
  .hint { font-size: 12px; color: #8a8f99; line-height: 1.7; margin-top: 14px; }
  .big { text-align: center; font-size: 44px; margin: 8px 0 14px; }
  .row { display: flex; gap: 10px; }
  .row > * { flex: 1; }
</style>
</head>
<body>
<div class="card">
  <div class="brand"><span class="dot"></span><span>SLIPE 会员 · 微信支付</span></div>
  ${body}
</div>
${script ? `<script>${script}</script>` : ''}
</body>
</html>`;
}

function renderOrderHeader(order) {
  return `
  <div class="amount"><small>¥</small>${yuan(order.amountFen)}</div>
  <div class="title">SLIPE ${escapeHtml(order.planName)} 会员 · ${escapeHtml(
    order.cycleName || '',
  )}</div>
  <div class="meta">订单号 ${escapeHtml(order.outTradeNo)}</div>
  <div class="divider"></div>`;
}

function renderSuccessPage(order) {
  const plan = membershipPlanById(order.planId);
  return pageShell({
    title: '支付成功',
    body: `
      <div class="big">✅</div>
      <div class="title" style="text-align:center;font-size:20px">支付成功</div>
      <div class="meta" style="text-align:center;margin-top:8px">
        ${escapeHtml(plan?.name || order.planName)} 会员 · ${escapeHtml(order.cycleName)}
        · ¥${yuan(order.amountFen)}
      </div>
      <div class="divider"></div>
      <div class="hint" style="text-align:center">
        会员权益与积分已到账，请返回 APP 查看。<br>
        订单号 ${escapeHtml(order.outTradeNo)}
      </div>
    `,
  });
}

function renderErrorPage(message) {
  return pageShell({
    title: '支付不可用',
    body: `
      <div class="big">⚠️</div>
      <div class="title" style="text-align:center;font-size:18px">无法发起支付</div>
      <div class="hint" style="text-align:center">${escapeHtml(message)}</div>
    `,
  });
}

function renderOutsideWechatPage(order, payUrl, cfg) {
  return pageShell({
    title: '请在微信中打开',
    body: `
      ${renderOrderHeader(order)}
      <div class="title">请在微信中打开本页面</div>
      <div class="hint">
        微信支付只能在微信内置浏览器中发起。请复制下方支付链接，发送到「文件传输助手」后点击打开；
        或使用微信扫描链接二维码打开。
      </div>
      <div class="linkbox" id="payLink">${escapeHtml(payUrl)}</div>
      <button class="btn" id="copyBtn">复制支付链接</button>
      <a class="btn ghost" style="display:block;text-align:center;text-decoration:none;margin-top:10px"
         href="weixin://">打开微信</a>
      <div class="status" id="status">支付订单：${escapeHtml(order.outTradeNo)}</div>
    `,
    script: `
      var link = document.getElementById('payLink').innerText;
      var btn = document.getElementById('copyBtn');
      var status = document.getElementById('status');
      btn.onclick = function () {
        try {
          if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(link).then(function () { status.innerText = '已复制，请到微信中粘贴打开'; });
          } else {
            var ta = document.createElement('textarea');
            ta.value = link; document.body.appendChild(ta); ta.select();
            document.execCommand('copy'); document.body.removeChild(ta);
            status.innerText = '已复制，请到微信中粘贴打开';
          }
        } catch (e) {
          status.innerText = '复制失败，请长按链接手动复制';
        }
      };
      window.__APPID__ = ${JSON.stringify(cfg.appId)};
    `,
  });
}

function renderPayPage(order, oauthUrl) {
  const orderJson = JSON.stringify(publicOrder(order));
  const oauthJson = JSON.stringify(oauthUrl);
  return pageShell({
    title: '微信支付',
    body: `
      ${renderOrderHeader(order)}
      <button class="btn" id="payBtn" disabled>立即支付</button>
      <div class="status" id="status">正在准备支付…</div>
    `,
    script: `
      var order = ${orderJson};
      var oauthUrl = ${oauthJson};
      var params = null;
      var finished = false;
      var statusEl = document.getElementById('status');
      var payBtn = document.getElementById('payBtn');

      function setStatus(text, kind) {
        statusEl.className = 'status' + (kind ? ' ' + kind : '');
        statusEl.innerText = text;
      }

      function success() {
        if (finished) return;
        finished = true;
        location.replace('/pay?order=' + encodeURIComponent(order.outTradeNo));
      }

      async function load() {
        try {
          var res = await fetch('/pay/api/jsapi?order=' + encodeURIComponent(order.outTradeNo), { credentials: 'same-origin' });
          var data = await res.json();
          if (data.paid) { success(); return; }
          if (data.needOauth && data.oauthUrl) { location.replace(data.oauthUrl); return; }
          if (!data.ok) { setStatus(data.error || '支付参数获取失败', 'err'); return; }
          params = data.params;
          payBtn.disabled = false;
          setStatus('请点击「立即支付」完成付款');
        } catch (e) {
          setStatus('网络异常，请稍后重试', 'err');
        }
      }

      function invoke() {
        if (!params) return;
        if (typeof WeixinJSBridge === 'undefined') {
          setStatus('微信支付组件加载中，请稍后重试', 'err');
          return;
        }
        payBtn.disabled = true;
        setStatus('正在唤起微信支付…');
        WeixinJSBridge.invoke('getBrandWCPayRequest', params, function (res) {
          if (res.err_msg === 'get_brand_wcpay_request:ok') {
            setStatus('支付结果确认中…');
            confirmPay();
          } else if (res.err_msg === 'get_brand_wcpay_request:cancel') {
            payBtn.disabled = false;
            setStatus('已取消支付，可重新发起', 'err');
          } else {
            payBtn.disabled = false;
            setStatus('支付失败，请重试', 'err');
          }
        });
      }

      async function confirmPay() {
        try {
          var res = await fetch('/pay/api/confirm?order=' + encodeURIComponent(order.outTradeNo), { method: 'POST', credentials: 'same-origin' });
          var data = await res.json();
          if (data.status === 'paid') { success(); } else { setStatus('尚未收到支付结果，请稍候…'); }
        } catch (e) {
          setStatus('支付结果确认失败，请返回 APP 查看', 'err');
        }
      }

      payBtn.onclick = function () {
        if (typeof WeixinJSBridge === 'undefined') {
          document.addEventListener('WeixinJSBridgeReady', invoke, false);
          setTimeout(invoke, 800);
        } else {
          invoke();
        }
      };

      if (typeof WeixinJSBridge === 'undefined') {
        document.addEventListener('WeixinJSBridgeReady', load, false);
        setTimeout(load, 1200);
      } else {
        load();
      }

      // 兜底轮询：用户支付后从收银台返回时确认状态
      setInterval(async function () {
        if (finished) return;
        try {
          var res = await fetch('/pay/api/status?order=' + encodeURIComponent(order.outTradeNo), { credentials: 'same-origin' });
          var data = await res.json();
          if (data.status === 'paid') success();
        } catch (e) {}
      }, 4000);
    `,
  });
}

/** GET /pay?order=xxx */
export async function handlePayPage(req, res) {
  const url = new URL(req.url, 'http://localhost');
  const outTradeNo = String(url.searchParams.get('order') || '').trim();
  const order = findOrder(outTradeNo);
  if (!order) return sendHtml(res, 404, renderErrorPage('订单不存在或已失效'));

  if (order.status === 'paid') return sendHtml(res, 200, renderSuccessPage(order));
  if (order.status !== 'pending') {
    return sendHtml(res, 410, renderErrorPage('该订单已关闭，请返回 APP 重新下单'));
  }

  const cfg = wechatPayConfig();
  const payUrl = `${cfg.pageBase}/pay?order=${encodeURIComponent(order.outTradeNo)}`;
  const ua = String(req.headers['user-agent'] || '');
  if (!/MicroMessenger/i.test(ua)) {
    return sendHtml(res, 200, renderOutsideWechatPage(order, payUrl, cfg));
  }

  if (!cfg.appSecret) {
    return sendHtml(res, 503, renderErrorPage('公众号 AppSecret 未配置，请联系管理员'));
  }

  const cookies = parseCookies(req);
  const openid = cookies[OPENID_COOKIE] || '';
  if (!openid) {
    const redirectUri = `${cfg.pageBase}/pay/oauth`;
    const oauthUrl = buildWechatOauthUrl(redirectUri, signState(order.outTradeNo));
    res.writeHead(302, { Location: oauthUrl, 'Cache-Control': 'no-store' });
    res.end();
    return;
  }

  return sendHtml(res, 200, renderPayPage(order, ''));
}

/** GET /pay/oauth?code=&state= */
export async function handlePayOauth(req, res) {
  const url = new URL(req.url, 'http://localhost');
  const code = String(url.searchParams.get('code') || '').trim();
  const orderNo = verifyState(url.searchParams.get('state') || '');
  if (!orderNo) return sendHtml(res, 400, renderErrorPage('授权校验失败，请返回 APP 重试'));
  const order = findOrder(orderNo);
  if (!order) return sendHtml(res, 404, renderErrorPage('订单不存在或已失效'));
  if (!code) return sendHtml(res, 400, renderErrorPage('未获取到微信授权码'));

  let openid;
  try {
    openid = await exchangeCodeForOpenid(code);
  } catch (err) {
    return sendHtml(res, 502, renderErrorPage(err.message || '获取微信身份失败'));
  }

  res.writeHead(302, {
    Location: `${wechatPayConfig().pageBase}/pay?order=${encodeURIComponent(order.outTradeNo)}`,
    'Set-Cookie': `${OPENID_COOKIE}=${encodeURIComponent(
      openid,
    )}; Path=/pay; Max-Age=${OPENID_COOKIE_MAX_AGE}; HttpOnly; Secure; SameSite=Lax`,
    'Cache-Control': 'no-store',
  });
  res.end();
}

/** GET /pay/api/jsapi?order=xxx → JSAPI 调起参数 */
export async function handlePayJsapi(req, res) {
  const url = new URL(req.url, 'http://localhost');
  const outTradeNo = String(url.searchParams.get('order') || '').trim();
  const order = findOrder(outTradeNo);
  if (!order) return sendJson(res, 404, { ok: false, error: '订单不存在' });
  if (order.status === 'paid') return sendJson(res, 200, { ok: true, paid: true });
  if (order.status !== 'pending') {
    return sendJson(res, 410, { ok: false, error: '订单已关闭' });
  }

  const cfg = wechatPayConfig();
  const openid = parseCookies(req)[OPENID_COOKIE] || '';
  if (!openid) {
    return sendJson(res, 401, {
      ok: false,
      needOauth: true,
      oauthUrl: buildWechatOauthUrl(
        `${cfg.pageBase}/pay/oauth`,
        signState(order.outTradeNo),
      ),
    });
  }

  try {
    let prepayId = order.prepayId;
    if (!prepayId || Date.now() - (order.prepayAt || 0) > PREPAY_REUSE_MS) {
      prepayId = await createJsapiPrepay({
        description: `SLIPE ${order.planName} 会员（${order.cycleName}）`,
        outTradeNo: order.outTradeNo,
        amountFen: order.amountFen,
        openid,
        clientIp: remoteIp(req),
      });
      order.prepayId = prepayId;
      order.prepayAt = Date.now();
      await saveDb();
    }
    return sendJson(res, 200, {
      ok: true,
      params: buildJsapiPayParams(prepayId),
      order: publicOrder(order),
    });
  } catch (err) {
    console.error('[wechat-pay] 下单失败：', err.message, err.detail || '');
    return sendJson(res, err.status || 502, {
      ok: false,
      error: err.message || '微信支付下单失败',
      code: err.code || '',
    });
  }
}

/** GET /pay/api/status?order=xxx */
export async function handlePayStatus(req, res) {
  const url = new URL(req.url, 'http://localhost');
  const order = findOrder(String(url.searchParams.get('order') || '').trim());
  if (!order) return sendJson(res, 404, { status: 'not_found' });
  return sendJson(res, 200, {
    status: order.status,
    order: publicOrder(order),
  });
}

/** POST /pay/api/confirm?order=xxx → 主动查单确认 */
export async function handlePayConfirm(req, res) {
  const url = new URL(req.url, 'http://localhost');
  const outTradeNo = String(url.searchParams.get('order') || '').trim();
  const order = findOrder(outTradeNo);
  if (!order) return sendJson(res, 404, { status: 'not_found' });

  if (order.status === 'pending') {
    try {
      const data = await queryOrder(outTradeNo);
      if (data.trade_state === 'SUCCESS') {
        await markOrderPaid({
          outTradeNo,
          transactionId: data.transaction_id,
          amountTotal: data.amount?.total,
          source: 'page_confirm',
        });
      }
    } catch (err) {
      return sendJson(res, 200, {
        status: order.status,
        warning: err.message || '查单失败',
      });
    }
  }
  return sendJson(res, 200, { status: order.status, order: publicOrder(order) });
}

// ---------------------------------------------------------------------------
// 管理端：订单列表
// ---------------------------------------------------------------------------

export async function handleAdminListOrders(req, res) {
  requireAdmin(req);
  const url = new URL(req.url, 'http://localhost');
  const status = String(url.searchParams.get('status') || '');
  const keyword = String(url.searchParams.get('q') || '').trim().toUpperCase();
  const page = Math.max(1, Number(url.searchParams.get('page') || 1));
  const pageSize = Math.min(100, Math.max(1, Number(url.searchParams.get('pageSize') || 20)));

  const all = (getDb().payOrders || []).slice().reverse();
  let list = all;
  if (status) list = list.filter((o) => o.status === status);
  if (keyword) {
    list = list.filter(
      (o) =>
        String(o.outTradeNo).includes(keyword) ||
        String(o.userEmail || '').toUpperCase().includes(keyword),
    );
  }
  const start = (page - 1) * pageSize;
  const paid = all.filter((o) => o.status === 'paid');
  sendJson(res, 200, {
    orders: list.slice(start, start + pageSize).map((o) => ({
      ...publicOrder(o),
      userEmail: o.userEmail || '',
      note: o.note || '',
    })),
    total: list.length,
    page,
    pageSize,
    summary: {
      total: all.length,
      paid: paid.length,
      pending: all.filter((o) => o.status === 'pending').length,
      revenueFen: paid.reduce((sum, o) => sum + (Number(o.amountFen) || 0), 0),
    },
    plans: MEMBERSHIP_PLANS.filter((p) => !p.free).map((p) => ({
      id: p.id,
      name: p.name,
      prices: p.prices,
    })),
    cycles: MEMBERSHIP_CYCLES,
  });
}
