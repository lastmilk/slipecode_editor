// HTTP 工具：响应、请求体解析、CORS、静态资源

import { readFile, stat } from 'node:fs/promises';
import { extname, join } from 'node:path';

export const CORS_HEADERS = {
  'Access-Control-Allow-Origin': process.env.CORS_ORIGIN || '*',
  'Access-Control-Allow-Methods': 'GET,POST,PUT,DELETE,OPTIONS',
  'Access-Control-Allow-Headers':
    'Content-Type,Authorization,X-Admin-Password',
};

/** 构造带 HTTP 状态码的错误 */
export function httpError(status, message) {
  return Object.assign(new Error(message), { status });
}

export function sendJson(res, status, data) {
  const body = JSON.stringify(data);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
    ...CORS_HEADERS,
  });
  res.end(body);
}

/** 输出二进制（头像 / 壁纸下载） */
export function sendBytes(res, status, buffer, contentType) {
  res.writeHead(status, {
    'Content-Type': contentType,
    'Content-Length': buffer.length,
    'Cache-Control': 'no-cache',
    ...CORS_HEADERS,
  });
  res.end(buffer);
}

export function readJson(req, { limit = 1024 * 1024 } = {}) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(httpError(413, '请求体过大'));
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
        reject(httpError(400, 'JSON 格式不正确'));
      }
    });
    req.on('error', reject);
  });
}

/** 读取原始请求体（微信支付回调验签必须使用原始报文） */
export function readRaw(req, { limit = 1024 * 1024 } = {}) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(httpError(413, '请求体过大'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

export function bearer(req) {
  const raw = req.headers.authorization || '';
  const match = /^Bearer\s+(.+)$/i.exec(raw);
  return match ? match[1] : '';
}

/** 读取 Header 中的二次验证密码 */
export function adminPasswordHeader(req) {
  return String(req.headers['x-admin-password'] || '');
}

export function remoteIp(req) {
  const forwarded = req.headers['x-forwarded-for'];
  if (typeof forwarded === 'string' && forwarded.trim()) {
    return forwarded.split(',')[0].trim();
  }
  return req.socket.remoteAddress || 'unknown';
}

// ---------------------------------------------------------------------------
// 静态资源（管理端）
// ---------------------------------------------------------------------------

const MIME_BY_EXT = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.mjs': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.map': 'application/json; charset=utf-8',
  '.zip': 'application/zip',
  '.mp4': 'video/mp4',
  '.webm': 'video/webm',
  '.md': 'text/markdown; charset=utf-8',
};

/**
 * 从 rootDir 内安全地读取静态文件（阻止 ../ 路径穿越）。
 * 命中返回 true，未命中返回 false（由调用方继续路由）。
 */
export async function serveStatic(req, res, rootDir, relPath) {
  const clean = relPath.replace(/^\/+/, '').replace(/\\/g, '/');
  if (clean.includes('..')) return false;
  const filePath = join(rootDir, clean);
  try {
    const info = await stat(filePath);
    if (!info.isFile()) return false;
    const body = await readFile(filePath);
    const type = MIME_BY_EXT[extname(filePath).toLowerCase()] || 'application/octet-stream';
    res.writeHead(200, {
      'Content-Type': type,
      'Content-Length': body.length,
      // 管理端资源更新不频繁，短缓存即可
      'Cache-Control': 'public, max-age=300',
    });
    res.end(body);
    return true;
  } catch {
    return false;
  }
}
