// SlipCode 账号后端（重构版）
//
// 零第三方依赖，Node.js >= 18。
// 模块划分：
//   config.js    —— 配置中心（db > env > 默认值）
//   db.js        —— 单文件 JSON 存储 + 统计埋点
//   http.js      —— HTTP 工具 / 静态资源
//   security.js  —— 密码哈希 / JWT / 用户与管理员鉴权
//   services/    —— 极验、阿里云短信
//   routes/      —— auth / me / projects / chat / oauth / llm / admin
//
// 域名约定：
//   api.slipe.cn        → 全部 /api/* 接口
//   workadmin.slipe.cn  → Element Plus 管理页面（/）
//   （本地开发可用 /admin 直接访问管理页面）
//
// 启动：node src/server.js

import { createServer } from 'node:http';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { PORT } from './config.js';
import { loadDb } from './db.js';
import { CORS_HEADERS, sendJson, serveStatic } from './http.js';
import {
  handleAdminDeleteModel,
  handleAdminGetConfig,
  handleAdminListModels,
  handleAdminLogin,
  handleAdminCreateModel,
  handleAdminPutConfig,
  handleAdminSession,
  handleAdminStats,
  handleAdminUpdateModel,
  handleAdminUserCredits,
  handleAdminUserDetail,
  handleAdminUsers,
} from './routes/admin.js';
import {
  handleCaptchaValidate,
  handleLogin,
  handleRegister,
  handleSendSmsCode,
} from './routes/auth.js';
import {
  handleDeleteChatHistory,
  handleGetChatHistory,
  handlePutChatHistory,
} from './routes/chat.js';
import { handleLlmChat, handleLlmModels } from './routes/llm.js';
import {
  handleCheckin,
  handleDeleteWallpaper,
  handleGetAvatar,
  handleGetCredits,
  handleGetSettings,
  handleGetWallpaper,
  handleMe,
  handlePutSettings,
  handleUploadAvatar,
  handleUploadWallpaper,
} from './routes/me.js';
import {
  handleGiteeRefresh,
  handleGiteeToken,
  handleGithubCallback,
  handleGithubToken,
} from './routes/oauth.js';
import { handleGetProjects, handlePutProjects } from './routes/projects.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ADMIN_DIR = join(__dirname, '..', 'admin');

// ---------------------------------------------------------------------------
// 路由表
// ---------------------------------------------------------------------------

const ROUTES = {
  'GET /api/health': async (req, res) =>
    sendJson(res, 200, { ok: true, service: 'slipecode-api', time: Date.now() }),

  // 账号
  'POST /api/auth/register': handleRegister,
  'POST /api/auth/login': handleLogin,
  'POST /api/auth/sms/send': handleSendSmsCode,
  'POST /api/auth/captcha/validate': handleCaptchaValidate,
  'GET /api/me': handleMe,

  // 偏好 / 项目 / 对话
  'GET /api/settings': handleGetSettings,
  'PUT /api/settings': handlePutSettings,
  'GET /api/projects': handleGetProjects,
  'PUT /api/projects': handlePutProjects,
  'GET /api/chat/history': handleGetChatHistory,
  'PUT /api/chat/history': handlePutChatHistory,
  'DELETE /api/chat/history': handleDeleteChatHistory,

  // 头像 / 壁纸
  'POST /api/me/avatar': handleUploadAvatar,
  'POST /api/me/wallpaper': handleUploadWallpaper,
  'GET /api/me/wallpaper': handleGetWallpaper,
  'DELETE /api/me/wallpaper': handleDeleteWallpaper,

  // OAuth
  'POST /api/oauth/gitee/token': handleGiteeToken,
  'POST /api/oauth/gitee/refresh': handleGiteeRefresh,
  'POST /api/oauth/github/token': handleGithubToken,
  'GET /api/oauth/github/callback': handleGithubCallback,

  // 积分
  'POST /api/checkin': handleCheckin,
  'GET /api/credits': handleGetCredits,

  // LLM
  'GET /api/llm/models': handleLlmModels,
  'POST /api/llm/chat': handleLlmChat,

  // 管理端 API
  'POST /api/admin/login': handleAdminLogin,
  'GET /api/admin/session': handleAdminSession,
  'GET /api/admin/stats': handleAdminStats,
  'GET /api/admin/config': handleAdminGetConfig,
  'PUT /api/admin/config': handleAdminPutConfig,
  'GET /api/admin/users': handleAdminUsers,
  'GET /api/admin/llm/models': handleAdminListModels,
  'POST /api/admin/llm/models': handleAdminCreateModel,
};

