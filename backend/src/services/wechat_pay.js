// 微信支付 v3（JSAPI）
//
// 负责：
//  - 商户私钥 / 微信支付公钥读取（PEM 文本或本地文件）
//  - 请求签名（WECHATPAY2-SHA256-RSA2048）
//  - JSAPI 下单 / 查单
//  - 调起支付参数签名
//  - 回调通知验签 + 报文解密（AEAD_AES_256_GCM）
//  - 公众号网页授权换取 openid
//
// 说明：微信支付要求支付页面域名（ser1996.niav.cn）已配置为
// 「支付授权目录」与「网页授权域名」，否则无法发起 JSAPI 支付。

import {
  createDecipheriv,
  createSign,
  createVerify,
  randomBytes,
} from 'node:crypto';
import { readFileSync, existsSync } from 'node:fs';

import { wechatPayConfig } from '../config.js';
import { getDb, saveDb } from '../db.js';

const API_BASE = 'https://api.mch.weixin.qq.com';
const REQUEST_TIMEOUT_MS = 12000;

export function wechatNonce() {
  return randomBytes(16).toString('hex');
}

function loadPem(inline, filePath) {
  const text = String(inline || '').trim();
  if (text) return text;
  if (filePath && existsSync(filePath)) {
    return readFileSync(filePath, 'utf8');
  }
  return '';
}

export function merchantPrivateKey() {
  const c = wechatPayConfig();
  return loadPem(c.privateKeyPem, c.privateKeyPath);
}

export function wechatPublicKey() {
  const c = wechatPayConfig();
  return loadPem(c.publicKeyPem, c.publicKeyPath);
}

function signWithMerchantKey(message) {
  const key = merchantPrivateKey();
  if (!key) {
    throw Object.assign(new Error('未配置微信支付商户私钥'), {
      status: 503,
      code: 'WECHAT_PAY_NOT_CONFIGURED',
    });
  }
  return createSign('RSA-SHA256').update(message, 'utf8').sign(key, 'base64');
}

/** 构造请求 Authorization 头 */
function buildAuthorization(method, urlPath, body, cfg) {
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const nonceStr = wechatNonce();
  const message = `${method}\n${urlPath}\n${timestamp}\n${nonceStr}\n${body}\n`;
  const signature = signWithMerchantKey(message);
  return (
    'WECHATPAY2-SHA256-RSA2048 ' +
    `mchid="${cfg.mchId}",` +
    `nonce_str="${nonceStr}",` +
    `signature="${signature}",` +
    `timestamp="${timestamp}",` +
    `serial_no="${cfg.serialNo}"`
  );
}

/** 校验微信支付应答 / 回调签名 */
export async function verifyWechatSignature({
  timestamp,
  nonceStr,
  signature,
  serial,
  body,
}) {
  if (!timestamp || !nonceStr || !signature || !body) return false;
  const message = `${timestamp}\n${nonceStr}\n${body}\n`;
  const cfg = wechatPayConfig();

  const candidates = [];
  const publicKey = wechatPublicKey();
  if (publicKey) {
    // 微信支付公钥（serial 形如 PUB_KEY_ID_xxx）；未填公钥 ID 时兜底尝试
    if (!cfg.publicKeyId || serial === cfg.publicKeyId || String(serial || '').startsWith('PUB_KEY_ID_')) {
      candidates.push(publicKey);
    }
  }
  const cached = getDb().config?.wechatPay?.platformCerts?.[serial];
  if (cached) candidates.push(cached);

  // 未知序列号：尝试拉取平台证书（需要商户私钥）
  if (!cached && serial && !String(serial).startsWith('PUB_KEY_ID_')) {
    try {
      const certs = await refreshPlatformCertificates();
      if (certs[serial]) candidates.push(certs[serial]);
    } catch {
      // 没有私钥或网络异常时忽略，走下面的失败分支
    }
  }

  for (const pem of candidates) {
    try {
      const ok = createVerify('RSA-SHA256')
        .update(message, 'utf8')
        .verify(pem, signature, 'base64');
      if (ok) return true;
    } catch {
      // 尝试下一个候选证书
    }
  }
  return false;
}

