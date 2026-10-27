// SlipCode 账号后端
//
// 零第三方依赖，Node.js >= 18。
// 功能：
//  1. 独立账号体系（注册 / 登录 / 用户信息）
//  2. 按用户保存偏好设置（多设备同步）
//  3. Gitee OAuth token 代理（Gitee 不支持 PKCE，必须由后端持有 client_secret）
//
// 启动：node src/server.js
// 环境变量见 backend/README.md

import { createServer } from 'node:http';
import { randomBytes, scryptSync, timingSafeEqual, createHmac } from 'node:crypto';
import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT || 8787);
const DATA_DIR = process.env.DATA_DIR || join(__dirname, '..', 'data');
const DB_FILE = join(DATA_DIR, 'db.json');
const JWT_SECRET =
  process.env.JWT_SECRET || 'dev-only-change-me-slipecode-secret';
const TOKEN_TTL_SECONDS = 60 * 60 * 24 * 30; // 30 天
const MAX_BODY_BYTES = 1024 * 1024;
const PASSWORD_MIN = 8;

const GITEE_CLIENT_ID = process.env.GITEE_CLIENT_ID || '';
const GITEE_CLIENT_SECRET = process.env.GITEE_CLIENT_SECRET || '';
const GITEE_REDIRECT_URI = process.env.GITEE_REDIRECT_URI || '';

// ---------------------------------------------------------------------------
// 存储（单文件 JSON，写入时原子替换；数据量小且单实例部署足够）
// ---------------------------------------------------------------------------

let db = { users: [], settings: {} };
let writeQueue = Promise.resolve();

async function loadDb() {
  await mkdir(DATA_DIR, { recursive: true });
  try {
    const raw = await readFile(DB_FILE, 'utf8');
    const parsed = JSON.parse(raw);
    db = {
      users: Array.isArray(parsed.users) ? parsed.users : [],
      settings: parsed.settings && typeof parsed.settings === 'object'
        ? parsed.settings
        : {},
    };
  } catch (err) {
    if (err.code !== 'ENOENT') throw err;
    await saveDb();
  }
}

function saveDb() {
  writeQueue = writeQueue.then(async () => {
    const tmp = `${DB_FILE}.tmp`;
    await writeFile(tmp, JSON.stringify(db, null, 2), 'utf8');
    await rename(tmp, DB_FILE);
  });
  return writeQueue;
}

// ---------------------------------------------------------------------------
// 密码 / JWT
// ---------------------------------------------------------------------------

function hashPassword(password) {
  const salt = randomBytes(16);
  const hash = scryptSync(password, salt, 64);
  return `${salt.toString('hex')}:${hash.toString('hex')}`;
}

function verifyPassword(password, stored) {
  const [saltHex, hashHex] = String(stored).split(':');
  if (!saltHex || !hashHex) return false;
  const expected = Buffer.from(hashHex, 'hex');
  const actual = scryptSync(password, Buffer.from(saltHex, 'hex'), 64);
  return expected.length === actual.length && timingSafeEqual(expected, actual);
}

const b64url = (buf) =>
  Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');

function signToken(payload) {
  const header = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const body = b64url(JSON.stringify(payload));
  const sig = b64url(createHmac('sha256', JWT_SECRET).update(`${header}.${body}`).digest());
  return `${header}.${body}.${sig}`;
}

function verifyToken(token) {
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

// ---------------------------------------------------------------------------
// HTTP 工具
// ---------------------------------------------------------------------------

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': process.env.CORS_ORIGIN || '*',
  'Access-Control-Allow-Methods': 'GET,POST,PUT,OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type,Authorization',
};

function sendJson(res, status, data) {
  const body = JSON.stringify(data);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    ...CORS_HEADERS,
  });
  res.end(body);
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(Object.assign(new Error('请求体过大'), { status: 413 }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (chunks.length === 0) return resolve({});
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      } catch {
        reject(Object.assign(new Error('JSON 格式不正确'), { status: 400 }));
      }
    });
    req.on('error', reject);
  });
}

