// 管理端 API
//
// 鉴权两层：
//  1. Bearer 管理员令牌（登录后签发，8 小时有效）
//  2. 查看用户详情等敏感接口额外要求 X-Admin-Password（二次验证）

import { randomBytes } from 'node:crypto';

import {
  DEFAULT_ADMIN_PASSWORD,
  adminPasswordHash,
  aliyunConfig,
  geetestConfig,
  wechatPayConfig,
  wechatPayPrivateKeyAvailable,
  wechatPayPublicKeyAvailable,
  wechatPayReady,
} from '../config.js';
import { dailySeries, getDb, saveDb, todayStr } from '../db.js';
import { readJson, sendJson } from '../http.js';
import {
  clearAdminLoginThrottle,
  hashPassword,
  issueAdminToken,
  requireAdmin,
  requireAdminPassword,
  throttleAdminLogin,
  verifyAdminPassword,
} from '../security.js';
import { getCredits, applyCredits } from './me.js';

const STARTED_AT = Date.now();

// ---------------------------------------------------------------------------
// 登录
// ---------------------------------------------------------------------------

export async function handleAdminLogin(req, res) {
  throttleAdminLogin(req);
  const body = await readJson(req);
  const password = String(body.password || '');
  if (!verifyAdminPassword(password)) {
    return sendJson(res, 401, { error: '管理员密码不正确' });
  }
  clearAdminLoginThrottle(req);
  sendJson(res, 200, {
    token: issueAdminToken(),
    expiresIn: 8 * 60 * 60,
    mustChangePassword: !adminPasswordHash(),
  });
}

/** 供管理页判断登录态 / 是否仍使用默认密码 */
export async function handleAdminSession(req, res) {
  requireAdmin(req);
  sendJson(res, 200, { ok: true, mustChangePassword: !adminPasswordHash() });
}

// ---------------------------------------------------------------------------
// 统计
// ---------------------------------------------------------------------------

function maskSecret(value) {
  const str = String(value || '');
  if (!str) return '';
  if (str.length <= 8) return '****';
  return `${str.slice(0, 4)}****${str.slice(-4)}`;
}

export async function handleAdminStats(req, res) {
  requireAdmin(req);
  const db = getDb();
  const today = todayStr();
  const todayStats = db.stats.daily[today] || {};

  const users = db.users;
  sendJson(res, 200, {
    totals: db.stats.totals,
    today: {
      registers: todayStats.registers || 0,
      logins: todayStats.logins || 0,
      smsSent: todayStats.smsSent || 0,
      llmCalls: todayStats.llmCalls || 0,
      tokensUsed: todayStats.tokensUsed || 0,
    },
    daily: dailySeries(14),
    llm: {
      models: Object.entries(db.stats.models || {})
        .map(([id, s]) => ({ id, ...s }))
        .sort((a, b) => (b.calls || 0) - (a.calls || 0)),
      channels: Object.values(db.stats.channels || {}).sort(
        (a, b) => (b.calls || 0) - (a.calls || 0),
      ),
    },
    users: {
      count: users.length,
      newToday: users.filter((u) => (u.createdAt || '').slice(0, 10) === today).length,
      activeToday: users.filter((u) => (u.lastLoginAt || '').slice(0, 10) === today).length,
      credits: users.reduce((sum, u) => sum + getCredits(u), 0),
    },
    content: {
      llmModels: db.llmModels.length,
      projects: Object.keys(db.projects).length,
      chatHistories: Object.keys(db.chatHistory).length,
      settings: Object.keys(db.settings).length,
      activationCodes: (db.activationCodes || []).length,
    },
    config: {
      geetest: (() => {
        const g = geetestConfig();
        return {
          captchaId: g.captchaId,
          captchaKeyMasked: maskSecret(g.captchaKey),
          enforce: g.enforce,
          configured: Boolean(g.captchaId && g.captchaKey),
        };
      })(),
      aliyun: (() => {
        const a = aliyunConfig();
        return {
          accessKeyId: a.accessKeyId,
          accessKeySecretMasked: maskSecret(a.accessKeySecret),
          signName: a.signName,
          templateCode: a.templateCode,
          devMode: a.devMode,
          configured: !a.devMode,
        };
      })(),
    },
    server: {
      uptimeSeconds: Math.floor((Date.now() - STARTED_AT) / 1000),
      memoryMb: Math.round(process.memoryUsage().rss / 1024 / 1024),
      nodeVersion: process.version,
    },
  });
}

