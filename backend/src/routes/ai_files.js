// AI 附件：云端解压 Zip 到临时目录，返回可阅读的文本内容
//
// 客户端把 Zip 以 base64 上传，服务端解压到 DATA_DIR/ai_tmp/<userId>/<uuid>/，
// 读取其中的文本文件返回给客户端拼进对话（图片等二进制文件只返回元信息）。
// 文件数量 / 单文件大小 / 总大小限制来自管理端配置 config.aiUploads。

import { randomUUID } from 'node:crypto';
import { mkdir, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { extname, join, resolve, sep } from 'node:path';
import { inflateRawSync } from 'node:zlib';

import { DATA_DIR, getDb } from '../db.js';
import { readJson, sendJson } from '../http.js';
import { requireUser } from '../security.js';

const TMP_ROOT = join(DATA_DIR, 'ai_tmp');
const MAX_PREVIEW_BYTES = 64 * 1024;
const MAX_TOTAL_PREVIEW_BYTES = 1024 * 1024;

const TEXT_EXTENSIONS = new Set([
  '.txt', '.md', '.markdown', '.json', '.js', '.mjs', '.cjs', '.ts', '.tsx',
  '.jsx', '.dart', '.kt', '.java', '.py', '.go', '.rs', '.c', '.h', '.cpp',
  '.hpp', '.cs', '.php', '.rb', '.swift', '.m', '.mm', '.html', '.htm',
  '.css', '.scss', '.less', '.xml', '.yml', '.yaml', '.toml', '.ini', '.cfg',
  '.conf', '.env', '.sh', '.bash', '.zsh', '.bat', '.ps1', '.sql', '.gradle',
  '.properties', '.dockerfile', '.gitignore', '.csv', '.tsv', '.log', '.vue',
  '.svelte', '.lua', '.r', '.scala', '.pl', '.tex', '.proto', '.graphql',
]);

function limits() {
  const cfg = getDb().config?.aiUploads || {};
  return {
    enabled: cfg.enabled !== false,
    maxFiles: Number(cfg.maxFiles) || 5,
    maxFileMb: Number(cfg.maxFileMb) || 10,
    maxTotalMb: Number(cfg.maxTotalMb) || 30,
    maxUnzipFiles: Number(cfg.maxUnzipFiles) || 50,
    maxUnzipMb: Number(cfg.maxUnzipMb) || 50,
  };
}

export async function handleAiLimits(req, res) {
  requireUser(req);
  const l = limits();
  sendJson(res, 200, {
    ...l,
    // 客户端一次最多可携带的附件数量（图片 + 文件）
    maxAttachments: l.maxFiles,
  });
}

function isTextFile(name) {
  const ext = extname(name).toLowerCase();
  if (TEXT_EXTENSIONS.has(ext)) return true;
  const base = name.split(/[/\\]/).pop()?.toLowerCase() || '';
  return ['dockerfile', 'makefile', 'readme', 'license', 'gemfile'].includes(base);
}

/** 解析 Zip 中央目录，返回条目列表（仅支持 store / deflate，不支持 zip64 与加密） */
export function readZipEntries(buffer) {
  // 1. 从尾部查找 EOCD（0x06054b50）
  let eocd = -1;
  const minPos = Math.max(0, buffer.length - 65557);
  for (let i = buffer.length - 22; i >= minPos; i -= 1) {
    if (buffer.readUInt32LE(i) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new Error('不是有效的 Zip 文件');
  const totalEntries = buffer.readUInt16LE(eocd + 10);
  const cdOffset = buffer.readUInt32LE(eocd + 16);
  if (totalEntries === 0xffff || cdOffset === 0xffffffff) {
    throw new Error('暂不支持 Zip64 格式，请重新压缩后再上传');
  }

  const entries = [];
  let offset = cdOffset;
  for (let i = 0; i < totalEntries; i += 1) {
    if (offset + 46 > buffer.length || buffer.readUInt32LE(offset) !== 0x02014b50) {
      break;
    }
    const flags = buffer.readUInt16LE(offset + 8);
    const method = buffer.readUInt16LE(offset + 10);
    const compSize = buffer.readUInt32LE(offset + 20);
    const uncompSize = buffer.readUInt32LE(offset + 24);
    const nameLen = buffer.readUInt16LE(offset + 28);
    const extraLen = buffer.readUInt16LE(offset + 30);
    const commentLen = buffer.readUInt16LE(offset + 32);
    const localOffset = buffer.readUInt32LE(offset + 42);
    const name = buffer
      .subarray(offset + 46, offset + 46 + nameLen)
      .toString('utf8');
    offset += 46 + nameLen + extraLen + commentLen;

    const isDir = name.endsWith('/') || name.endsWith('\\');
    if (isDir) continue;
    if (flags & 0x1) continue; // 加密条目直接跳过（需要密码）
    if (localOffset + 30 > buffer.length) continue;
    if (buffer.readUInt32LE(localOffset) !== 0x04034b50) continue;
    const localNameLen = buffer.readUInt16LE(localOffset + 26);
    const localExtraLen = buffer.readUInt16LE(localOffset + 28);
    const dataStart = localOffset + 30 + localNameLen + localExtraLen;
    const dataEnd = dataStart + compSize;
    if (dataStart < 0 || dataEnd > buffer.length) continue;
    entries.push({
      name,
      method,
      compSize,
      uncompSize,
      data: buffer.subarray(dataStart, dataEnd),
    });
  }
  return entries;
}

/** 防止 Zip Slip：拒绝绝对路径与 .. 越级 */
function safeRelativePath(name) {
  const normalized = name.replace(/\\/g, '/');
  if (normalized.startsWith('/') || /^[a-zA-Z]:/.test(normalized)) return null;
  const parts = [];
  for (const part of normalized.split('/')) {
    if (!part || part === '.') continue;
    if (part === '..') return null;
    parts.push(part);
  }
  return parts.join('/');
}

/** 清理 1 小时前的临时解压目录 */
async function pruneOldDirs() {
  try {
    const names = await readdir(TMP_ROOT).catch(() => []);
    const now = Date.now();
    for (const name of names) {
      const dir = join(TMP_ROOT, name);
      try {
        const info = await stat(dir);
        if (now - info.mtimeMs > 60 * 60 * 1000) {
          await rm(dir, { recursive: true, force: true });
        }
      } catch {
        // 忽略单个目录清理失败
      }
    }
  } catch {
    // 忽略清理失败
  }
}

export async function handleAiUnzip(req, res) {
  const user = requireUser(req);
  const cfg = limits();
  if (!cfg.enabled) {
    return sendJson(res, 403, { error: '管理员已关闭 AI 附件上传' });
  }
  const body = await readJson(req, { limit: 64 * 1024 * 1024 });
  const name = String(body.name || 'archive.zip').slice(0, 120);
  const raw = String(body.dataBase64 || '');
  if (!raw) return sendJson(res, 400, { error: '缺少 Zip 文件内容' });

  let buffer;
  try {
    buffer = Buffer.from(raw, 'base64');
  } catch {
    return sendJson(res, 400, { error: 'Zip 文件内容不是合法的 base64' });
  }
  if (buffer.length === 0) return sendJson(res, 400, { error: 'Zip 文件为空' });
  if (buffer.length > cfg.maxFileMb * 1024 * 1024) {
    return sendJson(res, 400, {
      error: `Zip 文件超过单文件上限（${cfg.maxFileMb}MB）`,
    });
  }
  if (buffer.subarray(0, 2).toString('latin1') !== 'PK') {
    return sendJson(res, 400, { error: '文件不是 Zip 格式' });
  }

  let entries;
  try {
    entries = readZipEntries(buffer);
  } catch (err) {
    return sendJson(res, 400, { error: String(err?.message || err) });
  }
  if (entries.length > cfg.maxUnzipFiles) {
    return sendJson(res, 400, {
      error: `压缩包内文件数超过上限（${cfg.maxUnzipFiles}）`,
    });
  }

  const dirName = `${user.id}_${randomUUID().slice(0, 8)}`;
  const dir = join(TMP_ROOT, dirName);
  await mkdir(dir, { recursive: true });

  const files = [];
  const skipped = [];
  let totalUnzipped = 0;
  let previewBudget = MAX_TOTAL_PREVIEW_BYTES;

  for (const entry of entries) {
    const relative = safeRelativePath(entry.name);
    if (!relative) {
      skipped.push({ path: entry.name, reason: '非法路径' });
      continue;
    }
    let data;
    try {
      if (entry.method === 0) {
        data = entry.data;
      } else if (entry.method === 8) {
        data = inflateRawSync(entry.data);
      } else {
        skipped.push({ path: relative, reason: `不支持的压缩方式 ${entry.method}` });
        continue;
      }
    } catch {
      skipped.push({ path: relative, reason: '解压失败' });
      continue;
    }
    totalUnzipped += data.length;
    if (totalUnzipped > cfg.maxUnzipMb * 1024 * 1024) {
      skipped.push({ path: relative, reason: '超过解压总大小上限' });
      break;
    }
    const target = resolve(dir, relative);
    if (!target.startsWith(resolve(dir) + sep) && target !== resolve(dir)) {
      skipped.push({ path: relative, reason: '非法路径' });
      continue;
    }
    try {
      await mkdir(resolve(target, '..'), { recursive: true });
      await writeFile(target, data);
    } catch {
      skipped.push({ path: relative, reason: '写入临时目录失败' });
      continue;
    }
    const item = { path: relative, size: data.length };
    if (isTextFile(relative) && previewBudget > 0) {
      const limit = Math.min(MAX_PREVIEW_BYTES, previewBudget, data.length);
      item.text = data.subarray(0, limit).toString('utf8');
      if (limit < data.length) item.truncated = true;
      previewBudget -= Math.min(limit, data.length);
    } else if (isTextFile(relative)) {
      item.truncated = true;
    }
    files.push(item);
  }

  await pruneOldDirs();
  sendJson(res, 200, {
    id: dirName,
    name,
    count: files.length,
    totalSize: totalUnzipped,
    files,
    skipped,
    dir: `ai_tmp/${dirName}`,
  });
}
