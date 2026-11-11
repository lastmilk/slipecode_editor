// SLIPE 账号后端（重构版）
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
//   api.lineregre.com        → 全部 /api/* 接口
//   workadmin.lineregre.com  → Element Plus 管理页面（/）
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
import {
  handleCreateConversation,
  handleDeleteConversation,
  handleGetConversation,
  handleListConversations,
  handleUpdateConversation,
} from './routes/conversations.js';
import {
  handleBillingPlans,
  handleRedeemActivationCode,
  handleAdminListActivationCodes,
  handleAdminCreateActivationCodes,
  handleAdminToggleActivationCode,
  handleAdminDeleteActivationCode,
} from './routes/billing.js';
import { handleLlmChat, handleLlmModels } from './routes/llm.js';
import {
  handleAdminListOrders,
  handleCreateWechatOrder,
  handleGetWechatOrder,
  handlePayConfirm,
  handlePayJsapi,
  handlePayOauth,
  handlePayPage,
  handlePayStatus,
  handleWechatNotify,
} from './routes/membership.js';
import { handleAiLimits, handleAiUnzip } from './routes/ai_files.js';
import {
  handleAdminRefreshGithubHosts,
  handleGetGithubHosts,
  startGithubHostsSync,
} from './routes/github_hosts.js';
import {
  handleCheckin,
  handleDeleteAccount,
  handleDeleteWallpaper,
  handleGetAvatar,
  handleGetCreditLogs,
  handleGetCredits,
  handleGetSettings,
  handleGetWallpaper,
  handleListDevices,
  handleMe,
  handlePutSettings,
  handleRegisterDevice,
  handleRevokeDevice,
  handleUploadAvatar,
  handleUploadWallpaper,
} from './routes/me.js';
import {
  handleGiteeRefresh,
  handleGiteeToken,
  handleGithubCallback,
  handleGithubToken,
} from './routes/oauth.js';
import {
  handleAdminCreateDoc,
  handleAdminDeleteDoc,
  handleAdminListDocs,
  handleAdminUpdateDoc,
  handleGetDoc,
  handleListDocs,
  handlePortalInfo,
} from './routes/docs.js';
import {
  handleAdminGetPolicies,
  handleAdminUpdatePolicies,
  handleGetPolicies,
} from './routes/policies.js';
import { handleGetProjects, handlePutProjects } from './routes/projects.js';
import {
  handleAdminDeleteRelease,
  handleAdminGetRelease,
  handleAdminUploadRelease,
  handleDownloadRelease,
  handleGetLatestRelease,
} from './routes/releases.js';
import {
  handleCreateBuildWatch,
  handleDownloadBuildArtifact,
  handleGetBuildWatch,
  handleLatestBuildWatch,
} from './routes/builds.js';
import {
  handleAdminDeleteCommunity,
  handleAdminListCommunity,
  handleAdminReviewCommunity,
  handleDownloadCommunityPackage,
  handleGetCommunityPackage,
  handleListCommunity,
  handleMyCommunityPackages,
  handlePublishPackage,
} from './routes/community.js';
import {
  handleAdminDeleteComment,
  handleAdminDeletePost,
  handleAdminGetCommunitySettings,
  handleAdminListPosts,
  handleAdminListReports,
  handleAdminPutCommunitySettings,
  handleAdminReviewPost,
  handleAdminUserCommunityStatus,
  handleCommunitySettingsPublic,
  handleCovenant,
  handleCreateComment,
  handleCreatePost,
  handleDeleteComment,
  handleDeletePost,
  handleGetPost,
  handleListComments,
  handleListFeed,
  handleMyPosts,
  handleReportPost,
  handleToggleLike,
} from './routes/forum.js';
import {
  TUTORIAL_ASSETS_DIR,
  handleGetTutorial,
  handleListTutorials,
} from './routes/tutorials.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ADMIN_DIR = join(__dirname, '..', 'admin');
const WEBSITE_DIR = join(__dirname, '..', 'website');

// ---------------------------------------------------------------------------
// 路由表
// ---------------------------------------------------------------------------