function bearer(req) {
  const raw = req.headers.authorization || '';
  const match = /^Bearer\s+(.+)$/i.exec(raw);
  return match ? match[1] : '';
}

function requireUser(req) {
  const payload = verifyToken(bearer(req));
  if (!payload) {
    throw Object.assign(new Error('未登录或登录已过期'), { status: 401 });
  }
  const user = db.users.find((u) => u.id === payload.sub);
  if (!user) {
    throw Object.assign(new Error('账号不存在'), { status: 401 });
  }
  return user;
}

function publicUser(user) {
  return { id: user.id, email: user.email, displayName: user.displayName };
}

function normalizeEmail(value) {
  return String(value || '').trim().toLowerCase();
}

// 简单的登录失败节流（内存级，单实例足够）
const loginAttempts = new Map();
const ATTEMPT_WINDOW_MS = 10 * 60 * 1000;
const ATTEMPT_MAX = 10;

function throttle(key) {
  const now = Date.now();
  const item = loginAttempts.get(key);
  if (!item || now - item.first > ATTEMPT_WINDOW_MS) {
    loginAttempts.set(key, { first: now, count: 1 });
    return;
  }
  item.count += 1;
  if (item.count > ATTEMPT_MAX) {
    throw Object.assign(new Error('尝试次数过多，请稍后再试'), { status: 429 });
  }
}

// ---------------------------------------------------------------------------
// 路由
// ---------------------------------------------------------------------------

async function handleRegister(req, res) {
  throttle(`register:${req.socket.remoteAddress}`);
  const body = await readJson(req);
  const email = normalizeEmail(body.email);
  const password = String(body.password || '');
  const displayName = String(body.displayName || '').trim();

  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
    return sendJson(res, 400, { error: '邮箱格式不正确' });
  }
  if (password.length < PASSWORD_MIN) {
    return sendJson(res, 400, { error: `密码至少 ${PASSWORD_MIN} 位` });
  }
  if (!displayName) {
    return sendJson(res, 400, { error: '昵称不能为空' });
  }
  if (displayName.length > 24) {
    return sendJson(res, 400, { error: '昵称不能超过 24 个字符' });
  }
  if (db.users.some((u) => u.email === email)) {
    return sendJson(res, 409, { error: '该邮箱已注册' });
  }

  const user = {
    id: `u_${randomBytes(8).toString('hex')}`,
    email,
    displayName,
    passwordHash: hashPassword(password),
    createdAt: new Date().toISOString(),
  };
  db.users.push(user);
  await saveDb();

  const token = signToken({
    sub: user.id,
    exp: Math.floor(Date.now() / 1000) + TOKEN_TTL_SECONDS,
  });
  sendJson(res, 201, { token, user: publicUser(user) });
}

async function handleLogin(req, res) {
  const body = await readJson(req);
  const email = normalizeEmail(body.email);
  const password = String(body.password || '');
  throttle(`login:${email || req.socket.remoteAddress}`);

  const user = db.users.find((u) => u.email === email);
  if (!user || !verifyPassword(password, user.passwordHash)) {
    return sendJson(res, 401, { error: '邮箱或密码不正确' });
  }
  loginAttempts.delete(`login:${email}`);

  const token = signToken({
    sub: user.id,
    exp: Math.floor(Date.now() / 1000) + TOKEN_TTL_SECONDS,
  });
  sendJson(res, 200, { token, user: publicUser(user) });
}

async function handleGetSettings(req, res) {
  const user = requireUser(req);
  sendJson(res, 200, { settings: db.settings[user.id] ?? null });
}

async function handlePutSettings(req, res) {
  const user = requireUser(req);
  const body = await readJson(req);
  const settings = body.settings;
  if (!settings || typeof settings !== 'object' || Array.isArray(settings)) {
    return sendJson(res, 400, { error: 'settings 必须是对象' });
  }
  // 限制体积与字段数量，避免被当成任意存储
  const serialized = JSON.stringify(settings);
  if (serialized.length > 16 * 1024) {
    return sendJson(res, 400, { error: '设置内容过大' });
  }
  if (Object.keys(settings).length > 64) {
    return sendJson(res, 400, { error: '设置字段过多' });
  }
  db.settings[user.id] = { ...settings, updatedAt: new Date().toISOString() };
  await saveDb();
  sendJson(res, 200, { ok: true, settings: db.settings[user.id] });
}