// ---------------------------------------------------------------------------
// 配置读写
// ---------------------------------------------------------------------------

export async function handleAdminGetConfig(req, res) {
  requireAdmin(req);
  const g = geetestConfig();
  const a = aliyunConfig();
  const w = wechatPayConfig();
  sendJson(res, 200, {
    geetest: {
      captchaId: g.captchaId,
      captchaKey: '', // 不返回明文
      captchaKeyMasked: maskSecret(g.captchaKey),
      enforce: g.enforce,
    },
    aliyun: {
      accessKeyId: a.accessKeyId,
      accessKeySecret: '',
      accessKeySecretMasked: maskSecret(a.accessKeySecret),
      signName: a.signName,
      templateCode: a.templateCode,
      devMode: a.devMode,
    },
    admin: {
      passwordSet: Boolean(adminPasswordHash()),
      usingDefaultPassword: !adminPasswordHash(),
    },
    portal: {
      qqGroup: String(getDb().config?.portal?.qqGroup || ''),
    },
    aiUploads: {
      ...(getDb().config?.aiUploads || {}),
    },
    wechatPay: {
      appId: w.appId,
      appSecret: '',
      appSecretMasked: maskSecret(w.appSecret),
      mchId: w.mchId,
      serialNo: w.serialNo,
      apiV3Key: '',
      apiV3KeyMasked: maskSecret(w.apiV3Key),
      privateKeyPem: '',
      privateKeyConfigured: wechatPayPrivateKeyAvailable(),
      privateKeyPath: w.privateKeyPath,
      publicKeyPem: '',
      publicKeyConfigured: wechatPayPublicKeyAvailable(),
      publicKeyPath: w.publicKeyPath,
      publicKeyId: w.publicKeyId,
      notifyUrl: w.notifyUrl,
      pageBase: w.pageBase,
      ready: wechatPayReady(),
    },
  });
}

/**
 * 保存配置：
 *  - 字段传 `undefined` / 不传 → 保持原值
 *  - 传空字符串 → 清除（回退到环境变量）
 *  - 修改管理员密码需同时提供当前密码（X-Admin-Password）
 */