const ROUTES = {
  'GET /api/health': async (req, res) =>
    sendJson(res, 200, { ok: true, service: 'slipe-api', time: Date.now() }),

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

  // AI 多会话（跨端同步）
  'GET /api/conversations': handleListConversations,
  'POST /api/conversations': handleCreateConversation,

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
  'GET /api/credits/logs': handleGetCreditLogs,

  // 账号：登录设备管理 / 注销账号
  'GET /api/me/devices': handleListDevices,
  'POST /api/me/devices': handleRegisterDevice,
  'DELETE /api/me': handleDeleteAccount,

  // 商业化：充值套餐与激活码兑换
  'GET /api/billing/plans': handleBillingPlans,
  'POST /api/billing/redeem': handleRedeemActivationCode,

  // 会员：微信支付 JSAPI
  'POST /api/billing/wechat/order': handleCreateWechatOrder,
  'GET /api/billing/wechat/order': handleGetWechatOrder,
  'POST /api/pay/wechat/notify': handleWechatNotify,

  // 支付页面（必须在 ser1996.niav.cn 域名下访问）
  'GET /pay': handlePayPage,
  'GET /pay/oauth': handlePayOauth,
  'GET /pay/api/jsapi': handlePayJsapi,
  'GET /pay/api/status': handlePayStatus,
  'POST /pay/api/confirm': handlePayConfirm,

  // LLM（/api/llm 作为 OpenAI 兼容 base，客户端会拼 /chat/completions）
  'GET /api/llm/models': handleLlmModels,
  'POST /api/llm/chat': handleLlmChat,
  'POST /api/llm/chat/completions': handleLlmChat,

  // AI 附件（Zip 云端解压 / 上传限制）
  'GET /api/ai/limits': handleAiLimits,
  'POST /api/ai/files/unzip': handleAiUnzip,

  // GitHub 专用 Hosts（应用内使用，不影响系统网络）
  'GET /api/github-hosts': handleGetGithubHosts,
  'POST /api/admin/github-hosts/refresh': handleAdminRefreshGithubHosts,

  // 社区 Payload（列表公开；发布 / 下载需登录）
  'POST /api/community/publish': handlePublishPackage,
  'GET /api/community/packages': handleListCommunity,
  'GET /api/community/mine': handleMyCommunityPackages,

  // 社区论坛（帖子公开只读；发布 / 评论 / 点赞需登录）
  'GET /api/community/feed': handleListFeed,
  'POST /api/community/posts': handleCreatePost,
  'GET /api/community/posts/mine': handleMyPosts,
  'GET /api/community/covenant': handleCovenant,
  'GET /api/community/settings': handleCommunitySettingsPublic,

  // 社区教程（公开只读，资源按需下载）
  'GET /api/tutorials': handleListTutorials,

  // 使用文档（公开只读）与门户信息
  'GET /api/docs': handleListDocs,
  'GET /api/public/info': handlePortalInfo,

  // 政策合规（公开只读）
  'GET /api/policies': handleGetPolicies,

  // 云端构建监听（登录用户：服务端持续同步 + 产物中转）
  'POST /api/build/watch': handleCreateBuildWatch,
  'GET /api/build/watch': handleLatestBuildWatch,

  // 官网安装包（公开）
  'GET /api/releases/latest': handleGetLatestRelease,
  'GET /api/releases/download': handleDownloadRelease,
  'HEAD /api/releases/download': handleDownloadRelease,

  // 管理端 API
  'POST /api/admin/login': handleAdminLogin,
  'GET /api/admin/session': handleAdminSession,
  'GET /api/admin/stats': handleAdminStats,
  'GET /api/admin/config': handleAdminGetConfig,
  'PUT /api/admin/config': handleAdminPutConfig,
  'GET /api/admin/users': handleAdminUsers,
  'GET /api/admin/activation-codes': handleAdminListActivationCodes,
  'POST /api/admin/activation-codes': handleAdminCreateActivationCodes,
  'GET /api/admin/orders': handleAdminListOrders,
  'GET /api/admin/llm/models': handleAdminListModels,
  'POST /api/admin/llm/models': handleAdminCreateModel,
  'GET /api/admin/docs': handleAdminListDocs,
  'POST /api/admin/docs': handleAdminCreateDoc,
  'GET /api/admin/policies': handleAdminGetPolicies,
  'PUT /api/admin/policies': handleAdminUpdatePolicies,
  'GET /api/admin/releases': handleAdminGetRelease,
  'POST /api/admin/releases': handleAdminUploadRelease,
  'DELETE /api/admin/releases': handleAdminDeleteRelease,

  // 社区审核
  'GET /api/admin/community/packages': handleAdminListCommunity,
  'GET /api/admin/community/posts': handleAdminListPosts,
  'GET /api/admin/community/settings': handleAdminGetCommunitySettings,
  'PUT /api/admin/community/settings': handleAdminPutCommunitySettings,
  'GET /api/admin/community/reports': handleAdminListReports,
};

