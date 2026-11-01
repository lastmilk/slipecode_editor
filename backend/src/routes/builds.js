// 云端构建监听（服务端持续轮询 GitHub Actions）与构建产物中转
//
// 目的：登录用户退出构建页面 / 退出 IDE 后，构建进度仍由服务端持续同步；
// 构建成功后服务端先把产物下载到本地（国内访问 GitHub 较慢），客户端
// 再从 api.slipe.cn 拉取，可用偏好设置关闭该中转。
//
// 记录只保存在内存中（含用户的 GitHub token），服务进程重启后需要客户端
// 重新注册；因此这里不把 token 落到 db.json，避免凭据泄漏。

import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';

import { DATA_DIR } from '../db.js';
import { httpError, readJson, sendBytes, sendJson } from '../http.js';
import { requireUser } from '../security.js';

const BUILD_DIR = join(DATA_DIR, 'builds');
const GITHUB_API = 'https://api.github.com';
const POLL_INTERVAL_MS = 10 * 1000;
const FETCH_TIMEOUT_MS = 20 * 1000;
/** 完成后的记录保留 6 小时，方便客户端稍后回来取产物 */
const KEEP_COMPLETED_MS = 6 * 60 * 60 * 1000;

/** id -> watch */
const watches = new Map();

function sanitize(watch) {
  return {
    id: watch.id,
    repo: watch.repo,
    runId: watch.runId,
    status: watch.status,
    conclusion: watch.conclusion,
    htmlUrl: watch.htmlUrl,
    jobs: watch.jobs,
    artifactReady: Boolean(watch.artifactFile),
    artifactName: watch.artifactName || '',
    artifactSize: watch.artifactSize || 0,
    error: watch.error || '',
    updatedAt: watch.updatedAt,
  };
}

function normalizeJob(job) {
  return {
    id: job.id,
    name: job.name,
    status: job.status,
    conclusion: job.conclusion,
    started_at: job.started_at,
    completed_at: job.completed_at,
    steps: (job.steps || []).map((step) => ({
      number: step.number,
      name: step.name,
      status: step.status,
      conclusion: step.conclusion,
      started_at: step.started_at,
      completed_at: step.completed_at,
    })),
  };
}