export async function handleAdminPutConfig(req, res) {
  requireAdmin(req);
  const body = await readJson(req);
  const db = getDb();
  const config = db.config;

  if (body.geetest && typeof body.geetest === 'object') {
    const g = body.geetest;
    if (typeof g.captchaId === 'string') {
      config.geetest.captchaId = g.captchaId.trim().slice(0, 64);
    }
    if (typeof g.captchaKey === 'string' && g.captchaKey.trim()) {
      config.geetest.captchaKey = g.captchaKey.trim().slice(0, 128);
    }
    if (g.captchaKey === '') delete config.geetest.captchaKey;
    if (typeof g.enforce === 'boolean') config.geetest.enforce = g.enforce;
  }

  if (body.aliyun && typeof body.aliyun === 'object') {
    const a = body.aliyun;
    if (typeof a.accessKeyId === 'string') {
      config.aliyun.accessKeyId = a.accessKeyId.trim().slice(0, 64);
    }
    if (typeof a.accessKeySecret === 'string' && a.accessKeySecret.trim()) {
      config.aliyun.accessKeySecret = a.accessKeySecret.trim().slice(0, 128);
    }
    if (a.accessKeySecret === '') delete config.aliyun.accessKeySecret;
    if (typeof a.signName === 'string' && a.signName.trim()) {
      config.aliyun.signName = a.signName.trim().slice(0, 32);
    }
    if (typeof a.templateCode === 'string' && a.templateCode.trim()) {
      config.aliyun.templateCode = a.templateCode.trim().slice(0, 32);
    }
  }

  if (body.portal && typeof body.portal === 'object') {
    if (typeof body.portal.qqGroup === 'string') {
      config.portal.qqGroup = body.portal.qqGroup.trim().slice(0, 32);
    }
  }

  if (body.aiUploads && typeof body.aiUploads === 'object') {
    const limits = body.aiUploads;
    const num = (value, min, max, fallback) => {
      const n = Number(value);
      if (!Number.isFinite(n)) return fallback;
      return Math.min(max, Math.max(min, Math.round(n)));
    };
    config.aiUploads = {
      enabled: limits.enabled !== false,
      maxFiles: num(limits.maxFiles, 1, 20, 5),
      maxFileMb: num(limits.maxFileMb, 1, 100, 10),
      maxTotalMb: num(limits.maxTotalMb, 1, 200, 30),
      maxUnzipFiles: num(limits.maxUnzipFiles, 1, 500, 50),
      maxUnzipMb: num(limits.maxUnzipMb, 1, 500, 50),
    };
  }

  if (body.wechatPay && typeof body.wechatPay === 'object') {
    const w = body.wechatPay;
    if (!config.wechatPay) config.wechatPay = {};
    const setText = (key, max) => {
      if (typeof w[key] === 'string') {
        config.wechatPay[key] = w[key].trim().slice(0, max);
      }
    };
    setText('appId', 64);
    setText('mchId', 32);
    setText('serialNo', 128);
    setText('publicKeyId', 128);
    setText('notifyUrl', 255);
    setText('pageBase', 120);
    setText('privateKeyPath', 255);
    setText('publicKeyPath', 255);

    // 留空表示不修改（避免管理端仅修改其它字段时误清空密钥）
    if (typeof w.appSecret === 'string' && w.appSecret.trim()) {
      config.wechatPay.appSecret = w.appSecret.trim().slice(0, 128);
    }
    if (typeof w.apiV3Key === 'string' && w.apiV3Key.trim()) {
      const key = w.apiV3Key.trim();
      if (key.length !== 32) {
        return sendJson(res, 400, { error: 'APIv3 密钥必须是 32 位字符' });
      }
      config.wechatPay.apiV3Key = key;
    }
    if (typeof w.privateKeyPem === 'string' && w.privateKeyPem.trim()) {
      config.wechatPay.privateKeyPem = w.privateKeyPem.trim();
    }
    if (typeof w.publicKeyPem === 'string' && w.publicKeyPem.trim()) {
      config.wechatPay.publicKeyPem = w.publicKeyPem.trim();
    }
    if (w.clearPrivateKey === true) config.wechatPay.privateKeyPem = '';
    if (w.clearPublicKey === true) config.wechatPay.publicKeyPem = '';
  }

  if (typeof body.adminPassword === 'string' && body.adminPassword) {
    if (body.adminPassword.length < 8) {
      return sendJson(res, 400, { error: '管理员密码至少 8 位' });
    }
    if (!verifyAdminPassword(String(body.currentAdminPassword || ''))) {
      return sendJson(res, 403, { error: '当前管理员密码不正确' });
    }
    config.admin.passwordHash = hashPassword(String(body.adminPassword));
  }

  await saveDb();
  sendJson(res, 200, { ok: true });
}

// ---------------------------------------------------------------------------
// 用户
// ---------------------------------------------------------------------------

function publicAdminUser(u) {
  return {
    id: u.id,
    email: u.email,
    displayName: u.displayName,
    phone: u.phone || '',
    credits: getCredits(u),
    createdAt: u.createdAt || '',
    lastLoginAt: u.lastLoginAt || '',
    lastCheckinDate: u.lastCheckinDate || null,
  };
}