/** 带路径参数的路由（正则捕获，handler 第三个参数为正则 match） */
const DYNAMIC_ROUTES = [
  {
    method: 'GET',
    pattern: /^\/api\/conversations\/([^/]+)$/,
    handler: (req, res, match) =>
      handleGetConversation(req, res, decodeURIComponent(match[1])),
  },
  {
    method: 'PUT',
    pattern: /^\/api\/conversations\/([^/]+)$/,
    handler: (req, res, match) =>
      handleUpdateConversation(req, res, decodeURIComponent(match[1])),
  },
  {
    method: 'DELETE',
    pattern: /^\/api\/conversations\/([^/]+)$/,
    handler: (req, res, match) =>
      handleDeleteConversation(req, res, decodeURIComponent(match[1])),
  },
  {
    method: 'GET',
    pattern: /^\/api\/build\/watch\/([^/]+)\/artifact$/,
    handler: (req, res, match) =>
      handleDownloadBuildArtifact(req, res, decodeURIComponent(match[1])),
  },
  {
    method: 'GET',
    pattern: /^\/api\/build\/watch\/([^/]+)$/,
    handler: (req, res, match) =>
      handleGetBuildWatch(req, res, decodeURIComponent(match[1])),
  },
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
    method: 'POST',
    pattern: /^\/api\/admin\/activation-codes\/([^/]+)\/toggle$/,
    handler: (req, res, match) =>
      handleAdminToggleActivationCode(req, res, decodeURIComponent(match[1])),
  },
  {
    method: 'DELETE',
    pattern: /^\/api\/admin\/activation-codes\/([^/]+)$/,
    handler: (req, res, match) =>
      handleAdminDeleteActivationCode(req, res, decodeURIComponent(match[1])),
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
  {
    method: 'GET',
    pattern: /^\/api\/docs\/([^/]+)$/,
    handler: (req, res, match) => handleGetDoc(req, res, match[1]),
  },
  {
    method: 'PUT',
    pattern: /^\/api\/admin\/docs\/([^/]+)$/,
    handler: (req, res, match) => handleAdminUpdateDoc(req, res, match[1]),
  },
  {
    method: 'DELETE',
    pattern: /^\/api\/admin\/docs\/([^/]+)$/,
    handler: (req, res, match) => handleAdminDeleteDoc(req, res, match[1]),
  },
  {
    method: 'GET',
    pattern: /^\/api\/community\/packages\/([^/]+)$/,
    handler: (req, res, match) =>
      handleGetCommunityPackage(req, res, decodeURIComponent(match[1])),
  },
  {
    method: 'POST',
    pattern: /^\/api\/community\/packages\/([^/]+)\/download$/,
    handler: (req, res, match) =>
      handleDownloadCommunityPackage(req, res, decodeURIComponent(match[1])),
  },
  {
    method: 'POST',
    pattern: /^\/api\/admin\/community\/packages\/([^/]+)\/review$/,
    handler: (req, res, match) =>
      handleAdminReviewCommunity(req, res, decodeURIComponent(match[1])),
  },
  {
    method: 'DELETE',
    pattern: /^\/api\/me\/devices\/([^/]+)$/,
    handler: (req, res, match) =>
      handleRevokeDevice(req, res, decodeURIComponent(match[1])),
  },
  {
    method: 'DELETE',
    pattern: /^\/api\/admin\/community\/packages\/([^/]+)$/,
    handler: (req, res, match) =>
      handleAdminDeleteCommunity(req, res, decodeURIComponent(match[1])),
  },
  // 社区帖子
  {
    method: 'GET',
    pattern: /^\/api\/community\/posts\/([^/]+)$/,
    handler: (req, res, match) =>
      handleGetPost(req, res, decodeURIComponent(match[1])),
  },
  {
    method: 'DELETE',
    pattern: /^\/api\/community\/posts\/([^/]+)$/,
    handler: (req, res, match) =>
      handleDeletePost(req, res, decodeURIComponent(match[1])),
  },
  {
    method: 'POST',
    pattern: /^\/api\/community\/posts\/([^/]+)\/like$/,
    handler: (req, res, match) =>
      handleToggleLike(req, res, decodeURIComponent(match[1])),
  },
  {
    method: 'POST',
    pattern: /^\/api\/community\/posts\/([^/]+)\/report$/,
    handler: (req, res, match) =>
      handleReportPost(req, res, decodeURIComponent(match[1])),
  },
  {
    method: 'GET',
    pattern: /^\/api\/community\/posts\/([^/]+)\/comments$/,
    handler: (req, res, match) =>
      handleListComments(req, res, decodeURIComponent(match[1])),
  },
  {
    method: 'POST',
    pattern: /^\/api\/community\/posts\/([^/]+)\/comments$/,
    handler: (req, res, match) =>
      handleCreateComment(req, res, decodeURIComponent(match[1])),
  },
  {
    method: 'DELETE',
    pattern: /^\/api\/community\/comments\/([^/]+)$/,
    handler: (req, res, match) =>
      handleDeleteComment(req, res, decodeURIComponent(match[1])),
  },
  // 教程
  {
    method: 'GET',
    pattern: /^\/api\/tutorials\/([^/]+)$/,
    handler: (req, res, match) =>
      handleGetTutorial(req, res, decodeURIComponent(match[1])),
  },
  // 管理端：社区帖子 / 评论 / 用户状态
  {
    method: 'POST',
    pattern: /^\/api\/admin\/community\/posts\/([^/]+)\/review$/,
    handler: (req, res, match) =>
      handleAdminReviewPost(req, res, decodeURIComponent(match[1])),
  },
  {
    method: 'DELETE',
    pattern: /^\/api\/admin\/community\/posts\/([^/]+)$/,
    handler: (req, res, match) =>
      handleAdminDeletePost(req, res, decodeURIComponent(match[1])),
  },
  {
    method: 'DELETE',
    pattern: /^\/api\/admin\/community\/comments\/([^/]+)$/,
    handler: (req, res, match) =>
      handleAdminDeleteComment(req, res, decodeURIComponent(match[1])),
  },
  {
    method: 'POST',
    pattern: /^\/api\/admin\/community\/users\/([^/]+)\/status$/,
    handler: (req, res, match) =>
      handleAdminUserCommunityStatus(req, res, decodeURIComponent(match[1])),
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

/** 官网域名（slipe.cn / www.slipe.cn）：页面请求落到官网静态目录 */
function isWebsiteHost(req) {
  const host = String(req.headers.host || '')
    .toLowerCase()
    .replace(/:\d+$/, '');
  return host === 'slipe.cn' || host === 'www.slipe.cn';
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

    // 教程资源（按需下载，支持 Range 由 Nginx / 浏览器处理）
    if (
      (req.method === 'GET' || req.method === 'HEAD') &&
      path.startsWith('/tutorial-assets/')
    ) {
      const rel = decodeURIComponent(path.slice('/tutorial-assets/'.length));
      const ok = await serveStatic(req, res, TUTORIAL_ASSETS_DIR, rel);
      if (!ok) sendJson(res, 404, { error: '教程资源不存在' });
      return;
    }

    // 2) 官网（slipe.cn / www.slipe.cn）
    if (isWebsiteHost(req) && (req.method === 'GET' || req.method === 'HEAD')) {
      const isAsset = /\.(js|mjs|css|map|png|jpg|jpeg|svg|webp|ico|woff|woff2|ttf|txt)$/i.test(path);
      if (isAsset) {
        const ok = await serveStatic(req, res, WEBSITE_DIR, path.slice(1));
        if (ok) return;
      } else {
        if (await serveStatic(req, res, WEBSITE_DIR, 'index.html')) return;
      }
      sendJson(res, 404, { error: '页面不存在' });
      return;
    }

    // 3) 管理页面
    //    资源（含 /vendor、/styles.css、/app.js）无论哪个域名都从 admin 目录读取；
    //    页面入口：workadmin.* 任意路径、其它域名的 / 与 /admin。
    if (req.method === 'GET' || req.method === 'HEAD') {
      const isAsset = /\.(js|mjs|css|map|png|jpg|jpeg|svg|webp|ico|woff|woff2|ttf|txt)$/i.test(path);
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
startGithubHostsSync();
server.listen(PORT, () => {
  console.log(`SLIPE backend listening on http://localhost:${PORT}`);
  console.log('  API      : https://api.lineregre.com');
  console.log('  WorkAdmin: https://workadmin.lineregre.com');
  if (!process.env.JWT_SECRET) {
    console.warn('[WARN] 未设置 JWT_SECRET，当前使用开发默认值，生产环境必须设置');
  }
});
