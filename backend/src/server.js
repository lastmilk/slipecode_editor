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
import {
  randomBytes,
  scryptSync,
  timingSafeEqual,
  createHmac,
} from 'node:crypto';
import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT || 8787);
const DATA_DIR = process.env.DATA_DIR || join(__dirname, '..', 'data');
const DB_FILE = join(DATA_DIR, 'db.json');
// 用户上传的头像 / 壁纸
const UPLOAD_DIR = join(DATA_DIR, 'uploads');
const UPLOAD_BODY_LIMIT = 8 * 1024 * 1024;
const AVATAR_MAX_BYTES = 2 * 1024 * 1024;
const WALLPAPER_MAX_BYTES = 5 * 1024 * 1024;
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

// 极验验证码（GT4）：Captcha ID 为公开信息，Key 仅保存在服务端
const GEETEST_CAPTCHA_ID =
  process.env.GEETEST_CAPTCHA_ID || 'bad52dace656f61eab4b052c157d00b2';
const GEETEST_CAPTCHA_KEY =
  process.env.GEETEST_CAPTCHA_KEY || 'f14be37e33e7104c769f84d8470eef9e';
// GEETEST_ENFORCE=0 可关闭强制校验（仅用于本地调试）
const GEETEST_ENFORCE = (process.env.GEETEST_ENFORCE || '1') !== '0';

// 阿里云号码认证服务（DyPnsApi 2017-05-25）——短信验证码
const ALIYUN_ACCESS_KEY_ID = process.env.ALIYUN_ACCESS_KEY_ID || '';
const ALIYUN_ACCESS_KEY_SECRET = process.env.ALIYUN_ACCESS_KEY_SECRET || '';
const ALIYUN_DYPNS_ENDPOINT =
  process.env.ALIYUN_DYPNS_ENDPOINT || 'dypnsapi.aliyuncs.com';
const ALIYUN_REGION = process.env.ALIYUN_REGION || 'cn-hangzhou';
const ALIYUN_SMS_SIGN_NAME = process.env.ALIYUN_SMS_SIGN_NAME || '恒创联众';
const ALIYUN_SMS_TEMPLATE_CODE =
  process.env.ALIYUN_SMS_TEMPLATE_CODE || '100001';
const SMS_VALID_MINUTES = Number(process.env.ALIYUN_SMS_VALID_MINUTES || 5);
const SMS_DAILY_LIMIT = Number(process.env.ALIYUN_SMS_DAILY_LIMIT || 5);
// 未配置凭据时使用开发模式：发送接口返回固定验证码，注册接受该验证码
const SMS_DEV_MODE = !ALIYUN_ACCESS_KEY_ID || !ALIYUN_ACCESS_KEY_SECRET;
const SMS_DEV_CODE = '123456';
const PHONE_PATTERN = /^1[3-9]\d{9}$/;

const CHECKIN_REWARD = 100;
// 积分计价：1 积分 = 2000 token
const TOKENS_PER_CREDIT = 2000;

// ---------------------------------------------------------------------------
// 存储（单文件 JSON，写入时原子替换；数据量小且单实例部署足够）
// ---------------------------------------------------------------------------

let db = {
  users: [],
  settings: {},
  llmModels: [],
  projects: {},
  chatHistory: {},
};
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
      projects: parsed.projects && typeof parsed.projects === 'object'
        ? parsed.projects
        : {},
      chatHistory:
        parsed.chatHistory && typeof parsed.chatHistory === 'object'
          ? parsed.chatHistory
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

