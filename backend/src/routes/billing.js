// 商业化：充值套餐展示 + 激活码兑换

import { randomBytes } from 'node:crypto';

import {
  CHECKIN_REWARD,
  CREDIT_PLANS,
  INITIAL_CREDITS,
  TOKENS_PER_CREDIT,
  creditPlanById,
} from '../config.js';
import { bumpStat, getDb, saveDb } from '../db.js';
import { readJson, sendJson } from '../http.js';
import { requireAdmin, requireUser } from '../security.js';
import { applyCredits, getCredits } from './me.js';

/** 激活码字符集（去掉易混淆的 0/O/1/I/L） */
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

/** 生成 SLIPE-XXXX-XXXX-XXXX 形式的激活码 */
export function generateActivationCode() {
  const blocks = [];
  for (let i = 0; i < 3; i += 1) {
    let block = '';
    const bytes = randomBytes(4);
    for (let j = 0; j < 4; j += 1) {
      block += CODE_ALPHABET[bytes[j] % CODE_ALPHABET.length];
    }
    blocks.push(block);
  }
  return `SLIPE-${blocks.join('-')}`;
}

function normalizeCode(value) {
  return String(value || '')
    .trim()
    .toUpperCase()
    .replace(/\s+/g, '');
}

/** 充值套餐与计价口径（客户端展示用，可公开） */
export async function handleBillingPlans(req, res) {
  sendJson(res, 200, {
    plans: CREDIT_PLANS,
    pricing: {
      tokensPerCredit: TOKENS_PER_CREDIT,
      initialCredits: INITIAL_CREDITS,
      checkinReward: CHECKIN_REWARD,
      currency: 'CNY',
    },
    redeemEnabled: true,
  });
}

/** 用户兑换激活码 */
export async function handleRedeemActivationCode(req, res) {
  const user = requireUser(req);
  const body = await readJson(req);
  const code = normalizeCode(body.code);
  if (!code) return sendJson(res, 400, { error: '请输入激活码' });

  const db = getDb();
  const item = (db.activationCodes || []).find((c) => c.code === code);
  if (!item) return sendJson(res, 404, { error: '激活码不存在' });
  if (item.disabled) return sendJson(res, 403, { error: '该激活码已被停用' });
  if (item.usedAt) return sendJson(res, 409, { error: '该激活码已被使用' });
  if (item.expiresAt && Date.parse(item.expiresAt) < Date.now()) {
    return sendJson(res, 410, { error: '该激活码已过期' });
  }

  const credits = Math.max(1, Math.trunc(Number(item.credits) || 0));
  item.usedAt = new Date().toISOString();
  item.usedBy = user.id;
  item.usedByEmail = user.email;
  const plan = creditPlanById(item.planId);
  applyCredits(user, credits, 'redeem', plan ? `${plan.name} 激活码` : '激活码充值');
  bumpStat('creditsRedeemed', credits);
  await saveDb();

  sendJson(res, 200, {
    ok: true,
    message: `兑换成功 +${credits} 积分`,
    credits: getCredits(user),
    amount: credits,
    plan: plan ? { id: plan.id, name: plan.name } : null,
  });
}

// ---------------------------------------------------------------------------
// 管理端：激活码批量生成 / 列表 / 停用
// ---------------------------------------------------------------------------

function publicCode(c) {
  return {
    id: c.id,
    code: c.code,
    credits: c.credits,
    planId: c.planId || '',
    planName: creditPlanById(c.planId)?.name || '',
    note: c.note || '',
    createdAt: c.createdAt || '',
    expiresAt: c.expiresAt || null,
    usedAt: c.usedAt || null,
    usedBy: c.usedBy || '',
    usedByEmail: c.usedByEmail || '',
    disabled: Boolean(c.disabled),
  };
}