async function github(watch, path, { raw = false } = {}) {
  const res = await fetch(`${GITHUB_API}${path}`, {
    headers: {
      Authorization: `Bearer ${watch.token}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'slipecode-build-watch',
    },
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
  if (!res.ok) {
    throw httpError(res.status === 404 ? 404 : 502, `GitHub 接口 ${path} 返回 HTTP ${res.status}`);
  }
  return raw ? res : res.json();
}

async function refreshWatch(watch) {
  if (!watch.token) return;
  const now = Date.now();
  // 已完成且产物已就绪（或失败）后不再轮询
  if (watch.status === 'completed' && (watch.artifactFile || watch.conclusion !== 'success')) {
    watch.updatedAt = now;
    return;
  }

  const run = await github(watch, `/repos/${watch.repo}/actions/runs/${watch.runId}`);
  watch.status = run.status || watch.status;
  watch.conclusion = run.conclusion || watch.conclusion;
  watch.htmlUrl = run.html_url || watch.htmlUrl;

  try {
    const jobs = await github(watch, `/repos/${watch.repo}/actions/runs/${watch.runId}/jobs?per_page=20`);
    watch.jobs = (jobs.jobs || []).map(normalizeJob);
  } catch (err) {
    // 步骤接口偶发失败不影响主状态
    if (!watch.status) watch.error = err.message;
  }

  if (watch.status === 'completed') {
    if (watch.conclusion === 'success') {
      await relayArtifact(watch);
    }
  }
  watch.updatedAt = now;
}

async function relayArtifact(watch) {
  if (watch.artifactFile) return;
  const list = await github(watch, `/repos/${watch.repo}/actions/runs/${watch.runId}/artifacts`);
  const usable = (list.artifacts || []).filter((item) => !item.expired);
  if (usable.length === 0) {
    watch.error = '构建成功但未找到可用产物';
    return;
  }
  const expected = `slipecode-${watch.buildType}`;
  const artifact = usable.find((item) => item.name === expected) || usable[0];

  const first = await fetch(`${GITHUB_API}/repos/${watch.repo}/actions/artifacts/${artifact.id}/zip`, {
    headers: {
      Authorization: `Bearer ${watch.token}`,
      Accept: 'application/vnd.github+json',
      'User-Agent': 'slipecode-build-watch',
    },
    redirect: 'manual',
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
  let body = first;
  if (first.status >= 300 && first.status < 400) {
    const location = first.headers.get('location');
    if (!location) throw new Error('产物下载缺少重定向地址');
    // 签名地址不带 Authorization，避免 token 泄露给第三方域名
    body = await fetch(location, { signal: AbortSignal.timeout(5 * 60 * 1000) });
  }
  if (!body.ok) throw new Error(`产物下载失败（HTTP ${body.status}）`);

  const bytes = Buffer.from(await body.arrayBuffer());
  await mkdir(BUILD_DIR, { recursive: true });
  const file = join(BUILD_DIR, `${watch.id}.zip`);
  await writeFile(file, bytes);
  watch.artifactFile = file;
  watch.artifactName = artifact.name || '';
  watch.artifactSize = bytes.length;
  watch.error = '';
}

let polling = false;

async function pollAll() {
  if (polling) return;
  polling = true;
  const now = Date.now();
  try {
    for (const watch of watches.values()) {
      const idleMs = now - (watch.updatedAt || watch.createdAt);
      if (watch.status === 'completed' && idleMs > KEEP_COMPLETED_MS) {
        watches.delete(watch.id);
        continue;
      }
      try {
        await refreshWatch(watch);
      } catch (err) {
        watch.error = err.message || '同步构建状态失败';
        watch.updatedAt = now;
        // 凭据失效 / 仓库不存在时不再继续轮询
        if (err.status === 401 || err.status === 403 || err.status === 404) {
          watch.token = '';
        }
      }
    }
  } finally {
    polling = false;
  }
}

setInterval(() => {
  pollAll().catch((err) => console.error('[build-watch] 轮询失败', err));
}, POLL_INTERVAL_MS).unref?.();

/** 注册构建监听（同一用户 + 同一运行复用记录） */
export async function handleCreateBuildWatch(req, res) {
  const user = requireUser(req);
  const body = await readJson(req, { limit: 256 * 1024 });

  const repo = String(body.repo || '').trim();
  const runId = Number(body.runId);
  const token = String(body.githubToken || '').trim();
  if (!/^[\w.-]+\/[\w.-]+$/.test(repo)) throw httpError(400, '仓库格式不正确');
  if (!Number.isInteger(runId) || runId <= 0) throw httpError(400, 'runId 不正确');
  if (!token) throw httpError(400, '缺少 GitHub token');

  for (const watch of watches.values()) {
    if (watch.userId === user.id && watch.repo === repo && watch.runId === runId) {
      watch.token = token;
      watch.buildType = String(body.buildType || watch.buildType || '');
      watch.updatedAt = Date.now();
      // 立即同步一次，返回最新状态
      try {
        await refreshWatch(watch);
      } catch (_) {}
      sendJson(res, 200, { watch: sanitize(watch) });
      return;
    }
  }

  const watch = {
    id: randomUUID(),
    userId: user.id,
    repo,
    runId,
    token,
    buildType: String(body.buildType || '').trim(),
    htmlUrl: String(body.runUrl || '').trim(),
    status: 'queued',
    conclusion: null,
    jobs: [],
    artifactFile: '',
    artifactName: '',
    artifactSize: 0,
    error: '',
    createdAt: Date.now(),
    updatedAt: Date.now(),
  };
  watches.set(watch.id, watch);

  try {
    await refreshWatch(watch);
  } catch (err) {
    watch.error = err.message || '同步构建状态失败';
  }
  sendJson(res, 201, { watch: sanitize(watch) });
}

/** 查询单条监听 */
export async function handleGetBuildWatch(req, res, id) {
  const user = requireUser(req);
  const watch = watches.get(id);
  if (!watch || watch.userId !== user.id) throw httpError(404, '构建监听不存在或已过期');
  sendJson(res, 200, { watch: sanitize(watch) });
}

/** 查询某仓库最新一条监听（重新打开 IDE 时恢复进度） */
export async function handleLatestBuildWatch(req, res) {
  const user = requireUser(req);
  const repo = new URL(req.url, 'http://localhost').searchParams.get('repo') || '';
  let latest = null;
  for (const watch of watches.values()) {
    if (watch.userId !== user.id || watch.repo !== repo) continue;
    if (!latest || watch.createdAt > latest.createdAt) latest = watch;
  }
  sendJson(res, 200, { watch: latest ? sanitize(latest) : null });
}

/** 下载服务端中转的构建产物（zip） */
export async function handleDownloadBuildArtifact(req, res, id) {
  const user = requireUser(req);
  const watch = watches.get(id);
  if (!watch || watch.userId !== user.id) throw httpError(404, '构建监听不存在或已过期');
  let bytes;
  try {
    bytes = await readFile(watch.artifactFile || '');
  } catch {
    throw httpError(404, '构建产物尚未就绪');
  }
  sendBytes(res, 200, bytes, 'application/zip');
}
