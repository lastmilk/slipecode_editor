// 社区 Payload 包
//
// 用户把自建的 System / Block Payload 发布到社区；
// 发布后进入待审核状态（pending），管理员在 WorkAdmin 审核通过（approved）
// 后才对所有人可见，驳回（rejected）时附审核备注。
// Root Payload 只能由官方内置，因此社区只接受 system / block 两类。

import { randomBytes } from 'node:crypto';

import { getDb, saveDb } from '../db.js';
import { readJson, sendJson } from '../http.js';
import { requireAdmin, requireUser, publicUser } from '../security.js';

const MAX_NAME = 60;
const MAX_DESCRIPTION = 400;
const MAX_README = 64 * 1024;
const MAX_SPEC_BYTES = 512 * 1024;
const KINDS = new Set(['system', 'block']);

function publicPackage(pkg, { withSpec = false } = {}) {
  const base = {
    id: pkg.id,
    kind: pkg.kind,
    name: pkg.name,
    description: pkg.description,
    readme: pkg.readme,
    status: pkg.status,
    authorId: pkg.authorId,
    authorName: pkg.authorName,
    downloads: pkg.downloads || 0,
    createdAt: pkg.createdAt,
    updatedAt: pkg.updatedAt,
    reviewNote: pkg.reviewNote || '',
    reviewedAt: pkg.reviewedAt || '',
  };
  if (withSpec) base.spec = pkg.spec;
  return base;
}

function readSpec(body) {
  const spec = body.spec;
  if (!spec || typeof spec !== 'object' || Array.isArray(spec)) return null;
  const text = JSON.stringify(spec);
  if (Buffer.byteLength(text) > MAX_SPEC_BYTES) return null;
  return spec;
}

// ---------------------------------------------------------------------------
// 用户接口（App 端）
// ---------------------------------------------------------------------------

/** 发布自己的 Payload 到社区（进入待审核） */
export async function handlePublishPackage(req, res) {
  const user = requireUser(req);
  const body = await readJson(req, { limit: 1024 * 1024 });
  const kind = String(body.kind || '').trim();
  if (!KINDS.has(kind)) {
    return sendJson(res, 400, { error: '仅支持发布 system / block 两类 Payload' });
  }
  const name = String(body.name || '').trim().slice(0, MAX_NAME);
  if (!name) return sendJson(res, 400, { error: '名称不能为空' });
  const description = String(body.description || '').trim().slice(0, MAX_DESCRIPTION);
  const readme = String(body.readme || '').slice(0, MAX_README);
  const spec = readSpec(body);
  if (!spec) return sendJson(res, 400, { error: 'Payload 定义缺失或过大' });

  const now = new Date().toISOString();
  const pkg = {
    id: `pkg_${randomBytes(8).toString('hex')}`,
    kind,
    name,
    description,
    readme,
    spec,
    status: 'pending',
    authorId: user.id,
    authorName: publicUser(user).displayName || user.email,
    downloads: 0,
    createdAt: now,
    updatedAt: now,
    reviewNote: '',
    reviewedAt: '',
  };
  getDb().community.push(pkg);
  await saveDb();
  sendJson(res, 201, {
    package: publicPackage(pkg),
    message: '已提交，管理员审核通过后会在社区公开',
  });
}

/** 社区公开列表（仅审核通过），支持 kind / q 过滤 */
export async function handleListCommunity(req, res) {
  const query = new URL(req.url, 'http://localhost').searchParams;
  const kind = String(query.get('kind') || '').trim();
  const keyword = String(query.get('q') || '').trim().toLowerCase();
  const list = getDb()
    .community.filter((p) => p.status === 'approved')
    .filter((p) => (kind ? p.kind === kind : true))
    .filter((p) => {
      if (!keyword) return true;
      return `${p.name} ${p.description} ${p.authorName}`.toLowerCase().includes(keyword);
    })
    .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))
    .map((p) => publicPackage(p));
  sendJson(res, 200, { packages: list, total: list.length });
}

