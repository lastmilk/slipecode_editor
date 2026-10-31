// 安全：密码哈希（scrypt）、JWT（HMAC-SHA256）、用户/管理员鉴权

import { randomBytes, scryptSync, timingSafeEqual, createHmac } from 'node:crypto';

import {
  ADMIN_TOKEN_TTL_SECONDS,
  DEFAULT_ADMIN_PASSWORD,
  JWT_SECRET,
  LEGACY_ADMIN_TOKEN,
  TOKEN_TTL_SECONDS,
  adminPasswordHash,
} from './config.js';
import { getDb } from './db.js';
import { adminPasswordHeader, bearer, httpError, remoteIp } from './http.js';

// ---------------------------------------------------------------------------
// 密码
// ---------------------------------------------------------------------------

export function hashPassword(password) {
  const salt = randomBytes(16);
  const hash = scryptSync(password, salt, 64);
  return `${salt.toString('hex')}:${hash.toString('hex')}`;
}

export function verifyPassword(password, stored) {
  const [saltHex, hashHex] = String(stored || '').split(':');
  if (!saltHex || !hashHex) return false;
  const expected = Buffer.from(hashHex, 'hex');
  const actual = scryptSync(password, Buffer.from(saltHex, 'hex'), 64);
  return expected.length === actual.length && timingSafeEqual(expected, actual);
}

/** 定长比较，避免长度差异泄露信息 */
function safeEqual(a, b) {
  const left = Buffer.from(String(a));
  const right = Buffer.from(String(b));
  if (left.length !== right.length) return false;
  return timingSafeEqual(left, right);
}

// ---------------------------------------------------------------------------
// JWT
// ---------------------------------------------------------------------------

const b64url = (buf) =>
  Buffer.from(buf)
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/g, '');

export function signToken(payload) {
  const header = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const body = b64url(JSON.stringify(payload));
  const sig = b64url(createHmac('sha256', JWT_SECRET).update(`${header}.${body}`).digest());
  return `${header}.${body}.${sig}`;
}

export function verifyToken(token) {
  const parts = String(token || '').split('.');
  if (parts.length !== 3) return null;
  const [header, body, sig] = parts;
  const expected = b64url(
    createHmac('sha256', JWT_SECRET).update(`${header}.${body}`).digest(),
  );
  if (sig.length !== expected.length) return null;
  if (!timingSafeEqual(Buffer.from(sig), Buffer.from(expected))) return null;
  try {
    const payload = JSON.parse(
      Buffer.from(body.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8'),
    );
    if (!payload.sub || !payload.exp || payload.exp * 1000 < Date.now()) return null;
    return payload;
  } catch {
    return null;
  }
}

export function issueUserToken(userId) {
  return signToken({
    sub: userId,
    exp: Math.floor(Date.now() / 1000) + TOKEN_TTL_SECONDS,
  });
}

export function issueAdminToken() {
  return signToken({
    sub: 'admin',
    role: 'admin',
    exp: Math.floor(Date.now() / 1000) + ADMIN_TOKEN_TTL_SECONDS,
  });
}

// ---------------------------------------------------------------------------
// 用户鉴权
// ---------------------------------------------------------------------------

export function requireUser(req) {
  const payload = verifyToken(bearer(req));
  if (!payload || payload.role === 'admin') {
    throw httpError(401, '未登录或登录已过期');
  }
  const user = getDb().users.find((u) => u.id === payload.sub);
  if (!user) throw httpError(401, '账号不存在');
  return user;
}

export function publicUser(user) {
  return {
    id: user.id,
    email: user.email,
    displayName: user.displayName,
    phone: user.phone || '',
    avatarUrl: user.avatar ? `/api/avatars/${user.id}?v=${user.avatar.version}` : '',
    wallpaperVersion: user.wallpaper?.version || '',
  };
}

// ---------------------------------------------------------------------------
// 管理员鉴权
// ---------------------------------------------------------------------------

/** 校验管理员密码：优先使用 db 中保存的哈希，否则回退到环境变量/默认密码 */
export function verifyAdminPassword(password) {
  const pw = String(password || '');
  if (!pw) return false;
  const stored = adminPasswordHash();
  if (stored) return verifyPassword(pw, stored);
  return safeEqual(pw, DEFAULT_ADMIN_PASSWORD);
}

/** 管理员会话令牌（Bearer）或环境变量静态令牌（兼容脚本） */
export function requireAdmin(req) {
  const token = bearer(req);
  if (!token) throw httpError(401, '请先登录管理端');
  if (safeEqual(token, LEGACY_ADMIN_TOKEN)) return;
  const payload = verifyToken(token);
  if (!payload || payload.role !== 'admin') {
    throw httpError(401, '管理端登录已过期，请重新登录');
  }
}

/** 敏感操作二次验证：要求请求头携带管理员密码 */
export function requireAdminPassword(req) {
  requireAdmin(req);
  if (!verifyAdminPassword(adminPasswordHeader(req))) {
    throw httpError(403, '管理员密码不正确');
  }
}

 // 管理员登录失败节流：同一 IP 10 分钟内最多 8 次
const adminAttempts = new Map();
const ADMIN_ATTEMPT_WINDOW_MS = 10 * 60 * 1000;
const ADMIN_ATTEMPT_MAX = 8;

export function throttleAdminLogin(req) {
  const key = remoteIp(req);
  const now = Date.now();
  const item = adminAttempts.get(key);
  if (!item || now - item.first > ADMIN_ATTEMPT_WINDOW_MS) {
    adminAttempts.set(key, { first: now, count: 1 });
    return;
  }
  item.count += 1;
  if (item.count > ADMIN_ATTEMPT_MAX) {
    throw httpError(429, '尝试次数过多，请稍后再试');
  }
}

export function clearAdminLoginThrottle(req) {
  adminAttempts.delete(remoteIp(req));
}