function readJson(req, { limit = MAX_BODY_BYTES } = {}) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > limit) {
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

/** 输出二进制（头像 / 壁纸下载） */
function sendBytes(res, status, buffer, contentType) {
  res.writeHead(status, {
    'Content-Type': contentType,
    'Content-Length': buffer.length,
    'Cache-Control': 'no-cache',
    ...CORS_HEADERS,
  });
  res.end(buffer);
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
  return {
    id: user.id,
    email: user.email,
    displayName: user.displayName,
    phone: user.phone || '',
    avatarUrl: user.avatar
      ? `/api/avatars/${user.id}?v=${user.avatar.version}`
      : '',
    wallpaperVersion: user.wallpaper?.version || '',
  };
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

function normalizePhone(value) {
  return String(value || '').replace(/[\s-]/g, '');
}

// ---------------------------------------------------------------------------
// 极验验证（GT4 二次校验）
// ---------------------------------------------------------------------------

/**
 * 校验客户端 SDK 返回的极验结果。
 *
 * @param {object} captcha { lot_number, captcha_output, pass_token, gen_time }
 * @returns {Promise<boolean>}
 */
async function verifyGeetest(captcha) {
  if (!captcha || typeof captcha !== 'object') return false;
  const lotNumber = String(captcha.lot_number || '');
  const captchaOutput = String(captcha.captcha_output || '');
  const passToken = String(captcha.pass_token || '');
  const genTime = String(captcha.gen_time || '');
  if (!lotNumber || !captchaOutput || !passToken || !genTime) return false;

  const signToken = createHmac('sha256', GEETEST_CAPTCHA_KEY)
    .update(lotNumber)
    .digest('hex');
  const form = new URLSearchParams({
    lot_number: lotNumber,
    captcha_output: captchaOutput,
    pass_token: passToken,
    gen_time: genTime,
    sign_token: signToken,
  });

  try {
    const res = await fetch(
      `https://gcaptcha4.geetest.com/validate?captcha_id=${encodeURIComponent(
        GEETEST_CAPTCHA_ID,
      )}`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: form,
        signal: AbortSignal.timeout(6000),
      },
    );
    const data = await res.json().catch(() => null);
    return Boolean(data && data.result === 'success');
  } catch (err) {
    console.warn('[geetest] 校验失败：', err.message);
    return false;
  }
}

/**
 * 注册/登录统一的人机验证拦截。
 * 非 Android 平台（客户端声明 unsupported）在强制模式下放行。
 */
async function requireCaptchaIfNeeded(req, body) {
  if (!GEETEST_ENFORCE) return true;
  if (body.captchaPlatform === 'unsupported') {
    console.warn('[geetest] 客户端平台不支持验证码，已放行');
    return true;
  }
  return verifyGeetest(body.captcha);
}

// ---------------------------------------------------------------------------
// 阿里云短信验证码（DyPnsApi 2017-05-25，V1 RPC 签名，零依赖）
// ---------------------------------------------------------------------------

function percentEncode(value) {
  return encodeURIComponent(String(value)).replace(
    /[!'()*]/g,
    (ch) => `%${ch.charCodeAt(0).toString(16).toUpperCase()}`,
  );
}

async function aliyunRpc(action, params) {
  const common = {
    AccessKeyId: ALIYUN_ACCESS_KEY_ID,
    Action: action,
    Format: 'JSON',
    RegionId: ALIYUN_REGION,
    SignatureMethod: 'HMAC-SHA1',
    SignatureNonce: randomBytes(16).toString('hex'),
    SignatureVersion: '1.0',
    Timestamp: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
    Version: '2017-05-25',
    ...params,
  };
  const sorted = Object.keys(common)
    .sort()
    .map((key) => `${percentEncode(key)}=${percentEncode(common[key])}`)
    .join('&');
  const stringToSign = `GET&${percentEncode('/')}&${percentEncode(sorted)}`;
  const signature = createHmac('sha1', `${ALIYUN_ACCESS_KEY_SECRET}&`)
    .update(stringToSign)
    .digest('base64');
  const url = `https://${ALIYUN_DYPNS_ENDPOINT}/?${sorted}&Signature=${percentEncode(
    signature,
  )}`;

  const res = await fetch(url, { signal: AbortSignal.timeout(8000) });
  const text = await res.text();
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    throw Object.assign(new Error('短信服务响应异常'), { status: 502 });
  }
  if (!res.ok || data.Code) {
    throw Object.assign(new Error(data.Message || '短信服务调用失败'), {
      status: 502,
      detail: data.Code,
    });
  }
  return data;
}

async function sendSmsVerifyCode(phone) {
  return aliyunRpc('SendSmsVerifyCode', {
    PhoneNumber: phone,
    SignName: ALIYUN_SMS_SIGN_NAME,
    TemplateCode: ALIYUN_SMS_TEMPLATE_CODE,
    TemplateParam: JSON.stringify({ code: '', min: SMS_VALID_MINUTES }),
    CodeLength: 6,
    ValidTime: SMS_VALID_MINUTES * 60,
  });
}

async function checkSmsVerifyCode(phone, code) {
  if (SMS_DEV_MODE) return code === SMS_DEV_CODE;
  const data = await aliyunRpc('CheckSmsVerifyCode', {
    PhoneNumber: phone,
    VerifyCode: code,
  });
  return data?.Model?.VerifyResult === 'PASS';
}

// 短信发送节流：同一手机号 60s 一次、每天上限 N 次
const smsSends = new Map();

function throttleSms(phone) {
  const now = Date.now();
  const today = todayStr();
  const item = smsSends.get(phone);
  if (item && now - item.last < 60 * 1000) {
    throw Object.assign(new Error('验证码发送过于频繁，请稍后再试'), {
      status: 429,
    });
  }
  if (item && item.day === today && item.count >= SMS_DAILY_LIMIT) {
    throw Object.assign(new Error('今日验证码发送次数已达上限'), {
      status: 429,
    });
  }
  smsSends.set(phone, {
    last: now,
    day: today,
    count: item && item.day === today ? item.count + 1 : 1,
  });
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
  const phone = normalizePhone(body.phone);
  const smsCode = String(body.smsCode || '').trim();

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
  if (!PHONE_PATTERN.test(phone)) {
    return sendJson(res, 400, { error: '手机号格式不正确' });
  }
  if (!smsCode) {
    return sendJson(res, 400, { error: '请填写短信验证码' });
  }
  if (db.users.some((u) => u.email === email)) {
    return sendJson(res, 409, { error: '该邮箱已注册' });
  }
  if (db.users.some((u) => u.phone === phone)) {
    return sendJson(res, 409, { error: '该手机号已注册' });
  }

  // 人机验证（极验）
  if (!(await requireCaptchaIfNeeded(req, body))) {
    return sendJson(res, 400, { error: '人机验证失败，请重试' });
  }

  // 短信验证码校验
  let smsOk = false;
  try {
    smsOk = await checkSmsVerifyCode(phone, smsCode);
  } catch (err) {
    return sendJson(res, 502, { error: err.message || '短信验证码校验失败' });
  }
  if (!smsOk) {
    return sendJson(res, 400, { error: '短信验证码不正确或已过期' });
  }

  const user = {
    id: `u_${randomBytes(8).toString('hex')}`,
    email,
    displayName,
    phone,
    avatarUrl: '',
    wallpaper: null,
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

/** 发送短信验证码（注册用） */
async function handleSendSmsCode(req, res) {
  const body = await readJson(req);
  const phone = normalizePhone(body.phone);
  if (!PHONE_PATTERN.test(phone)) {
    return sendJson(res, 400, { error: '手机号格式不正确' });
  }
  if (db.users.some((u) => u.phone === phone)) {
    return sendJson(res, 409, { error: '该手机号已注册，请直接登录' });
  }
  throttle(`sms-ip:${req.socket.remoteAddress}`);
  throttleSms(phone);

  if (SMS_DEV_MODE) {
    return sendJson(res, 200, { ok: true, dev: true, devCode: SMS_DEV_CODE });
  }
  try {
    await sendSmsVerifyCode(phone);
  } catch (err) {
    return sendJson(res, 502, { error: err.message || '短信发送失败' });
  }
  sendJson(res, 200, { ok: true, dev: false });
}

/** 极验结果独立校验（客户端也可在登录/注册前预校验） */
async function handleCaptchaValidate(req, res) {
  const body = await readJson(req);
  const ok = await verifyGeetest(body.captcha);
  if (!ok) return sendJson(res, 400, { ok: false, error: '人机验证失败' });
  sendJson(res, 200, { ok: true });
}

async function handleLogin(req, res) {
  const body = await readJson(req);
  const email = normalizeEmail(body.email);
  const password = String(body.password || '');
  throttle(`login:${email || req.socket.remoteAddress}`);

  if (!(await requireCaptchaIfNeeded(req, body))) {
    return sendJson(res, 400, { error: '人机验证失败，请重试' });
  }

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
  // 限制体积与字段数量，避免被当成任意存储（多模型配置需要更大额度）
  const serialized = JSON.stringify(settings);
  if (serialized.length > 64 * 1024) {
    return sendJson(res, 400, { error: '设置内容过大' });
  }
  if (Object.keys(settings).length > 128) {
    return sendJson(res, 400, { error: '设置字段过多' });
  }
  db.settings[user.id] = { ...settings, updatedAt: new Date().toISOString() };
  await saveDb();
  sendJson(res, 200, { ok: true, settings: db.settings[user.id] });
}

// ---------------------------------------------------------------------------
// 项目列表云同步（路径 + 仓库映射）
// ---------------------------------------------------------------------------

async function handleGetProjects(req, res) {
  const user = requireUser(req);
  sendJson(res, 200, { projects: db.projects[user.id] || [] });
}

async function handlePutProjects(req, res) {
  const user = requireUser(req);
  const body = await readJson(req);
  const list = Array.isArray(body.projects) ? body.projects : null;
  if (!list) return sendJson(res, 400, { error: 'projects 必须是数组' });
  if (list.length > 100) {
    return sendJson(res, 400, { error: '项目数量过多（最多 100 个）' });
  }
  const cleaned = list
    .map((item) => ({
      path: String(item?.path || '').slice(0, 512),
      name: String(item?.name || '').slice(0, 128),
      repoFullName: item?.repoFullName
        ? String(item.repoFullName).slice(0, 200)
        : undefined,
      host: item?.host ? String(item.host).slice(0, 16) : undefined,
      lastEditedAt: item?.lastEditedAt
        ? String(item.lastEditedAt).slice(0, 40)
        : undefined,
    }))
    .filter((item) => item.path);
  if (JSON.stringify(cleaned).length > 32 * 1024) {
    return sendJson(res, 400, { error: '项目列表过大' });
  }
  db.projects[user.id] = cleaned;
  await saveDb();
  sendJson(res, 200, { ok: true, projects: cleaned });
}

// ---------------------------------------------------------------------------
// AI 对话记录云同步（可选开启）
// ---------------------------------------------------------------------------

async function handleGetChatHistory(req, res) {
  const user = requireUser(req);
  sendJson(res, 200, { messages: db.chatHistory[user.id] || [] });
}

async function handlePutChatHistory(req, res) {
  const user = requireUser(req);
  const body = await readJson(req, { limit: 512 * 1024 });
  const list = Array.isArray(body.messages) ? body.messages : null;
  if (!list) return sendJson(res, 400, { error: 'messages 必须是数组' });
  const cleaned = list
    .filter((m) => m && (m.role === 'user' || m.role === 'assistant'))
    .map((m) => ({
      role: m.role,
      content: String(m.content || '').slice(0, 20000),
      ts: Number.isFinite(m.ts) ? m.ts : Date.now(),
    }))
    .slice(-200);
  if (JSON.stringify(cleaned).length > 256 * 1024) {
    return sendJson(res, 400, { error: '对话记录过大' });
  }
  db.chatHistory[user.id] = cleaned;
  await saveDb();
  sendJson(res, 200, { ok: true, count: cleaned.length });
}

async function handleDeleteChatHistory(req, res) {
  const user = requireUser(req);
  db.chatHistory[user.id] = [];
  await saveDb();
  sendJson(res, 200, { ok: true });
}

// ---------------------------------------------------------------------------
// 头像 / 壁纸上传
// ---------------------------------------------------------------------------

const MIME_TO_EXT = {
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/jpg': 'jpg',
  'image/webp': 'webp',
};

function decodeBase64Image(body, { maxBytes, allowWebp }) {
  const mime = String(body.mime || '').toLowerCase();
  const ext = MIME_TO_EXT[mime];
  if (!ext) {
    throw Object.assign(new Error('仅支持 png / jpg / webp 图片'), { status: 400 });
  }
  if (!allowWebp && ext === 'webp') {
    throw Object.assign(new Error('该位置不支持 webp，请使用 png / jpg'), {
      status: 400,
    });
  }
  const raw = String(body.base64 || body.data || '').replace(
    /^data:[^;]+;base64,/,
    '',
  );
  const buffer = Buffer.from(raw, 'base64');
  if (!buffer.length) {
    throw Object.assign(new Error('图片内容为空'), { status: 400 });
  }
  if (buffer.length > maxBytes) {
    throw Object.assign(
      new Error(`图片过大（上限 ${Math.round(maxBytes / 1024 / 1024)}MB）`),
      { status: 413 },
    );
  }
  return { buffer, mime, ext };
}

async function handleUploadAvatar(req, res) {
  const user = requireUser(req);
  const body = await readJson(req, { limit: UPLOAD_BODY_LIMIT });
  let image;
  try {
    image = decodeBase64Image(body, {
      maxBytes: AVATAR_MAX_BYTES,
      allowWebp: false,
    });
  } catch (err) {
    return sendJson(res, err.status || 400, { error: err.message });
  }
  const dir = join(UPLOAD_DIR, user.id);
  await mkdir(dir, { recursive: true });
  const filename = `avatar.${image.ext}`;
  await writeFile(join(dir, filename), image.buffer);
  user.avatar = {
    file: filename,
    mime: image.mime,
    version: Date.now().toString(36),
    updatedAt: new Date().toISOString(),
  };
  await saveDb();
  sendJson(res, 200, {
    ok: true,
    avatarUrl: `/api/avatars/${user.id}?v=${user.avatar.version}`,
  });
}

async function handleGetAvatar(req, res, match) {
  const userId = decodeURIComponent(match[1]);
  const user = db.users.find((u) => u.id === userId);
  if (!user || !user.avatar) {
    return sendJson(res, 404, { error: '头像不存在' });
  }
  try {
    const buffer = await readFile(join(UPLOAD_DIR, user.id, user.avatar.file));
    sendBytes(res, 200, buffer, user.avatar.mime);
  } catch {
    sendJson(res, 404, { error: '头像文件缺失' });
  }
}

async function handleUploadWallpaper(req, res) {
  const user = requireUser(req);
  const body = await readJson(req, { limit: UPLOAD_BODY_LIMIT });
  let image;
  try {
    image = decodeBase64Image(body, {
      maxBytes: WALLPAPER_MAX_BYTES,
      allowWebp: true,
    });
  } catch (err) {
    return sendJson(res, err.status || 400, { error: err.message });
  }
  const dir = join(UPLOAD_DIR, user.id);
  await mkdir(dir, { recursive: true });
  const filename = `wallpaper.${image.ext}`;
  await writeFile(join(dir, filename), image.buffer);
  user.wallpaper = {
    file: filename,
    mime: image.mime,
    size: image.buffer.length,
    version: Date.now().toString(36),
    updatedAt: new Date().toISOString(),
  };
  await saveDb();
  sendJson(res, 200, {
    ok: true,
    version: user.wallpaper.version,
    updatedAt: user.wallpaper.updatedAt,
  });
}

async function handleGetWallpaper(req, res) {
  const user = requireUser(req);
  const wallpaper = user.wallpaper;
  if (!wallpaper) {
    return sendJson(res, 404, { error: '云端没有壁纸' });
  }
  try {
    const buffer = await readFile(join(UPLOAD_DIR, user.id, wallpaper.file));
    sendJson(res, 200, {
      base64: buffer.toString('base64'),
      mime: wallpaper.mime,
      version: wallpaper.version,
      updatedAt: wallpaper.updatedAt,
    });
  } catch {
    sendJson(res, 404, { error: '壁纸文件缺失' });
  }
}

async function handleDeleteWallpaper(req, res) {
  const user = requireUser(req);
  user.wallpaper = null;
  await saveDb();
  sendJson(res, 200, { ok: true });
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
  // Agent 的 MCP 工具调用需要透传 function-calling 参数
  if (Array.isArray(body.tools) && body.tools.length > 0) {
    upstreamBody.tools = body.tools;
    if (body.tool_choice !== undefined) upstreamBody.tool_choice = body.tool_choice;
  }

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
  'POST /api/auth/sms/send': handleSendSmsCode,
  'POST /api/auth/captcha/validate': handleCaptchaValidate,
  'GET /api/me': async (req, res) => sendJson(res, 200, { user: publicUser(requireUser(req)) }),
  'GET /api/settings': handleGetSettings,
  'PUT /api/settings': handlePutSettings,
  'GET /api/projects': handleGetProjects,
  'PUT /api/projects': handlePutProjects,
  'GET /api/chat/history': handleGetChatHistory,
  'PUT /api/chat/history': handlePutChatHistory,
  'DELETE /api/chat/history': handleDeleteChatHistory,
  'POST /api/me/avatar': handleUploadAvatar,
  'POST /api/me/wallpaper': handleUploadWallpaper,
  'GET /api/me/wallpaper': handleGetWallpaper,
  'DELETE /api/me/wallpaper': handleDeleteWallpaper,
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
    method: 'GET',
    pattern: /^\/api\/avatars\/([^/]+)$/,
    handler: (req, res, match) => handleGetAvatar(req, res, match),
  },
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