/** 社区包详情：已通过的对所有人可见，未通过的仅作者本人可见 */
export async function handleGetCommunityPackage(req, res, id) {
  const pkg = getDb().community.find((p) => p.id === id);
  if (!pkg) return sendJson(res, 404, { error: '社区包不存在' });
  let viewer = null;
  try {
    viewer = requireUser(req);
  } catch {
    viewer = null;
  }
  const isOwner = viewer && viewer.id === pkg.authorId;
  if (pkg.status !== 'approved' && !isOwner) {
    return sendJson(res, 404, { error: '社区包不存在或尚未通过审核' });
  }
  sendJson(res, 200, { package: publicPackage(pkg, { withSpec: true }) });
}

/** 下载社区包（需登录），返回完整定义并累计下载量 */
export async function handleDownloadCommunityPackage(req, res, id) {
  requireUser(req);
  const pkg = getDb().community.find((p) => p.id === id);
  if (!pkg) return sendJson(res, 404, { error: '社区包不存在' });
  if (pkg.status !== 'approved') {
    return sendJson(res, 403, { error: '该社区包尚未通过审核，暂不可下载' });
  }
  pkg.downloads = (pkg.downloads || 0) + 1;
  await saveDb();
  sendJson(res, 200, { package: publicPackage(pkg, { withSpec: true }) });
}

/** 我发布的包（含待审核 / 被驳回） */
export async function handleMyCommunityPackages(req, res) {
  const user = requireUser(req);
  const list = getDb()
    .community.filter((p) => p.authorId === user.id)
    .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))
    .map((p) => publicPackage(p, { withSpec: true }));
  sendJson(res, 200, { packages: list });
}

// ---------------------------------------------------------------------------
// 管理端接口（WorkAdmin 审核）
// ---------------------------------------------------------------------------

export async function handleAdminListCommunity(req, res) {
  requireAdmin(req);
  const query = new URL(req.url, 'http://localhost').searchParams;
  const status = String(query.get('status') || '').trim();
  const list = getDb()
    .community.filter((p) => (status && status !== 'all' ? p.status === status : true))
    .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))
    .map((p) => publicPackage(p, { withSpec: true }));
  sendJson(res, 200, {
    packages: list,
    counts: {
      pending: getDb().community.filter((p) => p.status === 'pending').length,
      approved: getDb().community.filter((p) => p.status === 'approved').length,
      rejected: getDb().community.filter((p) => p.status === 'rejected').length,
    },
  });
}

/** 审核：approve 通过 / reject 驳回（可附备注） */
export async function handleAdminReviewCommunity(req, res, id) {
  requireAdmin(req);
  const pkg = getDb().community.find((p) => p.id === id);
  if (!pkg) return sendJson(res, 404, { error: '社区包不存在' });
  const body = await readJson(req);
  const action = String(body.action || '').trim();
  if (action !== 'approve' && action !== 'reject') {
    return sendJson(res, 400, { error: 'action 只能是 approve 或 reject' });
  }
  pkg.status = action === 'approve' ? 'approved' : 'rejected';
  pkg.reviewNote = String(body.note || '').trim().slice(0, MAX_DESCRIPTION);
  pkg.reviewedAt = new Date().toISOString();
  pkg.updatedAt = pkg.reviewedAt;
  await saveDb();
  sendJson(res, 200, { package: publicPackage(pkg, { withSpec: true }) });
}

export async function handleAdminDeleteCommunity(req, res, id) {
  requireAdmin(req);
  const index = getDb().community.findIndex((p) => p.id === id);
  if (index === -1) return sendJson(res, 404, { error: '社区包不存在' });
  const [removed] = getDb().community.splice(index, 1);
  await saveDb();
  sendJson(res, 200, { ok: true, id: removed.id });
}
