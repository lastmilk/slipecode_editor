// 账号路由：注册 / 登录 / 短信验证码 / 极验独立校验

import { randomBytes } from 'node:crypto';

import { INITIAL_CREDITS, PASSWORD_MIN, PHONE_PATTERN } from '../config.js';
import { bumpStat, getDb, saveDb } from '../db.js';
import { httpError, readJson, remoteIp, sendJson } from '../http.js';
import {
  hashPassword,
  issueUserToken,
  publicUser,
  verifyPassword,
} from '../security.js';
import { requireCaptchaIfNeeded, verifyGeetest } from '../services/geetest.js';
import { checkSmsVerifyCode, devCode, sendCode, throttleSms } from '../services/aliyun-sms.js';

// 登录/注册失败节流（内存级，单实例足够）
const attempts = new Map();
const ATTEMPT_WINDOW_MS = 10 * 60 * 1000;
const ATTEMPT_MAX = 10;

function throttle(key) {
  const now = Date.now();
  const item = attempts.get(key);
  if (!item || now - item.first > ATTEMPT_WINDOW_MS) {
    attempts.set(key, { first: now, count: 1 });
    return;
  }
  item.count += 1;
  if (item.count > ATTEMPT_MAX) {
    throw httpError(429, '尝试次数过多，请稍后再试');
  }
}

function normalizeEmail(value) {
  return String(value || '').trim().toLowerCase();
}

function normalizePhone(value) {
  return String(value || '').replace(/[\s-]/g, '');
}

export async function handleRegister(req, res) {
  throttle(`register:${remoteIp(req)}`);
  const body = await readJson(req);
  const email = normalizeEmail(body.email);
  const password = String(body.password || '');
  const displayName = String(body.displayName || '').trim();
  const phone = normalizePhone(body.phone);
  const smsCode = String(body.smsCode || '').trim();

  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
    return sendJson(res, 400, { error: '邮箱格式不正确' });
  }
  if (password.length < PASSWORD_MIN) {
    return sendJson(res, 400, { error: `密码至少 ${PASSWORD_MIN} 位` });
  }
  if (!displayName) return sendJson(res, 400, { error: '昵称不能为空' });
  if (displayName.length > 24) {
    return sendJson(res, 400, { error: '昵称不能超过 24 个字符' });
  }
  if (!PHONE_PATTERN.test(phone)) {
    return sendJson(res, 400, { error: '手机号格式不正确' });
  }
  if (!smsCode) return sendJson(res, 400, { error: '请填写短信验证码' });

  const db = getDb();
  if (db.users.some((u) => u.email === email)) {
    return sendJson(res, 409, { error: '该邮箱已注册' });
  }
  if (db.users.some((u) => u.phone === phone)) {
    return sendJson(res, 409, { error: '该手机号已注册' });
  }

  // 1) 人机验证（极验）
  if (!(await requireCaptchaIfNeeded(body))) {
    return sendJson(res, 400, { error: '人机验证失败，请重试' });
  }

  // 2) 短信验证码
  let smsOk = false;
  try {
    smsOk = await checkSmsVerifyCode(phone, smsCode);
  } catch (err) {
    return sendJson(res, 502, { error: err.message || '短信验证码校验失败' });
  }
  if (!smsOk) {
    return sendJson(res, 400, { error: '短信验证码不正确或已过期' });
  }

  const now = new Date().toISOString();
  const user = {
    id: `u_${randomBytes(8).toString('hex')}`,
    email,
    displayName,
    phone,
    avatarUrl: '',
    wallpaper: null,
    passwordHash: hashPassword(password),
    credits: INITIAL_CREDITS,
    creditLogs: [
      {
        ts: now,
        type: 'register_bonus',
        amount: INITIAL_CREDITS,
        balance: INITIAL_CREDITS,
        note: '注册赠送额度',
      },
    ],
    lastCheckinDate: null,
    createdAt: now,
    lastLoginAt: now,
  };
  db.users.push(user);
  bumpStat('registers');
  await saveDb();

  sendJson(res, 201, { token: issueUserToken(user.id), user: publicUser(user) });
}

/** 发送注册短信验证码 */
export async function handleSendSmsCode(req, res) {
  const body = await readJson(req);
  const phone = normalizePhone(body.phone);
  if (!PHONE_PATTERN.test(phone)) {
    return sendJson(res, 400, { error: '手机号格式不正确' });
  }
  if (getDb().users.some((u) => u.phone === phone)) {
    return sendJson(res, 409, { error: '该手机号已注册，请直接登录' });
  }
  throttle(`sms-ip:${remoteIp(req)}`);
  throttleSms(phone);

  try {
    const result = await sendCode(phone);
    return sendJson(res, 200, {
      ok: true,
      dev: result.dev,
      ...(result.dev ? { devCode: devCode() } : {}),
    });
  } catch (err) {
    return sendJson(res, 502, { error: err.message || '短信发送失败' });
  }
}

/** 极验结果独立校验（客户端可在登录/注册前预校验） */
export async function handleCaptchaValidate(req, res) {
  const body = await readJson(req);
  const ok = await verifyGeetest(body.captcha);
  if (!ok) return sendJson(res, 400, { ok: false, error: '人机验证失败' });
  sendJson(res, 200, { ok: true });
}

export async function handleLogin(req, res) {
  const body = await readJson(req);
  const email = normalizeEmail(body.email);
  const password = String(body.password || '');
  throttle(`login:${email || remoteIp(req)}`);

  if (!(await requireCaptchaIfNeeded(body))) {
    return sendJson(res, 400, { error: '人机验证失败，请重试' });
  }

  const db = getDb();
  const user = db.users.find((u) => u.email === email);
  if (!user || !verifyPassword(password, user.passwordHash)) {
    return sendJson(res, 401, { error: '邮箱或密码不正确' });
  }
  attempts.delete(`login:${email}`);
  user.lastLoginAt = new Date().toISOString();
  bumpStat('logins');
  await saveDb();

  sendJson(res, 200, { token: issueUserToken(user.id), user: publicUser(user) });
}
