// 安装包发布管理（官网下载）
//
// 管理端上传最新 Android APK（二进制流，元数据走 query），
// 官网通过公开接口读取版本信息并下载。
// 文件落盘 DATA_DIR/releases/，元数据存 db.release。

import { createHash } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { mkdir, open, readFile, rename, stat, unlink } from 'node:fs/promises';
import { join } from 'node:path';

import { DATA_DIR, getDb, saveDb } from '../db.js';
import { httpError, sendJson } from '../http.js';
import { requireAdmin } from '../security.js';

const RELEASE_DIR = join(DATA_DIR, 'releases');
const RELEASE_FILE = 'slipecode-latest.apk';
/** APK 体积上限 300MB */
const MAX_BYTES = 300 * 1024 * 1024;

const VERSION_PATTERN = /^[0-9A-Za-z.+-]{1,32}$/;
const MAX_NOTES = 4000;

export function publicRelease(release) {
  return {
    version: release.version,
    notes: release.notes || '',
    size: release.size,
    sha256: release.sha256 || '',
    downloads: release.downloads || 0,
    updatedAt: release.updatedAt,
    url: '/api/releases/download',
  };
}

// ---------------------------------------------------------------------------
// 公开接口（官网）
// ---------------------------------------------------------------------------

/** 最新版本信息（未发布时 404，官网据此显示「即将发布」） */
export async function handleGetLatestRelease(req, res) {
  const release = getDb().release;
  if (!release || !release.version) {
    return sendJson(res, 404, { error: '暂未发布安装包' });
  }
  sendJson(res, 200, { release: publicRelease(release) });
}

/** 下载最新 APK（支持 HEAD 预检；GET 计数并输出文件） */
export async function handleDownloadRelease(req, res) {
  const release = getDb().release;
  if (!release || !release.version) {
    return sendJson(res, 404, { error: '暂未发布安装包' });
  }
  let buffer;
  try {
    buffer = await readFile(join(RELEASE_DIR, release.file || RELEASE_FILE));
  } catch {
    return sendJson(res, 404, { error: '安装包文件缺失，请联系管理员重新上传' });
  }
  const headers = {
    'Content-Type': 'application/vnd.android.package-archive',
    'Content-Length': buffer.length,
    'Content-Disposition': `attachment; filename="slipecode-${release.version}.apk"`,
    'Cache-Control': 'no-cache',
  };
  if (req.method === 'HEAD') {
    res.writeHead(200, headers);
    res.end();
    return;
  }
  release.downloads = (release.downloads || 0) + 1;
  saveDb().catch(() => {});
  res.writeHead(200, headers);
  res.end(buffer);
}

// ---------------------------------------------------------------------------
// 管理端接口
// ---------------------------------------------------------------------------

/** 当前发布信息（含文件是否真实存在） */
export async function handleAdminGetRelease(req, res) {
  requireAdmin(req);
  const release = getDb().release;
  if (!release || !release.version) {
    return sendJson(res, 200, { release: null });
  }
  let fileExists = false;
  try {
    const info = await stat(join(RELEASE_DIR, release.file || RELEASE_FILE));
    fileExists = info.isFile();
  } catch {
    fileExists = false;
  }
  sendJson(res, 200, { release: { ...publicRelease(release), fileExists } });
}

/**
 * 上传最新 APK：
 *   POST /api/admin/releases?version=1.2.0&notes=更新说明
 *   Body 为 APK 二进制流（Content-Type: application/octet-stream）
 * 覆盖旧版本，写临时文件后原子替换。
 */
export async function handleAdminUploadRelease(req, res) {
  requireAdmin(req);
  const url = new URL(req.url, 'http://localhost');
  const version = String(url.searchParams.get('version') || '').trim();
  const notes = String(url.searchParams.get('notes') || '').trim().slice(0, MAX_NOTES);
  if (!VERSION_PATTERN.test(version)) {
    return sendJson(res, 400, { error: '版本号格式不正确（仅字母数字 . + -，最长 32 位）' });
  }

  await mkdir(RELEASE_DIR, { recursive: true });
  const tmpFile = join(RELEASE_DIR, `.uploading-${Date.now()}.tmp`);
  const hash = createHash('sha256');
  let size = 0;
  let tooLarge = false;

  try {
    await new Promise((resolve, reject) => {
      const out = createWriteStream(tmpFile);
      req.on('data', (chunk) => {
        size += chunk.length;
        if (size > MAX_BYTES) {
          tooLarge = true;
          out.destroy();
          req.destroy();
          reject(httpError(413, '安装包过大（上限 300MB）'));
          return;
        }
        hash.update(chunk);
        if (!out.write(chunk)) {
          req.pause();
          out.once('drain', () => req.resume());
        }
      });
      req.on('end', () => out.end((err) => (err ? reject(err) : resolve())));
      req.on('error', reject);
      out.on('error', reject);
    });
  } catch (err) {
    await unlink(tmpFile).catch(() => {});
    if (tooLarge) throw err;
    throw Object.assign(err.status ? err : new Error('上传失败'), {
      status: err.status || 500,
    });
  }

  if (!size) {
    await unlink(tmpFile).catch(() => {});
    return sendJson(res, 400, { error: '安装包内容为空' });
  }

  // APK 魔数校验（ZIP：PK）
  const handle = await open(tmpFile, 'r');
  const head = Buffer.alloc(4);
  await handle.read(head, 0, 4, 0);
  await handle.close();
  if (head[0] !== 0x50 || head[1] !== 0x4b) {
    await unlink(tmpFile).catch(() => {});
    return sendJson(res, 400, { error: '文件不是有效的 APK（ZIP 魔数校验失败）' });
  }

  await rename(tmpFile, join(RELEASE_DIR, RELEASE_FILE));
  const db = getDb();
  db.release = {
    version,
    notes,
    size,
    sha256: hash.digest('hex'),
    file: RELEASE_FILE,
    downloads: db.release?.downloads || 0,
    updatedAt: new Date().toISOString(),
  };
  await saveDb();
  sendJson(res, 200, { ok: true, release: publicRelease(db.release) });
}

/** 下架当前安装包（删除文件并清空元数据） */
export async function handleAdminDeleteRelease(req, res) {
  requireAdmin(req);
  const release = getDb().release;
  if (release?.file) {
    await unlink(join(RELEASE_DIR, release.file)).catch(() => {});
  }
  getDb().release = null;
  await saveDb();
  sendJson(res, 200, { ok: true });
}