export async function handleAdminUsers(req, res) {
  requireAdmin(req);
  const url = new URL(req.url, 'http://localhost');
  const keyword = String(url.searchParams.get('q') || '').trim().toLowerCase();
  let users = getDb().users.map(publicAdminUser);
  if (keyword) {
    users = users.filter(
      (u) =>
        u.email.toLowerCase().includes(keyword) ||
        u.displayName.toLowerCase().includes(keyword) ||
        u.phone.includes(keyword),
    );
  }
  users.sort((a, b) => (b.createdAt || '').localeCompare(a.createdAt || ''));
  sendJson(res, 200, { users, total: users.length });
}

/** 用户详情：需要管理员令牌 + 管理员密码（二次验证） */
export async function handleAdminUserDetail(req, res, userId) {
  requireAdminPassword(req);
  const user = getDb().users.find((u) => u.id === userId);
  if (!user) return sendJson(res, 404, { error: '用户不存在' });
  const db = getDb();
  const settings = db.settings[user.id];
  const projects = db.projects[user.id] || [];
  const messages = db.chatHistory[user.id] || [];
  sendJson(res, 200, {
    user: {
      ...publicAdminUser(user),
      avatarUrl: user.avatar ? `/api/avatars/${user.id}?v=${user.avatar.version}` : '',
      wallpaper: user.wallpaper
        ? {
            mime: user.wallpaper.mime,
            size: user.wallpaper.size || 0,
            version: user.wallpaper.version,
            updatedAt: user.wallpaper.updatedAt,
          }
        : null,
      passwordHashPresent: Boolean(user.passwordHash),
      credits: getCredits(user),
      creditLogs: Array.isArray(user.creditLogs)
        ? user.creditLogs.slice(-20).reverse()
        : [],
    },
    settings: settings
      ? { keys: Object.keys(settings), updatedAt: settings.updatedAt || '' }
      : null,
    projects: projects.map((p) => ({
      name: p.name,
      path: p.path,
      repoFullName: p.repoFullName || '',
      lastEditedAt: p.lastEditedAt || '',
    })),
    chat: {
      count: messages.length,
      lastTs: messages.length ? messages[messages.length - 1].ts : 0,
    },
  });
}

export async function handleAdminUserCredits(req, res, userId) {
  requireAdmin(req);
  const body = await readJson(req);
  const delta = Number(body.delta);
  if (!Number.isFinite(delta) || !Number.isInteger(delta) || delta === 0) {
    return sendJson(res, 400, { error: 'delta 必须是非零整数（可正可负）' });
  }
  const user = getDb().users.find((u) => u.id === userId);
  if (!user) return sendJson(res, 404, { error: '用户不存在' });
  applyCredits(
    user,
    delta,
    'admin_adjust',
    String(body.note || '管理端调整').slice(0, 80),
  );
  await saveDb();
  sendJson(res, 200, { ok: true, id: user.id, credits: user.credits });
}

// ---------------------------------------------------------------------------
// LLM 模型
// ---------------------------------------------------------------------------

export async function handleAdminListModels(req, res) {
  requireAdmin(req);
  sendJson(res, 200, { models: getDb().llmModels });
}

function readModelFields(body) {
  return {
    name: String(body.name ?? '').trim(),
    apiBase: String(body.apiBase ?? '').trim(),
    apiKey: String(body.apiKey ?? '').trim(),
    model: String(body.model ?? '').trim(),
    description: String(body.description ?? '').trim().slice(0, 120),
    supportsVision: body.supportsVision === true,
  };
}

/** 规范化多线路配置：每条线路 = 一个 BaseURL + APIKey 组合 */
function normalizeChannels(raw) {
  if (!Array.isArray(raw)) return null;
  return raw
    .filter((c) => c && String(c.apiBase || '').trim())
    .slice(0, 10)
    .map((c, index) => ({
      id: String(c.id || '').trim() || `ch_${randomBytes(4).toString('hex')}`,
      name: String(c.name || '').trim() || `线路 ${index + 1}`,
      apiBase: String(c.apiBase).trim(),
      apiKey: String(c.apiKey || '').trim(),
      weight: Number.isFinite(Number(c.weight)) ? Math.max(1, Number(c.weight)) : 1,
      enabled: c.enabled !== false,
    }));
}