/** 带路径参数的路由（正则捕获，handler 第三个参数为正则 match） */
const DYNAMIC_ROUTES = [
  {
    method: 'GET',
    pattern: /^\/api\/avatars\/([^/]+)$/,
    handler: (req, res, match) => handleGetAvatar(req, res, match[1]),
  },
  {
    method: 'GET',
    pattern: /^\/api\/admin\/users\/([^/]+)$/,
    handler: (req, res, match) => handleAdminUserDetail(req, res, decodeURIComponent(match[1])),
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

// ---------------------------------------------------------------------------
// 管理页面（Element Plus SPA）
// ---------------------------------------------------------------------------

/** WorkAdmin 专属域名：所有页面请求都落到管理端 */
function isAdminHost(req) {
  const host = String(req.headers.host || '').toLowerCase();
  return host.startsWith('workadmin.') || host.includes('workadmin');
}

// ---------------------------------------------------------------------------
// 服务器
// ---------------------------------------------------------------------------

const server = createServer(async (req, res) => {
  if (req.method === 'OPTIONS') {
    res.writeHead(204, CORS_HEADERS);
    res.end();
    return;
  }

  const path = new URL(req.url, 'http://localhost').pathname.replace(/\/+$/, '') || '/';

  try {
    // 1) API 路由
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
    if (handler) {
      await handler(req, res);
      return;
    }

    if (path.startsWith('/api/')) {
      sendJson(res, 404, { error: '接口不存在' });
      return;
    }

    // 2) 管理页面
    //    资源（含 /vendor、/styles.css、/app.js）无论哪个域名都从 admin 目录读取；
    //    页面入口：workadmin.* 任意路径、其它域名的 / 与 /admin。
    if (req.method === 'GET' || req.method === 'HEAD') {
      const isAsset = /\.(js|mjs|css|map|png|jpg|jpeg|svg|webp|ico|woff|woff2|ttf)$/i.test(path);
      if (isAsset) {
        const ok = await serveStatic(req, res, ADMIN_DIR, path.slice(1));
        if (ok) return;
      } else if (isAdminHost(req) || path === '/' || path.startsWith('/admin')) {
        const relPath = path.startsWith('/admin/') ? path.slice('/admin/'.length) : 'index.html';
        const ok = relPath !== 'index.html'
          ? await serveStatic(req, res, ADMIN_DIR, relPath)
          : false;
        if (ok) return;
        if (await serveStatic(req, res, ADMIN_DIR, 'index.html')) return;
      }
    }

    sendJson(res, 404, { error: '页面或接口不存在' });
  } catch (err) {
    const status = err.status || 500;
    if (status >= 500) console.error(err);
    if (res.headersSent) {
      res.end();
      return;
    }
    sendJson(res, status, { error: err.message || '服务器错误' });
  }
});

await loadDb();
server.listen(PORT, () => {
  console.log(`SlipCode backend listening on http://localhost:${PORT}`);
  console.log('  API      : https://api.slipe.cn');
  console.log('  WorkAdmin: https://workadmin.slipe.cn');
  if (!process.env.JWT_SECRET) {
    console.warn('[WARN] 未设置 JWT_SECRET，当前使用开发默认值，生产环境必须设置');
  }
});