export async function handleAdminListActivationCodes(req, res) {
  requireAdmin(req);
  const url = new URL(req.url, 'http://localhost');
  const status = String(url.searchParams.get('status') || '');
  const keyword = String(url.searchParams.get('q') || '').trim().toUpperCase();
  const page = Math.max(1, Number(url.searchParams.get('page') || 1));
  const pageSize = Math.min(100, Math.max(1, Number(url.searchParams.get('pageSize') || 20)));

  let list = (getDb().activationCodes || []).slice().reverse();
  if (keyword) {
    list = list.filter(
      (c) =>
        c.code.includes(keyword) ||
        String(c.usedByEmail || '').toUpperCase().includes(keyword),
    );
  }
  if (status === 'unused') list = list.filter((c) => !c.usedAt && !c.disabled);
  if (status === 'used') list = list.filter((c) => c.usedAt);
  if (status === 'disabled') list = list.filter((c) => c.disabled);

  const total = list.length;
  const start = (page - 1) * pageSize;
  sendJson(res, 200, {
    codes: list.slice(start, start + pageSize).map(publicCode),
    total,
    page,
    pageSize,
    summary: {
      total: (getDb().activationCodes || []).length,
      unused: (getDb().activationCodes || []).filter((c) => !c.usedAt && !c.disabled)
        .length,
      used: (getDb().activationCodes || []).filter((c) => c.usedAt).length,
      creditsIssued: (getDb().activationCodes || []).reduce(
        (sum, c) => sum + (Number(c.credits) || 0),
        0,
      ),
      creditsRedeemed: (getDb().activationCodes || [])
        .filter((c) => c.usedAt)
        .reduce((sum, c) => sum + (Number(c.credits) || 0), 0),
    },
  });
}

export async function handleAdminCreateActivationCodes(req, res) {
  requireAdmin(req);
  const body = await readJson(req);
  const count = Math.min(200, Math.max(1, Math.trunc(Number(body.count) || 1)));
  const credits = Math.trunc(Number(body.credits) || 0);
  if (credits <= 0 || credits > 1_000_000) {
    return sendJson(res, 400, { error: '积分面额需在 1 - 1000000 之间' });
  }
  const plan = creditPlanById(body.planId);
  const expiresAt = body.expiresAt ? String(body.expiresAt) : null;
  if (expiresAt && Number.isNaN(Date.parse(expiresAt))) {
    return sendJson(res, 400, { error: '过期时间格式不正确' });
  }

  const db = getDb();
  if (!Array.isArray(db.activationCodes)) db.activationCodes = [];
  const now = new Date().toISOString();
  const created = [];
  const existing = new Set(db.activationCodes.map((c) => c.code));
  for (let i = 0; i < count; i += 1) {
    let code = generateActivationCode();
    while (existing.has(code)) code = generateActivationCode();
    existing.add(code);
    const item = {
      id: `ac_${randomBytes(6).toString('hex')}`,
      code,
      credits,
      planId: plan?.id || '',
      note: String(body.note || '').slice(0, 120),
      createdAt: now,
      expiresAt,
      usedAt: null,
      usedBy: '',
      usedByEmail: '',
      disabled: false,
    };
    db.activationCodes.push(item);
    created.push(publicCode(item));
  }
  await saveDb();
  sendJson(res, 201, { codes: created, total: created.length });
}

/** 停用 / 启用（仅未使用的激活码可停用） */
export async function handleAdminToggleActivationCode(req, res, id) {
  requireAdmin(req);
  const item = (getDb().activationCodes || []).find((c) => c.id === id);
  if (!item) return sendJson(res, 404, { error: '激活码不存在' });
  if (item.usedAt) return sendJson(res, 409, { error: '已使用的激活码不能停用' });
  item.disabled = !item.disabled;
  await saveDb();
  sendJson(res, 200, { ok: true, code: publicCode(item) });
}

export async function handleAdminDeleteActivationCode(req, res, id) {
  requireAdmin(req);
  const db = getDb();
  const index = (db.activationCodes || []).findIndex((c) => c.id === id);
  if (index === -1) return sendJson(res, 404, { error: '激活码不存在' });
  const [removed] = db.activationCodes.splice(index, 1);
  await saveDb();
  sendJson(res, 200, { ok: true, id: removed.id });
}
