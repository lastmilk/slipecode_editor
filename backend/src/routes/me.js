// 用户自身数据：资料、偏好设置、头像 / 壁纸、积分签到

import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import {
  AVATAR_MAX_BYTES,
  UPLOAD_BODY_LIMIT,
  WALLPAPER_MAX_BYTES,
  activeMembership,
  addMonths,
  checkinRewardFor,
  effectiveMembershipPlan,
  membershipSnapshot,
} from '../config.js';
import { UPLOAD_DIR, getDb, saveDb, todayStr } from '../db.js';
import { readJson, sendBytes, sendJson } from '../http.js';
import { publicUser, requireUser, verifyPassword } from '../security.js';

export async function handleMe(req, res) {
  const user = requireUser(req);
  await settleMembershipCredits(user);
  sendJson(res, 200, { user: publicUser(user) });
}

// ---------------------------------------------------------------------------
// 偏好设置（多设备同步）
// ---------------------------------------------------------------------------

export async function handleGetSettings(req, res) {
  const user = requireUser(req);
  sendJson(res, 200, { settings: getDb().settings[user.id] ?? null });
}

export async function handlePutSettings(req, res) {
  const user = requireUser(req);
  const body = await readJson(req);
  const settings = body.settings;
  if (!settings || typeof settings !== 'object' || Array.isArray(settings)) {
    return sendJson(res, 400, { error: 'settings 必须是对象' });
  }
  // 多模型配置需要较大额度，但仍限制体积与字段数，避免被当成任意存储
  if (JSON.stringify(settings).length > 64 * 1024) {
    return sendJson(res, 400, { error: '设置内容过大' });
  }
  if (Object.keys(settings).length > 128) {
    return sendJson(res, 400, { error: '设置字段过多' });
  }
  const db = getDb();
  db.settings[user.id] = { ...settings, updatedAt: new Date().toISOString() };
  await saveDb();
  sendJson(res, 200, { ok: true, settings: db.settings[user.id] });
}

// ---------------------------------------------------------------------------
// 头像 / 壁纸
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
  const raw = String(body.base64 || body.data || '').replace(/^data:[^;]+;base64,/, '');
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