function validateMultiplier(value) {
  const multiplier = Number(value);
  if (!Number.isFinite(multiplier) || multiplier <= 0) {
    return null;
  }
  return multiplier;
}

export async function handleAdminCreateModel(req, res) {
  requireAdmin(req);
  const body = await readJson(req);
  const fields = readModelFields(body);
  const channels = normalizeChannels(body.channels);
  const hasChannels = Array.isArray(channels) && channels.length > 0;
  if (!fields.name || !fields.model) {
    return sendJson(res, 400, { error: 'name / model 不能为空' });
  }
  if (!hasChannels && (!fields.apiBase || !fields.apiKey)) {
    return sendJson(res, 400, {
      error: '至少配置一条线路（BaseURL + APIKey）',
    });
  }
  if (hasChannels) {
    fields.apiBase = channels[0].apiBase;
    fields.apiKey = channels[0].apiKey;
  }
  const multiplier =
    body.multiplier === undefined ? 1 : validateMultiplier(body.multiplier);
  if (multiplier === null) {
    return sendJson(res, 400, { error: 'multiplier 必须是大于 0 的数字' });
  }
  const item = {
    id: `m_${randomBytes(6).toString('hex')}`,
    ...fields,
    multiplier,
    channels: hasChannels ? channels : [],
  };
  getDb().llmModels.push(item);
  await saveDb();
  sendJson(res, 201, { model: item });
}

export async function handleAdminUpdateModel(req, res, id) {
  requireAdmin(req);
  const item = getDb().llmModels.find((m) => m.id === id);
  if (!item) return sendJson(res, 404, { error: '模型不存在' });
  const body = await readJson(req);
  const fields = readModelFields(body);
  for (const key of ['name', 'model']) {
    if (body[key] !== undefined) {
      if (!fields[key]) return sendJson(res, 400, { error: `${key} 不能为空` });
      item[key] = fields[key];
    }
  }
  if (body.apiBase !== undefined) {
    if (!fields.apiBase) return sendJson(res, 400, { error: 'apiBase 不能为空' });
    item.apiBase = fields.apiBase;
  }
  if (body.apiKey !== undefined) {
    if (!fields.apiKey) return sendJson(res, 400, { error: 'apiKey 不能为空' });
    item.apiKey = fields.apiKey;
  }
  if (body.description !== undefined) item.description = fields.description;
  if (body.supportsVision !== undefined) {
    item.supportsVision = body.supportsVision === true;
  }
  if (body.channels !== undefined) {
    const channels = normalizeChannels(body.channels);
    if (channels === null) {
      return sendJson(res, 400, { error: 'channels 必须是数组' });
    }
    item.channels = channels;
    // 兼容旧字段：以第一条线路作为默认
    if (channels.length > 0) {
      item.apiBase = channels[0].apiBase;
      item.apiKey = channels[0].apiKey;
    }
  }
  if (body.multiplier !== undefined) {
    const multiplier = validateMultiplier(body.multiplier);
    if (multiplier === null) {
      return sendJson(res, 400, { error: 'multiplier 必须是大于 0 的数字' });
    }
    item.multiplier = multiplier;
  }
  await saveDb();
  sendJson(res, 200, { model: item });
}

export async function handleAdminDeleteModel(req, res, id) {
  requireAdmin(req);
  const index = getDb().llmModels.findIndex((m) => m.id === id);
  if (index === -1) return sendJson(res, 404, { error: '模型不存在' });
  const [removed] = getDb().llmModels.splice(index, 1);
  await saveDb();
  sendJson(res, 200, { ok: true, id: removed.id });
}
