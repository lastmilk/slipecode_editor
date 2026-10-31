// 用户自身数据：资料、偏好设置、头像 / 壁纸、积分签到

import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import {
  AVATAR_MAX_BYTES,
  CHECKIN_REWARD,
  UPLOAD_BODY_LIMIT,
  WALLPAPER_MAX_BYTES,
} from '../config.js';
import { UPLOAD_DIR, getDb, saveDb, todayStr } from '../db.js';
import { readJson, sendBytes, sendJson } from '../http.js';
import { publicUser, requireUser } from '../security.js';

export async function handleMe(req, res) {
  sendJson(res, 200, { user: publicUser(requireUser(req)) });
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

export async function handleCheckin(req, res) {
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

export async function handleGetCredits(req, res) {
  const user = requireUser(req);
  sendJson(res, 200, {
    credits: getCredits(user),
    checkedInToday: user.lastCheckinDate === todayStr(),
  });
}