/** AEAD_AES_256_GCM 解密（APIv3 报文） */
export function decryptWechatResource({ algorithm, ciphertext, nonce, associated_data }) {
  const cfg = wechatPayConfig();
  if (!cfg.apiV3Key || cfg.apiV3Key.length !== 32) {
    throw Object.assign(new Error('未配置微信支付 APIv3 密钥'), {
      status: 503,
      code: 'WECHAT_PAY_NOT_CONFIGURED',
    });
  }
  if (algorithm !== 'AEAD_AES_256_GCM') {
    throw new Error(`不支持的加密算法：${algorithm}`);
  }
  const raw = Buffer.from(String(ciphertext || ''), 'base64');
  if (raw.length <= 16) throw new Error('回调报文长度异常');
  const authTag = raw.subarray(raw.length - 16);
  const data = raw.subarray(0, raw.length - 16);
  const decipher = createDecipheriv(
    'aes-256-gcm',
    Buffer.from(cfg.apiV3Key, 'utf8'),
    Buffer.from(String(nonce || ''), 'utf8'),
  );
  decipher.setAuthTag(authTag);
  if (associated_data) {
    decipher.setAAD(Buffer.from(associated_data, 'utf8'));
  }
  return Buffer.concat([decipher.update(data), decipher.final()]).toString('utf8');
}

async function requestWechat(method, urlPath, body, { verifyResponse = true } = {}) {
  const cfg = wechatPayConfig();
  const payload = body ? JSON.stringify(body) : '';
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  let res;
  try {
    res = await fetch(`${API_BASE}${urlPath}`, {
      method,
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
        Authorization: buildAuthorization(method, urlPath, payload, cfg),
      },
      body: payload || undefined,
      signal: controller.signal,
    });
  } finally {
    clearTimeout(timer);
  }

  const text = await res.text();
  let data = {};
  try {
    data = text ? JSON.parse(text) : {};
  } catch {
    data = { raw: text };
  }

  if (!res.ok) {
    const err = new Error(
      data.message || `微信支付接口错误（HTTP ${res.status}）`,
    );
    err.status = 502;
    err.code = data.code || 'WECHAT_PAY_ERROR';
    err.detail = data;
    throw err;
  }

  if (verifyResponse && text) {
    const ok = await verifyWechatSignature({
      timestamp: res.headers.get('wechatpay-timestamp') || '',
      nonceStr: res.headers.get('wechatpay-nonce') || '',
      signature: res.headers.get('wechatpay-signature') || '',
      serial: res.headers.get('wechatpay-serial') || '',
      body: text,
    });
    // 未配置任何验签密钥时跳过（首次配置阶段），配置后强制校验
    const cachedCerts = getDb().config?.wechatPay?.platformCerts || {};
    const hasVerifyKey = Boolean(
      wechatPublicKey() || Object.keys(cachedCerts).length,
    );
    if (hasVerifyKey && !ok) {
      throw Object.assign(new Error('微信支付应答验签失败'), {
        status: 502,
        code: 'WECHAT_PAY_VERIFY_FAILED',
      });
    }
  }
  return data;
}

/** 拉取并缓存微信支付平台证书 */
export async function refreshPlatformCertificates() {
  const data = await requestWechat('GET', '/v3/certificates', null, {
    verifyResponse: false,
  });
  const list = Array.isArray(data.data) ? data.data : [];
  const certs = {};
  for (const item of list) {
    const enc = item.encrypt_certificate;
    if (!enc) continue;
    try {
      certs[item.serial_no] = decryptWechatResource({
        algorithm: enc.algorithm,
        ciphertext: enc.ciphertext,
        nonce: enc.nonce,
        associated_data: enc.associated_data,
      });
    } catch {
      // 单个证书解密失败不影响其它证书
    }
  }
  const db = getDb();
  db.config.wechatPay.platformCerts = certs;
  await saveDb();
  return certs;
}

