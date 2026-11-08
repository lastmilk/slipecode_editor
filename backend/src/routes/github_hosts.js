// GitHub 专用 Hosts 下发
//
// 服务端每天从公共 hosts 源拉取一次，缓存到 db.githubHosts；
// 客户端下载后在应用内部 HTTP 请求中使用（不涉及 VPN / 代理 / 系统 hosts）。
// WebView / 系统浏览器中的 OAuth 流程不受影响。

import { getDb, saveDb } from '../db.js';
import { requireAdmin } from '../security.js';
import { sendJson } from '../http.js';

export const GITHUB_HOSTS_SOURCE =
  process.env.GITHUB_HOSTS_URL ||
  'https://raw.githubusercontent.com/maxiaof/github-hosts/refs/heads/master/hosts';

/** 主源不可达时的备用源（同一份 hosts 文件的镜像） */
const GITHUB_HOSTS_MIRRORS = [
  'https://cdn.jsdelivr.net/gh/maxiaof/github-hosts@master/hosts',
  'https://gh-proxy.com/https://raw.githubusercontent.com/maxiaof/github-hosts/refs/heads/master/hosts',
];

const REFRESH_INTERVAL_MS = 24 * 60 * 60 * 1000;
const MAX_HOSTS_BYTES = 512 * 1024;

function isValidHosts(text) {
  if (!text || text.length > MAX_HOSTS_BYTES) return false;
  // 至少包含一条 github.com 的解析记录
  return /^\s*[0-9a-fA-F.:]+\s+.*github\.com/m.test(text);
}

/** 立即从公共源拉取 hosts 并落库 */
export async function refreshGithubHosts() {
  const sources = [GITHUB_HOSTS_SOURCE, ...GITHUB_HOSTS_MIRRORS];
  let lastError = null;
  for (const source of sources) {
    try {
      const response = await fetch(source, {
        signal: AbortSignal.timeout(20_000),
        headers: { 'User-Agent': 'SLIPE-Backend/1.0' },
      });
      if (!response.ok) {
        lastError = new Error(`拉取 hosts 失败：HTTP ${response.status}`);
        continue;
      }
      const content = await response.text();
      if (!isValidHosts(content)) {
        lastError = new Error('拉取的 hosts 内容无效');
        continue;
      }
      const db = getDb();
      db.githubHosts = {
        content,
        source,
        updatedAt: Date.now(),
      };
      await saveDb();
      return db.githubHosts;
    } catch (err) {
      lastError = err;
    }
  }
  throw lastError || new Error('无法获取 GitHub Hosts');
}

/** 客户端拉取 hosts（公开接口） */
export async function handleGetGithubHosts(req, res) {
  const hosts = getDb().githubHosts;
  if (!hosts || !hosts.content) {
    return sendJson(res, 200, { content: '', updatedAt: 0, source: GITHUB_HOSTS_SOURCE });
  }
  sendJson(res, 200, {
    content: hosts.content,
    updatedAt: hosts.updatedAt || 0,
    source: hosts.source || GITHUB_HOSTS_SOURCE,
  });
}

/** 管理员手动刷新 */
export async function handleAdminRefreshGithubHosts(req, res) {
  requireAdmin(req);
  try {
    const hosts = await refreshGithubHosts();
    sendJson(res, 200, {
      ok: true,
      updatedAt: hosts.updatedAt,
      bytes: hosts.content.length,
    });
  } catch (err) {
    sendJson(res, 502, { error: String(err?.message || err) });
  }
}

/** 启动时补拉 + 每日定时刷新（失败不影响服务） */
export function startGithubHostsSync() {
  const current = getDb().githubHosts;
  const stale =
    !current ||
    !current.updatedAt ||
    Date.now() - current.updatedAt > REFRESH_INTERVAL_MS;
  if (stale) {
    refreshGithubHosts().catch((err) => {
      console.warn('[github-hosts] 初始化拉取失败：', err?.message || err);
    });
  }
  setInterval(() => {
    refreshGithubHosts().catch((err) => {
      console.warn('[github-hosts] 定时拉取失败：', err?.message || err);
    });
  }, REFRESH_INTERVAL_MS).unref?.();
}
