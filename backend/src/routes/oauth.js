// OAuth 代理：Gitee / GitHub
//
// 后端持有 client_secret，客户端只拿到 access_token。
// GitHub 走「后端中转回调 + 一次性 ticket」，避免 token 出现在 URL 中。

import { randomBytes } from 'node:crypto';

import { GITEE, GITHUB, OAUTH_TICKET_TTL_MS, HTTP_TIMEOUT_MS } from '../config.js';
import { httpError, readJson, sendJson } from '../http.js';

// ---------------------------------------------------------------------------
// Gitee
// ---------------------------------------------------------------------------

async function giteeTokenRequest(params) {
  if (!GITEE.clientId || !GITEE.clientSecret) {
    throw httpError(503, '后端未配置 GITEE_CLIENT_ID / GITEE_CLIENT_SECRET');
  }
  const body = new URLSearchParams({
    client_id: GITEE.clientId,
    client_secret: GITEE.clientSecret,
    ...params,
  });
  const upstream = await fetch('https://gitee.com/oauth/token', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      Accept: 'application/json',
    },
    body,
    signal: AbortSignal.timeout(HTTP_TIMEOUT_MS),
  });
  const text = await upstream.text();
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    data = { error: 'invalid_response', error_description: text.slice(0, 300) };
  }
  if (!upstream.ok || !data.access_token) {
    throw httpError(502, data.error_description || data.error || 'Gitee 换取 token 失败');
  }
  return data;
}

function tokenPayload(data) {
  return {
    access_token: data.access_token,
    refresh_token: data.refresh_token,
    expires_in: data.expires_in,
    scope: data.scope,
    token_type: data.token_type || 'bearer',
  };
}

export async function handleGiteeToken(req, res) {
  const body = await readJson(req);
  const code = String(body.code || '');
  if (!code) return sendJson(res, 400, { error: '缺少 code' });

  const data = await giteeTokenRequest({
    grant_type: 'authorization_code',
    code,
    redirect_uri: String(body.redirect_uri || GITEE.redirectUri),
  });
  sendJson(res, 200, tokenPayload(data));
}

export async function handleGiteeRefresh(req, res) {
  const body = await readJson(req);
  const refreshToken = String(body.refresh_token || '');
  if (!refreshToken) return sendJson(res, 400, { error: '缺少 refresh_token' });

  const data = await giteeTokenRequest({
    grant_type: 'refresh_token',
    refresh_token: refreshToken,
  });
  sendJson(res, 200, tokenPayload(data));
}

// ---------------------------------------------------------------------------
// GitHub
// ---------------------------------------------------------------------------

async function githubTokenRequest(params) {
  if (!GITHUB.clientId || !GITHUB.clientSecret) {
    throw httpError(503, '后端未配置 GITHUB_CLIENT_ID / GITHUB_CLIENT_SECRET');
  }
  const body = new URLSearchParams({
    client_id: GITHUB.clientId,
    client_secret: GITHUB.clientSecret,
    ...params,
  });
  const upstream = await fetch(`${GITHUB.oauthBase}/access_token`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      Accept: 'application/json',
    },
    body,
    signal: AbortSignal.timeout(HTTP_TIMEOUT_MS),
  });
  const text = await upstream.text();
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    data = { error: 'invalid_response', error_description: text.slice(0, 300) };
  }
  if (!upstream.ok || !data.access_token) {
    throw httpError(502, data.error_description || data.error || 'GitHub 换取 token 失败');
  }
  return data;
}

/** 只允许 http(s) 回调地址参与换 token；深链回调走后端中转 */
function resolveGithubRedirectUri(candidate) {
  const value = String(candidate || '');
  if (value.startsWith('http://') || value.startsWith('https://')) return value;
  return GITHUB.redirectUri;
}

/** 取多值请求头中的第一个值（代理会追加多个） */
function firstHeaderValue(value) {
  return String(value || '').split(',')[0].trim();
}

/**
 * 按「本次回调请求的真实地址」推导 redirect_uri。
 *
 * GitHub 换取 token 时要求 redirect_uri 与授权时使用的回调地址完全一致。
 * 服务器环境变量里可能配的是旧域名（如 ser1996.niav.cn），
 * 与 App 实际使用的 api.lineregre.com 不一致就会报
 * `The redirect_uri MUST match the registered callback URL`。
 */
function resolveCallbackRedirectUri(req) {
  const proto = (
    firstHeaderValue(req.headers['x-forwarded-proto']) ||
    firstHeaderValue(req.headers['x-scheme']) ||
    'https'
  ).toLowerCase();

  let host = firstHeaderValue(req.headers['x-forwarded-host']) || firstHeaderValue(req.headers.host);
  // Nginx 反代常带默认端口（api.lineregre.com:443），需去掉才能与登记的回调一致
  if (proto === 'https' && host.endsWith(':443')) host = host.slice(0, -4);
  if (proto === 'http' && host.endsWith(':80')) host = host.slice(0, -3);

  const path = (req.url || '').split('?')[0];
  if (!host || !path) return GITHUB.redirectUri;
  return `${proto}://${host}${path}`;
}

// 一次性票据：ticket → token（5 分钟有效，用后即焚）
const oauthTickets = new Map();

function issueOAuthTicket(tokenData) {
  const now = Date.now();
  for (const [key, value] of oauthTickets) {
    if (value.expiresAt < now) oauthTickets.delete(key);
  }
  const ticket = randomBytes(32).toString('hex');
  oauthTickets.set(ticket, { ...tokenData, expiresAt: now + OAUTH_TICKET_TTL_MS });
  return ticket;
}