export async function handleUploadAvatar(req, res) {
  const user = requireUser(req);
  const body = await readJson(req, { limit: UPLOAD_BODY_LIMIT });
  let image;
  try {
    image = decodeBase64Image(body, { maxBytes: AVATAR_MAX_BYTES, allowWebp: false });
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

export async function handleGetAvatar(req, res, userId) {
  const id = decodeURIComponent(userId);
  const user = getDb().users.find((u) => u.id === id);
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

export async function handleUploadWallpaper(req, res) {
  const user = requireUser(req);
  const body = await readJson(req, { limit: UPLOAD_BODY_LIMIT });
  let image;
  try {
    image = decodeBase64Image(body, { maxBytes: WALLPAPER_MAX_BYTES, allowWebp: true });
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

export async function handleGetWallpaper(req, res) {
  const user = requireUser(req);
  const wallpaper = user.wallpaper;
  if (!wallpaper) return sendJson(res, 404, { error: '云端没有壁纸' });
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

export async function handleDeleteWallpaper(req, res) {
  const user = requireUser(req);
  user.wallpaper = null;
  await saveDb();
  sendJson(res, 200, { ok: true });
}

// ---------------------------------------------------------------------------
// 积分
// ---------------------------------------------------------------------------

export function getCredits(user) {
  return Number.isFinite(user.credits) ? user.credits : 0;
}

/**
 * 统一积分变动入口：写余额 + 记流水。
 * @param {object} user 用户对象
 * @param {number} delta 变动值（正数入账，负数扣费）
 * @param {string} type 流水类型：register_bonus / checkin / redeem / llm_usage / admin_adjust
 * @param {string} note 备注
 */
export function applyCredits(user, delta, type, note = '') {
  const amount = Math.trunc(Number(delta) || 0);
  if (!amount) return getCredits(user);
  const before = getCredits(user);
  const after = Math.max(0, before + amount);
  user.credits = after;
  if (!Array.isArray(user.creditLogs)) user.creditLogs = [];
  user.creditLogs.push({
    ts: new Date().toISOString(),
    type,
    amount: after - before,
    balance: after,
    note,
  });
  // 只保留最近 200 条，避免单用户数据无限膨胀
  if (user.creditLogs.length > 200) {
    user.creditLogs.splice(0, user.creditLogs.length - 200);
  }
  return after;
}

/**
 * 结算会员月度积分：会员有效期内，每满一个月发放当月积分。
 * 幂等：以 membership.nextCreditGrantAt 为游标，重复调用不会重复发放。
 * 返回是否有积分入账（调用方需按需 saveDb）。
 */
export async function settleMembershipCredits(user) {
  const membership = activeMembership(user);
  if (!membership) return false;
  const plan = effectiveMembershipPlan(user);
  if (!plan.monthlyCredits) return false;

  const now = Date.now();
  const expiresAt = Date.parse(membership.expiresAt);
  let cursor = Date.parse(membership.nextCreditGrantAt || '');

  if (!Number.isFinite(cursor)) {
    // 老数据/手动开通：从下个月开始发放，本次不补发
    user.membership.nextCreditGrantAt = addMonths(now, 1).toISOString();
    await saveDb();
    return false;
  }

  let granted = 0;
  let guard = 0;
  // 最多补发 24 个月，避免异常数据造成超大金额
  while (cursor <= now && cursor <= expiresAt && guard < 24) {
    granted += plan.monthlyCredits;
    cursor = addMonths(cursor, 1).getTime();
    guard += 1;
  }

  if (guard > 0) {
    user.membership.nextCreditGrantAt = new Date(cursor).toISOString();
  }
  if (!granted) {
    if (guard > 0) await saveDb();
    return false;
  }
  applyCredits(user, granted, 'membership', `${plan.name} 会员月度积分`);
  await saveDb();
  return true;
}

export async function handleGetCreditLogs(req, res) {
  const user = requireUser(req);
  await settleMembershipCredits(user);
  const logs = Array.isArray(user.creditLogs) ? user.creditLogs.slice(-50).reverse() : [];
  sendJson(res, 200, { credits: getCredits(user), logs });
}

export async function handleCheckin(req, res) {
  const user = requireUser(req);
  await settleMembershipCredits(user);
  const today = todayStr();
  if (user.lastCheckinDate === today) {
    return sendJson(res, 200, {
      ok: false,
      message: '今日已签到',
      credits: getCredits(user),
      checkedInToday: true,
      checkinReward: checkinRewardFor(user),
      membership: membershipSnapshot(user),
    });
  }
  const reward = checkinRewardFor(user);
  user.lastCheckinDate = today;
  applyCredits(user, reward, 'checkin', '每日签到');
  await saveDb();
  sendJson(res, 200, {
    ok: true,
    message: `签到成功 +${reward} 积分`,
    credits: user.credits,
    checkedInToday: true,
    checkinReward: reward,
    membership: membershipSnapshot(user),
  });
}

export async function handleGetCredits(req, res) {
  const user = requireUser(req);
  await settleMembershipCredits(user);
  sendJson(res, 200, {
    credits: getCredits(user),
    checkedInToday: user.lastCheckinDate === todayStr(),
    checkinReward: checkinRewardFor(user),
    membership: membershipSnapshot(user),
  });
}

// ---------------------------------------------------------------------------
// 登录设备管理
// ---------------------------------------------------------------------------

export async function handleListDevices(req, res) {
  const user = requireUser(req);
  const db = getDb();
  const devices = (db.loginDevices || [])
    .filter((d) => d.userId === user.id)
    .sort((a, b) =>
      String(b.lastActiveAt || '').localeCompare(String(a.lastActiveAt || '')),
    )
    .map((d) => ({
      id: d.id,
      name: d.name || '未知设备',
      platform: d.platform || '',
      ip: d.ip || '',
      createdAt: d.createdAt || '',
      lastActiveAt: d.lastActiveAt || '',
      current: d.id === req.authDeviceId,
    }));
  sendJson(res, 200, {
    devices,
    currentDeviceId: req.authDeviceId || '',
  });
}

export async function handleRevokeDevice(req, res, id) {
  const user = requireUser(req);
  const db = getDb();
  const device = (db.loginDevices || []).find(
    (d) => d.id === id && d.userId === user.id,
  );
  if (!device) return sendJson(res, 404, { error: '设备不存在或已下线' });

  db.loginDevices = db.loginDevices.filter((d) => d !== device);
  if (!Array.isArray(db.revokedDevices)) db.revokedDevices = [];
  if (!db.revokedDevices.includes(id)) db.revokedDevices.push(id);
  await saveDb();
  sendJson(res, 200, { ok: true, id });
}

/** 注销账号：需要密码确认，删除用户及其社区内容 */
export async function handleDeleteAccount(req, res) {
  const user = requireUser(req);
  const body = await readJson(req);
  const password = String(body.password || '');
  if (!verifyPassword(password, user.passwordHash)) {
    return sendJson(res, 403, { error: '密码不正确，无法注销账号' });
  }

  const db = getDb();
  db.users = db.users.filter((u) => u.id !== user.id);
  db.loginDevices = (db.loginDevices || []).filter(
    (d) => d.userId !== user.id,
  );
  db.communityPosts = (db.communityPosts || []).filter(
    (p) => p.authorId !== user.id,
  );
  db.communityComments = (db.communityComments || []).filter(
    (c) => c.authorId !== user.id,
  );
  db.communityReports = (db.communityReports || []).filter(
    (r) => r.reporterId !== user.id,
  );
  await saveDb();
  sendJson(res, 200, { ok: true, message: '账号已注销' });
}
