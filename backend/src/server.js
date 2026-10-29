// SlipCode 账号后端
//
// 零第三方依赖，Node.js >= 18。
// 功能：
//  1. 独立账号体系（注册 / 登录 / 用户信息）
//  2. 按用户保存偏好设置（多设备同步）
//  3. Gitee / GitHub OAuth token 代理（后端持有 client_secret，客户端不做 PKCE）
//  4. 积分体系（每日签到 +100，积分用于抵扣 LLM 调用）
//  5. OpenAI 兼容的 LLM 内置代理（按 token 计积分）
//  6. 管理端（/admin 静态页 + /api/admin/* 接口，Bearer ADMIN_TOKEN）
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
const ADMIN_HTML_FILE = join(__dirname, '..', 'admin', 'index.html');
const JWT_SECRET =
  process.env.JWT_SECRET || 'dev-only-change-me-slipecode-secret';
const TOKEN_TTL_SECONDS = 60 * 60 * 24 * 30; // 30 天
const MAX_BODY_BYTES = 1024 * 1024;
const PASSWORD_MIN = 8;

const GITEE_CLIENT_ID = process.env.GITEE_CLIENT_ID || '';
const GITEE_CLIENT_SECRET = process.env.GITEE_CLIENT_SECRET || '';
const GITEE_REDIRECT_URI = process.env.GITEE_REDIRECT_URI || '';

// GitHub OAuth（后端持有 client_secret，客户端不再使用 PKCE）
const GITHUB_CLIENT_ID = process.env.GITHUB_CLIENT_ID || '';
const GITHUB_CLIENT_SECRET = process.env.GITHUB_CLIENT_SECRET || '';
// 后端中转回调（GitHub OAuth App 里登记的 Authorization callback URL）
const GITHUB_REDIRECT_URI =
  process.env.GITHUB_REDIRECT_URI ||
  'https://ser1996.niav.cn/api/oauth/github/callback';
// 后端换到 token 后 302 回 App 的深链
const GITHUB_DEEP_LINK =
  process.env.GITHUB_DEEP_LINK || 'slipecode://oauth/callback';
const GITHUB_OAUTH_BASE =
  process.env.GITHUB_OAUTH_BASE || 'https://github.com/login/oauth';
// 一次性票据：ticket → token（5 分钟有效，用后即焚，避免 token 出现在 URL）
const OAUTH_TICKET_TTL_MS = 5 * 60 * 1000;
const oauthTickets = new Map();

// 管理端访问令牌：生产环境务必通过环境变量 ADMIN_TOKEN 覆盖默认值
const ADMIN_TOKEN =
  process.env.ADMIN_TOKEN || 'dev-only-admin-token-7f3a9c1e5b2d48f0-change-me';

const CHECKIN_REWARD = 100;
// 积分计价：1 积分 = 2000 token
const TOKENS_PER_CREDIT = 2000;

// ---------------------------------------------------------------------------
// 存储（单文件 JSON，写入时原子替换；数据量小且单实例部署足够）
// ---------------------------------------------------------------------------

let db = { users: [], settings: {}, llmModels: [] };
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
      llmModels: Array.isArray(parsed.llmModels) ? parsed.llmModels : [],
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
  'Access-Control-Allow-Methods': 'GET,POST,PUT,DELETE,OPTIONS',
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

function requireAdmin(req) {
  const token = Buffer.from(bearer(req));
  const expected = Buffer.from(ADMIN_TOKEN);
  if (token.length !== expected.length || !timingSafeEqual(token, expected)) {
    throw Object.assign(new Error('无管理员权限'), { status: 401 });
  }
}

// 积分 / 日期工具
function getCredits(user) {
  return Number.isFinite(user.credits) ? user.credits : 0;
}