/** 回调通知：验签 + 解密，返回支付成功报文 */
export async function parseWechatNotify(headers, rawBody) {
  const ok = await verifyWechatSignature({
    timestamp: headers['wechatpay-timestamp'] || '',
    nonceStr: headers['wechatpay-nonce'] || '',
    signature: headers['wechatpay-signature'] || '',
    serial: headers['wechatpay-serial'] || '',
    body: rawBody,
  });
  if (!ok) {
    throw Object.assign(new Error('微信支付回调验签失败'), {
      status: 401,
      code: 'WECHAT_PAY_VERIFY_FAILED',
    });
  }

  let payload;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    throw Object.assign(new Error('回调报文不是合法 JSON'), { status: 400 });
  }
  const resource = payload.resource;
  if (!resource) {
    throw Object.assign(new Error('回调报文缺少 resource'), { status: 400 });
  }
  const plain = decryptWechatResource({
    algorithm: resource.algorithm,
    ciphertext: resource.ciphertext,
    nonce: resource.nonce,
    associated_data: resource.associated_data,
  });
  return {
    eventType: payload.event_type || '',
    resourceType: payload.resource_type || '',
    transaction: JSON.parse(plain),
  };
}

/** JSAPI 下单，返回 prepay_id */
export async function createJsapiPrepay({
  description,
  outTradeNo,
  amountFen,
  openid,
  clientIp,
}) {
  const cfg = wechatPayConfig();
  const data = await requestWechat('POST', '/v3/pay/transactions/jsapi', {
    appid: cfg.appId,
    mchid: cfg.mchId,
    description: String(description || 'SLIPE 会员').slice(0, 120),
    out_trade_no: outTradeNo,
    notify_url: cfg.notifyUrl,
    amount: { total: amountFen, currency: 'CNY' },
    payer: { openid },
    ...(clientIp ? { scene_info: { payer_client_ip: clientIp } } : {}),
  });
  if (!data.prepay_id) {
    throw Object.assign(new Error('微信支付下单未返回 prepay_id'), {
      status: 502,
    });
  }
  return data.prepay_id;
}

/** 生成 WeixinJSBridge.invoke('getBrandWCPayRequest') 所需参数 */
export function buildJsapiPayParams(prepayId) {
  const cfg = wechatPayConfig();
  const timeStamp = Math.floor(Date.now() / 1000).toString();
  const nonceStr = wechatNonce();
  const pkg = `prepay_id=${prepayId}`;
  const message = `${cfg.appId}\n${timeStamp}\n${nonceStr}\n${pkg}\n`;
  const paySign = signWithMerchantKey(message);
  return {
    appId: cfg.appId,
    timeStamp,
    nonceStr,
    package: pkg,
    signType: 'RSA',
    paySign,
  };
}

/** 按商户订单号查单 */
export async function queryOrder(outTradeNo) {
  const cfg = wechatPayConfig();
  const path = `/v3/pay/transactions/out-trade-no/${encodeURIComponent(
    outTradeNo,
  )}?mchid=${encodeURIComponent(cfg.mchId)}`;
  return requestWechat('GET', path, null);
}

/** 公众号网页授权地址（snsapi_base，静默获取 openid） */
export function buildWechatOauthUrl(redirectUri, state) {
  const cfg = wechatPayConfig();
  const params = new URLSearchParams({
    appid: cfg.appId,
    redirect_uri: redirectUri,
    response_type: 'code',
    scope: 'snsapi_base',
    state,
  });
  return `https://open.weixin.qq.com/connect/oauth2/authorize?${params.toString()}#wechat_redirect`;
}

/** 用授权 code 换取 openid */
export async function exchangeCodeForOpenid(code) {
  const cfg = wechatPayConfig();
  if (!cfg.appSecret) {
    throw Object.assign(new Error('未配置公众号 AppSecret'), {
      status: 503,
      code: 'WECHAT_PAY_NOT_CONFIGURED',
    });
  }
  const params = new URLSearchParams({
    appid: cfg.appId,
    secret: cfg.appSecret,
    code,
    grant_type: 'authorization_code',
  });
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  let res;
  try {
    res = await fetch(
      `https://api.weixin.qq.com/sns/oauth2/access_token?${params.toString()}`,
      { signal: controller.signal },
    );
  } finally {
    clearTimeout(timer);
  }
  const data = await res.json().catch(() => ({}));
  if (!data.openid) {
    throw Object.assign(
      new Error(`获取 openid 失败：${data.errmsg || '未知错误'}`),
      { status: 502, code: data.errcode || 'WECHAT_OAUTH_ERROR' },
    );
  }
  return data.openid;
}
