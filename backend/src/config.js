// 配置中心
//
// 优先级：db.config（管理端热更新） > 环境变量 > 内置默认值
// 注意：JWT_SECRET 只能来自环境变量（热更新会导致已签发的 token 失效）。

import { getDb } from './db.js';

const env = process.env;

export const PORT = Number(env.PORT || 8787);
export const JWT_SECRET = env.JWT_SECRET || 'dev-only-change-me-slipe-secret';
export const TOKEN_TTL_SECONDS = 60 * 60 * 24 * 30; // 30 天
/** 管理员会话有效期：8 小时 */
export const ADMIN_TOKEN_TTL_SECONDS = 60 * 60 * 8;

export const MAX_BODY_BYTES = 1024 * 1024;
export const UPLOAD_BODY_LIMIT = 8 * 1024 * 1024;
export const AVATAR_MAX_BYTES = 2 * 1024 * 1024;
export const WALLPAPER_MAX_BYTES = 5 * 1024 * 1024;
export const PASSWORD_MIN = 8;
/** 调用第三方服务的单次请求超时 */
export const HTTP_TIMEOUT_MS = 8000;

export const CHECKIN_REWARD = 100;
/** 积分计价：1 积分 = 2000 token */
export const TOKENS_PER_CREDIT = 2000;

export const PHONE_PATTERN = /^1[3-9]\d{9}$/;

/** 未配置阿里云凭据时的开发模式固定验证码 */
export const SMS_DEV_CODE = '123456';

// ---------------------------------------------------------------------------
// 极验 GT4
// ---------------------------------------------------------------------------

const ENV_GEETEST = {
  captchaId: env.GEETEST_CAPTCHA_ID || 'bad52dace656f61eab4b052c157d00b2',
  captchaKey: env.GEETEST_CAPTCHA_KEY || 'f14be37e33e7104c769f84d8470eef9e',
  enforce: (env.GEETEST_ENFORCE || '1') !== '0',
};

/** 当前生效的极验配置（管理端保存后立即生效） */
export function geetestConfig() {
  const c = getDb().config?.geetest || {};
  return {
    captchaId: c.captchaId || ENV_GEETEST.captchaId,
    captchaKey: c.captchaKey || ENV_GEETEST.captchaKey,
    enforce: typeof c.enforce === 'boolean' ? c.enforce : ENV_GEETEST.enforce,
  };
}

// ---------------------------------------------------------------------------
// 阿里云短信（DyPnsApi 2017-05-25）
// ---------------------------------------------------------------------------

const ENV_ALIYUN = {
  accessKeyId: env.ALIYUN_ACCESS_KEY_ID || '',
  accessKeySecret: env.ALIYUN_ACCESS_KEY_SECRET || '',
  endpoint: env.ALIYUN_DYPNS_ENDPOINT || 'dypnsapi.aliyuncs.com',
  region: env.ALIYUN_REGION || 'cn-hangzhou',
  signName: env.ALIYUN_SMS_SIGN_NAME || '恒创联众',
  templateCode: env.ALIYUN_SMS_TEMPLATE_CODE || '100001',
  validMinutes: Number(env.ALIYUN_SMS_VALID_MINUTES || 5),
  dailyLimit: Number(env.ALIYUN_SMS_DAILY_LIMIT || 5),
};

/** 当前生效的阿里云配置 */
export function aliyunConfig() {
  const c = getDb().config?.aliyun || {};
  const accessKeyId = c.accessKeyId || ENV_ALIYUN.accessKeyId;
  const accessKeySecret = c.accessKeySecret || ENV_ALIYUN.accessKeySecret;
  return {
    accessKeyId,
    accessKeySecret,
    endpoint: c.endpoint || ENV_ALIYUN.endpoint,
    region: ENV_ALIYUN.region,
    signName: c.signName || ENV_ALIYUN.signName,
    templateCode: c.templateCode || ENV_ALIYUN.templateCode,
    validMinutes: ENV_ALIYUN.validMinutes,
    dailyLimit: ENV_ALIYUN.dailyLimit,
    // 未配置凭据 → 开发模式（发送接口返回固定验证码）
    devMode: !accessKeyId || !accessKeySecret,
  };
}

// ---------------------------------------------------------------------------
// 管理端
// ---------------------------------------------------------------------------

export const DEFAULT_ADMIN_PASSWORD = env.ADMIN_PASSWORD || 'slipe-admin-2026';

/** 环境变量中的静态管理令牌（兼容脚本调用，可选） */
export const LEGACY_ADMIN_TOKEN =
  env.ADMIN_TOKEN || 'dev-only-admin-token-7f3a9c1e5b2d48f0-change-me';

export function adminPasswordHash() {
  return getDb().config?.admin?.passwordHash || '';
}

// ---------------------------------------------------------------------------
// 第三方 OAuth
// ---------------------------------------------------------------------------

export const GITEE = {
  clientId: env.GITEE_CLIENT_ID || '',
  clientSecret: env.GITEE_CLIENT_SECRET || '',
  redirectUri: env.GITEE_REDIRECT_URI || '',
};

export const GITHUB = {
  clientId: env.GITHUB_CLIENT_ID || '',
  clientSecret: env.GITHUB_CLIENT_SECRET || '',
  redirectUri:
    env.GITHUB_REDIRECT_URI || 'https://api.slipe.cn/api/oauth/github/callback',
  deepLink: env.GITHUB_DEEP_LINK || 'slipe://oauth/callback',
  oauthBase: env.GITHUB_OAUTH_BASE || 'https://github.com/login/oauth',
};

/** 一次性票据有效期（5 分钟） */
export const OAUTH_TICKET_TTL_MS = 5 * 60 * 1000;
