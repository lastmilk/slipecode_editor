// 使用文档（Markdown）
//
// 管理员在 WorkAdmin 撰写 / 发布文档；
// App 端通过公开只读接口拉取（未发布草稿不下发）。

import { randomBytes } from 'node:crypto';

import { getDb, saveDb } from '../db.js';
import { readJson, sendJson } from '../http.js';
import { requireAdmin } from '../security.js';

const MAX_TITLE = 80;
const MAX_CONTENT = 128 * 1024; // 128 KB

function publicDoc(doc, { withContent = false } = {}) {
  const base = {
    id: doc.id,
    title: doc.title,
    updatedAt: doc.updatedAt,
    createdAt: doc.createdAt,
  };
  if (withContent) base.content = doc.content;
  return base;
}

// ---------------------------------------------------------------------------
// 公开接口（App 端）
// ---------------------------------------------------------------------------

/** 已发布文档列表（不含正文，按更新时间倒序） */
export async function handleListDocs(req, res) {
  const docs = getDb()
    .docs.filter((d) => d.published)
    .sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)))
    .map((d) => publicDoc(d));
  sendJson(res, 200, { docs });
}

/** 单篇文档（含正文） */
export async function handleGetDoc(req, res, id) {
  const doc = getDb().docs.find((d) => d.id === id && d.published);
  if (!doc) return sendJson(res, 404, { error: '文档不存在或未发布' });
  sendJson(res, 200, { doc: publicDoc(doc, { withContent: true }) });
}

/** 门户公开信息（QQ 群等运营位） */
export async function handlePortalInfo(req, res) {
  const portal = getDb().config?.portal || {};
  sendJson(res, 200, { qqGroup: String(portal.qqGroup || '') });
}

// ---------------------------------------------------------------------------
// 管理端接口
// ---------------------------------------------------------------------------

export async function handleAdminListDocs(req, res) {
  requireAdmin(req);
  const docs = getDb()
    .docs.slice()
    .sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)))
    .map((d) => ({ ...publicDoc(d, { withContent: true }), published: d.published }));
  sendJson(res, 200, { docs });
}

function readDocFields(body) {
  const title = String(body.title ?? '').trim().slice(0, MAX_TITLE);
  const content = String(body.content ?? '').slice(0, MAX_CONTENT);
  return { title, content };
}

export async function handleAdminCreateDoc(req, res) {
  requireAdmin(req);
  const body = await readJson(req);
  const { title, content } = readDocFields(body);
  if (!title) return sendJson(res, 400, { error: '标题不能为空' });
  if (!content.trim()) return sendJson(res, 400, { error: '正文不能为空' });
  const now = new Date().toISOString();
  const doc = {
    id: `d_${randomBytes(6).toString('hex')}`,
    title,
    content,
    published: body.published !== false,
    createdAt: now,
    updatedAt: now,
  };
  getDb().docs.push(doc);
  await saveDb();
  sendJson(res, 201, { doc: { ...publicDoc(doc, { withContent: true }), published: doc.published } });
}

export async function handleAdminUpdateDoc(req, res, id) {
  requireAdmin(req);
  const doc = getDb().docs.find((d) => d.id === id);
  if (!doc) return sendJson(res, 404, { error: '文档不存在' });
  const body = await readJson(req);
  if (body.title !== undefined) {
    const title = String(body.title).trim().slice(0, MAX_TITLE);
    if (!title) return sendJson(res, 400, { error: '标题不能为空' });
    doc.title = title;
  }
  if (body.content !== undefined) {
    const content = String(body.content).slice(0, MAX_CONTENT);
    if (!content.trim()) return sendJson(res, 400, { error: '正文不能为空' });
    doc.content = content;
  }
  if (body.published !== undefined) {
    doc.published = Boolean(body.published);
  }
  doc.updatedAt = new Date().toISOString();
  await saveDb();
  sendJson(res, 200, { doc: { ...publicDoc(doc, { withContent: true }), published: doc.published } });
}

export async function handleAdminDeleteDoc(req, res, id) {
  requireAdmin(req);
  const index = getDb().docs.findIndex((d) => d.id === id);
  if (index === -1) return sendJson(res, 404, { error: '文档不存在' });
  const [removed] = getDb().docs.splice(index, 1);
  await saveDb();
  sendJson(res, 200, { ok: true, id: removed.id });
}