// 服务器本地日期，YYYY-MM-DD
function todayStr() {
  const d = new Date();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${d.getFullYear()}-${m}-${day}`;
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
    credits: 0,
    lastCheckinDate: null,
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
// GitHub OAuth 代理（后端持有 client_secret）
// ---------------------------------------------------------------------------

async function githubTokenRequest(params) {
  if (!GITHUB_CLIENT_ID || !GITHUB_CLIENT_SECRET) {
    throw Object.assign(
      new Error('后端未配置 GITHUB_CLIENT_ID / GITHUB_CLIENT_SECRET'),
      { status: 503 },
    );
  }
  const body = new URLSearchParams({
    client_id: GITHUB_CLIENT_ID,
    client_secret: GITHUB_CLIENT_SECRET,
    ...params,
  });
  const upstream = await fetch(`${GITHUB_OAUTH_BASE}/access_token`, {
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
      new Error(
        data.error_description || data.error || 'GitHub 换取 token 失败',
      ),
      { status: 502 },
    );
  }
  return data;
}

// 只允许 http(s) 回调地址参与换 token；自定义深链无法在 GitHub 侧校验，
// 这种情况由后端中转回调（/api/oauth/github/callback）统一处理。
function resolveGithubRedirectUri(candidate) {
  const value = String(candidate || '');
  if (value.startsWith('http://') || value.startsWith('https://')) {
    return value;
  }
  return GITHUB_REDIRECT_URI;
}

function issueOAuthTicket(tokenData) {
  const now = Date.now();
  for (const [key, value] of oauthTickets) {
    if (value.expiresAt < now) oauthTickets.delete(key);
  }
  const ticket = randomBytes(32).toString('hex');
  oauthTickets.set(ticket, { ...tokenData, expiresAt: now + OAUTH_TICKET_TTL_MS });
  return ticket;
}

/// GitHub 回调中转：GitHub → 本后端 → 302 回 App 深链（带一次性 ticket）
async function handleGithubCallback(req, res) {
  const url = new URL(req.url, 'http://localhost');
  const state = url.searchParams.get('state') || '';
  const redirectToApp = (params) => {
    const query = new URLSearchParams({ state, ...params });
    res.writeHead(302, {
      Location: `${GITHUB_DEEP_LINK}?${query.toString()}`,
      'Cache-Control': 'no-store',
    });
    res.end();
  };

  const error = url.searchParams.get('error');
  if (error) {
    return redirectToApp({
      error,
      error_description: url.searchParams.get('error_description') || '',
    });
  }
  const code = url.searchParams.get('code');
  if (!code) return redirectToApp({ error: 'missing_code' });

  try {
    const data = await githubTokenRequest({
      code,
      redirect_uri: GITHUB_REDIRECT_URI,
    });
    redirectToApp({
      ticket: issueOAuthTicket({
        access_token: data.access_token,
        scope: data.scope || '',
        token_type: data.token_type || 'bearer',
      }),
    });
  } catch (err) {
    console.error('GitHub 回调换取 token 失败：', err.message);
    redirectToApp({ error: 'exchange_failed', error_description: err.message });
  }
}

async function handleGithubToken(req, res) {
  const body = await readJson(req);

  // 方式一：后端中转 callback 已换好 token，用一次性 ticket 领取
  const ticket = String(body.ticket || '');
  if (ticket) {
    const entry = oauthTickets.get(ticket);
    oauthTickets.delete(ticket);
    if (!entry || entry.expiresAt < Date.now()) {
      return sendJson(res, 400, { error: 'ticket 无效或已过期，请重新授权' });
    }
    return sendJson(res, 200, {
      access_token: entry.access_token,
      scope: entry.scope,
      token_type: entry.token_type,
    });
  }

  // 方式二：客户端直接拿到 code（深链回调）时由后端换取
  const code = String(body.code || '');
  if (!code) return sendJson(res, 400, { error: '缺少 code' });

  const data = await githubTokenRequest({
    code,
    redirect_uri: resolveGithubRedirectUri(body.redirect_uri),
  });
  sendJson(res, 200, {
    access_token: data.access_token,
    scope: data.scope,
    token_type: data.token_type || 'bearer',
  });
}

// ---------------------------------------------------------------------------
// 积分：每日签到 / 余额查询
// ---------------------------------------------------------------------------

async function handleCheckin(req, res) {
  const user = requireUser(req);
  const today = todayStr();
  if (user.lastCheckinDate === today) {
    return sendJson(res, 200, {
      ok: false,
      message: '今日已签到',
      credits: getCredits(user),
      checkedInToday: true,
    });
  }
  user.credits = getCredits(user) + CHECKIN_REWARD;
  user.lastCheckinDate = today;
  await saveDb();
  sendJson(res, 200, {
    ok: true,
    message: `签到成功 +${CHECKIN_REWARD} 积分`,
    credits: user.credits,
    checkedInToday: true,
  });
}

async function handleGetCredits(req, res) {
  const user = requireUser(req);
  sendJson(res, 200, {
    credits: getCredits(user),
    checkedInToday: user.lastCheckinDate === todayStr(),
  });
}

// ---------------------------------------------------------------------------
// LLM 内置代理（OpenAI 兼容 /chat/completions，按 token 扣积分）
// ---------------------------------------------------------------------------

function publicLlmModel(m) {
  return { id: m.id, name: m.name, multiplier: m.multiplier ?? 1 };
}

async function handleLlmModels(req, res) {
  requireUser(req);
  sendJson(res, 200, { models: db.llmModels.map(publicLlmModel) });
}

// 上游没有返回 usage 时按字符数粗略估算 token（约 4 字符 ≈ 1 token）
function estimateTokens(messages, data) {
  const promptChars = messages.reduce((sum, m) => {
    if (typeof m?.content === 'string') return sum + m.content.length;
    return sum + JSON.stringify(m?.content ?? '').length;
  }, 0);
  const completionChars = Array.isArray(data?.choices)
    ? data.choices.reduce(
        (sum, c) =>
          sum + (typeof c?.message?.content === 'string' ? c.message.content.length : 0),
        0,
      )
    : 0;
  return Math.ceil(promptChars / 4) + Math.ceil(completionChars / 4);
}

async function handleLlmChat(req, res) {
  const user = requireUser(req);
  const body = await readJson(req);
  const modelId = String(body.model || '');
  const config = db.llmModels.find((m) => m.id === modelId);
  if (!config) return sendJson(res, 400, { error: '模型不存在或已下线' });
  if (!Array.isArray(body.messages) || body.messages.length === 0) {
    return sendJson(res, 400, { error: 'messages 不能为空' });
  }

  const balance = getCredits(user);
  if (balance <= 0) {
    return sendJson(res, 402, { error: '积分不足', credits: balance });
  }

  const upstreamBody = { model: config.model, messages: body.messages };
  if (body.temperature !== undefined) upstreamBody.temperature = body.temperature;

  let upstream;
  let text;
  try {
    upstream = await fetch(`${String(config.apiBase).replace(/\/+$/, '')}/chat/completions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${config.apiKey}`,
      },
      body: JSON.stringify(upstreamBody),
    });
    text = await upstream.text();
  } catch {
    return sendJson(res, 502, { error: '无法连接上游模型服务' });
  }

  let data;
  try {
    data = JSON.parse(text);
  } catch {
    data = null;
  }
  if (!upstream.ok || !data) {
    return sendJson(res, 502, {
      error: '上游模型调用失败',
      upstreamStatus: upstream.status,
      detail: text.slice(0, 300),
    });
  }

  const totalTokens =
    data.usage && Number.isFinite(data.usage.total_tokens)
      ? data.usage.total_tokens
      : estimateTokens(body.messages, data);
  const multiplier = Number.isFinite(config.multiplier) ? config.multiplier : 1;
  const cost = Math.ceil((totalTokens / TOKENS_PER_CREDIT) * multiplier);

  if (getCredits(user) < cost) {
    return sendJson(res, 402, { error: '积分不足', credits: getCredits(user) });
  }
  user.credits = getCredits(user) - cost;
  await saveDb();

  data._credits = { used: cost, remaining: user.credits };
  sendJson(res, 200, data);
}

// ---------------------------------------------------------------------------
// 管理端（Authorization: Bearer <ADMIN_TOKEN>）
// ---------------------------------------------------------------------------

async function handleAdminPage(req, res) {
  try {
    const html = await readFile(ADMIN_HTML_FILE, 'utf8');
    res.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Content-Length': Buffer.byteLength(html),
      ...CORS_HEADERS,
    });
    res.end(html);
  } catch (err) {
    if (err.code === 'ENOENT') {
      return sendJson(res, 404, { error: '管理页面不存在' });
    }
    throw err;
  }
}

async function handleAdminUsers(req, res) {
  requireAdmin(req);
  sendJson(res, 200, {
    users: db.users.map((u) => ({
      id: u.id,
      email: u.email,
      displayName: u.displayName,
      credits: getCredits(u),
      createdAt: u.createdAt,
      lastCheckinDate: u.lastCheckinDate || null,
    })),
  });
}

async function handleAdminUserCredits(req, res, email) {
  requireAdmin(req);
  const body = await readJson(req);
  const delta = Number(body.delta);
  if (!Number.isFinite(delta) || !Number.isInteger(delta) || delta === 0) {
    return sendJson(res, 400, { error: 'delta 必须是非零整数（可正可负）' });
  }
  const user = db.users.find((u) => u.email === normalizeEmail(email));
  if (!user) return sendJson(res, 404, { error: '用户不存在' });
  user.credits = getCredits(user) + delta;
  await saveDb();
  sendJson(res, 200, { ok: true, email: user.email, credits: user.credits });
}

async function handleAdminListModels(req, res) {
  requireAdmin(req);
  sendJson(res, 200, { models: db.llmModels });
}

function readModelFields(body) {
  return {
    name: String(body.name ?? '').trim(),
    apiBase: String(body.apiBase ?? '').trim(),
    apiKey: String(body.apiKey ?? '').trim(),
    model: String(body.model ?? '').trim(),
  };
}

function validateMultiplier(value) {
  const multiplier = Number(value);
  if (!Number.isFinite(multiplier) || multiplier <= 0) {
    throw Object.assign(new Error('multiplier 必须是大于 0 的数字'), { status: 400 });
  }
  return multiplier;
}

async function handleAdminCreateModel(req, res) {
  requireAdmin(req);
  const body = await readJson(req);
  const fields = readModelFields(body);
  if (!fields.name || !fields.apiBase || !fields.apiKey || !fields.model) {
    return sendJson(res, 400, { error: 'name / apiBase / apiKey / model 均不能为空' });
  }
  const multiplier =
    body.multiplier === undefined ? 1 : validateMultiplier(body.multiplier);
  const item = { id: `m_${randomBytes(6).toString('hex')}`, ...fields, multiplier };
  db.llmModels.push(item);
  await saveDb();
  sendJson(res, 201, { model: item });
}

async function handleAdminUpdateModel(req, res, id) {
  requireAdmin(req);
  const item = db.llmModels.find((m) => m.id === id);
  if (!item) return sendJson(res, 404, { error: '模型不存在' });
  const body = await readJson(req);
  const fields = readModelFields(body);
  for (const key of ['name', 'apiBase', 'apiKey', 'model']) {
    if (body[key] !== undefined) {
      if (!fields[key]) {
        return sendJson(res, 400, { error: `${key} 不能为空` });
      }
      item[key] = fields[key];
    }
  }
  if (body.multiplier !== undefined) {
    item.multiplier = validateMultiplier(body.multiplier);
  }
  await saveDb();
  sendJson(res, 200, { model: item });
}

async function handleAdminDeleteModel(req, res, id) {
  requireAdmin(req);
  const index = db.llmModels.findIndex((m) => m.id === id);
  if (index === -1) return sendJson(res, 404, { error: '模型不存在' });
  const [removed] = db.llmModels.splice(index, 1);
  await saveDb();
  sendJson(res, 200, { ok: true, id: removed.id });
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
  'POST /api/oauth/github/token': handleGithubToken,
  'GET /api/oauth/github/callback': handleGithubCallback,
  'POST /api/checkin': handleCheckin,
  'GET /api/credits': handleGetCredits,
  'GET /api/llm/models': handleLlmModels,
  'POST /api/llm/chat': handleLlmChat,
  'GET /admin': handleAdminPage,
  'GET /api/admin/users': handleAdminUsers,
  'GET /api/admin/llm/models': handleAdminListModels,
  'POST /api/admin/llm/models': handleAdminCreateModel,
};

// 带路径参数的路由（正则捕获，handler 第三个参数为 match 结果）
const DYNAMIC_ROUTES = [
  {
    method: 'POST',
    pattern: /^\/api\/admin\/users\/([^/]+)\/credits$/,
    handler: (req, res, match) =>
      handleAdminUserCredits(req, res, decodeURIComponent(match[1])),
  },
  {
    method: 'PUT',
    pattern: /^\/api\/admin\/llm\/models\/([^/]+)$/,
    handler: (req, res, match) => handleAdminUpdateModel(req, res, match[1]),
  },
  {
    method: 'DELETE',
    pattern: /^\/api\/admin\/llm\/models\/([^/]+)$/,
    handler: (req, res, match) => handleAdminDeleteModel(req, res, match[1]),
  },
];

const server = createServer(async (req, res) => {
  if (req.method === 'OPTIONS') {
    res.writeHead(204, CORS_HEADERS);
    res.end();
    return;
  }
  const path = new URL(req.url, 'http://localhost').pathname.replace(/\/+$/, '') || '/';
  let handler = ROUTES[`${req.method} ${path}`];
  if (!handler) {
    for (const route of DYNAMIC_ROUTES) {
      if (route.method !== req.method) continue;
      const match = route.pattern.exec(path);
      if (match) {
        handler = (rq, rs) => route.handler(rq, rs, match);
        break;
      }
    }
  }
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
  if (!process.env.ADMIN_TOKEN) {
    console.warn('[WARN] 未设置 ADMIN_TOKEN，当前使用开发默认值，生产环境必须设置');
  }
});