function escapeHtml(value) {
  return String(value || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/** 供 <script> 内嵌的安全 JSON（避免 </script> 截断） */
function jsonForScript(value) {
  return JSON.stringify(value).replace(/</g, '\\u003c').replace(/>/g, '\\u003e');
}

/**
 * 自定义 scheme 无法由服务端 302 可靠唤起（Chrome Custom Tab 会拦截），
 * 因此返回一个 HTML 桥接页：自动尝试跳转 + 用户点击按钮兜底。
 */
function sendDeepLinkBridge(res, deepLink, params) {
  if (!deepLink.startsWith('slipe://')) {
    console.warn(
      `[oauth] GITHUB_DEEP_LINK 配置为 ${deepLink}，App 默认监听 slipe://gitoauth2，可能出现回调无法唤起`,
    );
  }
  const target = `${deepLink}?${new URLSearchParams(params).toString()}`;
  const hasError = Boolean(params.error);
  const detail = params.error_description || params.error || '';
  const html = `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>SLIPE 授权回调</title>
<style>
  :root { color-scheme: light dark; }
  body { margin:0; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;
         background:#f5f7fa; color:#1f2329; display:flex; align-items:center; justify-content:center; min-height:100vh; }
  .card { width:min(92vw,420px); background:#fff; border-radius:16px; padding:28px 24px;
          box-shadow:0 12px 40px rgba(0,0,0,.08); text-align:center; }
  .logo { width:56px; height:56px; border-radius:16px; background:#0175C2; color:#fff;
          display:flex; align-items:center; justify-content:center; font-size:26px; font-weight:700; margin:0 auto 14px; }
  h1 { font-size:18px; margin:0 0 8px; }
  p { font-size:13px; line-height:1.6; color:#646a73; margin:0 0 18px; }
  .error { color:#d54941; }
  button, a.btn { display:block; width:100%; box-sizing:border-box; border:0; border-radius:10px;
          padding:13px 16px; font-size:15px; font-weight:600; text-decoration:none; cursor:pointer; }
  .primary { background:#0175C2; color:#fff; }
  .ghost { background:#f2f3f5; color:#1f2329; margin-top:10px; }
  .hint { font-size:12px; color:#8f959e; margin-top:14px; }
  @media (prefers-color-scheme: dark) {
    body { background:#121212; color:#e8e8e8; }
    .card { background:#1e1e1e; box-shadow:none; border:1px solid #2b2b2b; }
    p { color:#a8abb2; }
    .ghost { background:#2a2a2c; color:#e8e8e8; }
  }
</style>
</head>
<body>
  <div class="card">
    <div class="logo">S</div>
    <h1>${hasError ? '授权未完成' : '授权成功'}</h1>
    <p class="${hasError ? 'error' : ''}">${
      hasError
        ? `GitHub 返回错误：${escapeHtml(detail || '未知错误')}`
        : '请返回 SLIPE 完成登录。若未自动跳转，请点击下方按钮。'
    }</p>
    <a class="btn primary" id="open" href="${escapeHtml(target)}">打开 SLIPE</a>
    <button class="btn ghost" id="copy">复制授权链接</button>
    <div class="hint" id="hint">正在尝试自动打开 SLIPE…</div>
  </div>
<script>
  var target = ${jsonForScript(target)};
  var hint = document.getElementById('hint');
  function tryOpen() {
    try { window.location.href = target; } catch (e) {}
  }
  document.getElementById('open').addEventListener('click', function (e) {
    e.preventDefault();
    tryOpen();
  });
  document.getElementById('copy').addEventListener('click', function () {
    var done = function () { hint.textContent = '链接已复制'; };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(target).then(done, function () { window.prompt('复制授权链接', target); });
    } else {
      window.prompt('复制授权链接', target);
    }
  });
  setTimeout(function () {
    hint.textContent = '若未自动跳转，请点击上方「打开 SLIPE」';
  }, 2500);
  setTimeout(tryOpen, 300);
</script>
</body>
</html>`;
  res.writeHead(200, {
    'Content-Type': 'text/html; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
  });
  res.end(html);
}

/** Gitee 回调中转：Gitee → 本后端桥接页 → App 深链（App 再用 code 换 token） */
export async function handleGiteeCallback(req, res) {
  const url = new URL(req.url, 'http://localhost');
  const params = {};
  const state = url.searchParams.get('state');
  const code = url.searchParams.get('code');
  const error = url.searchParams.get('error');
  const description = url.searchParams.get('error_description');
  if (state) params.state = state;
  if (code) params.code = code;
  if (error) params.error = error;
  if (description) params.error_description = description;
  if (!code && !error) params.error = 'missing_code';
  sendDeepLinkBridge(res, 'slipe://oauth/gitee/callback', params);
}

/** GitHub 回调中转：GitHub → 本后端 → 桥接页回 App 深链（带一次性 ticket） */
export async function handleGithubCallback(req, res) {
  const url = new URL(req.url, 'http://localhost');
  const state = url.searchParams.get('state') || '';
  const redirectToApp = (params) => {
    sendDeepLinkBridge(res, GITHUB.deepLink, { state, ...params });
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
      redirect_uri: resolveCallbackRedirectUri(req),
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

export async function handleGithubToken(req, res) {
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