// ---------------------------------------------------------------------------
// Gitee OAuth 代理（后端持有 client_secret）
// ---------------------------------------------------------------------------

async function giteeTokenRequest(params) {
  if (!GITEE_CLIENT_ID || !GITEE_CLIENT_SECRET) {
    throw Object.assign(
      new Error('后端未配置 GITEE_CLIENT_ID / GITEE_CLIENT_SECRET'),
      { status: 503 },
    );
  }
  const body = new URLSearchParams({
    client_id: GITEE_CLIENT_ID,
    client_secret: GITEE_CLIENT_SECRET,
    ...params,
  });
  const upstream = await fetch('https://gitee.com/oauth/token', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      Accept: 'application/json',
    },
    body,
  });
  const text = await upstream.text();
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    data = { error: 'invalid_response', error_description: text.slice(0, 300) };
  }
  if (!upstream.ok || !data.access_token) {
    throw Object.assign(
      new Error(data.error_description || data.error || 'Gitee 换取 token 失败'),
      { status: 502 },
    );
  }
  return data;
}

async function handleGiteeToken(req, res) {
  const body = await readJson(req);
  const code = String(body.code || '');
  if (!code) return sendJson(res, 400, { error: '缺少 code' });

  const data = await giteeTokenRequest({
    grant_type: 'authorization_code',
    code,
    redirect_uri: String(body.redirect_uri || GITEE_REDIRECT_URI),
  });
  sendJson(res, 200, {
    access_token: data.access_token,
    refresh_token: data.refresh_token,
    expires_in: data.expires_in,
    scope: data.scope,
    token_type: data.token_type || 'bearer',
  });
}

async function handleGiteeRefresh(req, res) {
  const body = await readJson(req);
  const refreshToken = String(body.refresh_token || '');
  if (!refreshToken) return sendJson(res, 400, { error: '缺少 refresh_token' });

  const data = await giteeTokenRequest({
    grant_type: 'refresh_token',
    refresh_token: refreshToken,
  });
  sendJson(res, 200, {
    access_token: data.access_token,
    refresh_token: data.refresh_token,
    expires_in: data.expires_in,
    scope: data.scope,
    token_type: data.token_type || 'bearer',
  });
}

// ---------------------------------------------------------------------------
// 服务器
// ---------------------------------------------------------------------------

const ROUTES = {
  'GET /api/health': async (req, res) => sendJson(res, 200, { ok: true }),
  'POST /api/auth/register': handleRegister,
  'POST /api/auth/login': handleLogin,
  'GET /api/me': async (req, res) => sendJson(res, 200, { user: publicUser(requireUser(req)) }),
  'GET /api/settings': handleGetSettings,
  'PUT /api/settings': handlePutSettings,
  'POST /api/oauth/gitee/token': handleGiteeToken,
  'POST /api/oauth/gitee/refresh': handleGiteeRefresh,
};

const server = createServer(async (req, res) => {
  if (req.method === 'OPTIONS') {
    res.writeHead(204, CORS_HEADERS);
    res.end();
    return;
  }
  const path = new URL(req.url, 'http://localhost').pathname.replace(/\/+$/, '') || '/';
  const handler = ROUTES[`${req.method} ${path}`];
  if (!handler) {
    sendJson(res, 404, { error: '接口不存在' });
    return;
  }
  try {
    await handler(req, res);
  } catch (err) {
    const status = err.status || 500;
    if (status >= 500) console.error(err);
    sendJson(res, status, { error: err.message || '服务器错误' });
  }
});

await loadDb();
server.listen(PORT, () => {
  console.log(`SlipCode backend listening on http://localhost:${PORT}`);
  if (!process.env.JWT_SECRET) {
    console.warn('[WARN] 未设置 JWT_SECRET，当前使用开发默认值，生产环境必须设置');
  }
});
