// AI 多会话跨端同步
//
// 每个登录用户拥有多条会话（DeepSeek 风格侧边栏）：
//   GET    /api/conversations        → 会话元信息列表（不含 messages）
//   POST   /api/conversations        → 新建会话 {title?}
//   GET    /api/conversations/:id    → 完整会话（含 messages）
//   PUT    /api/conversations/:id    → 更新 {title?, pinned?, messages?}
//   DELETE /api/conversations/:id    → 删除
//
// 存储结构（db.conversations[userId]）：
//   [{ id, title, pinned, createdAt, updatedAt, messages: [{role, content, reasoning?, ts}] }]

import { randomUUID } from 'node:crypto';

import { getDb, saveDb } from '../db.js';
import { readJson, sendJson } from '../http.js';
import { requireUser } from '../security.js';

const MAX_CONVERSATIONS = 200;
const MAX_MESSAGES = 500;
const MAX_MESSAGE_CHARS = 20000;
const MAX_TITLE_CHARS = 60;

function listOf(userId) {
  const db = getDb();
  if (!db.conversations[userId]) db.conversations[userId] = [];
  return db.conversations[userId];
}

function findOf(userId, id) {
  return listOf(userId).find((c) => c.id === id) || null;
}

function cleanMessages(raw) {
  if (!Array.isArray(raw)) return null;
  return raw
    .filter((m) => m && (m.role === 'user' || m.role === 'assistant'))
    .map((m) => ({
      role: m.role,
      content: String(m.content || '').slice(0, MAX_MESSAGE_CHARS),
      ...(m.reasoning ? { reasoning: String(m.reasoning).slice(0, MAX_MESSAGE_CHARS) } : {}),
      ...(m.kind ? { kind: String(m.kind).slice(0, 20) } : {}),
      // 渲染分段（思考/正文/工具调用穿插），原样透传但限制数量防膨胀
      ...(Array.isArray(m.segments) ? { segments: m.segments.slice(0, 80) } : {}),
      ts: Number.isFinite(m.ts) ? m.ts : Date.now(),
    }))
    .slice(-MAX_MESSAGES);
}

function metaOf(c) {
  return {
    id: c.id,
    title: c.title,
    pinned: !!c.pinned,
    createdAt: c.createdAt,
    updatedAt: c.updatedAt,
    messageCount: c.messages.length,
  };
}

export async function handleListConversations(req, res) {
  const user = requireUser(req);
  const list = listOf(user.id)
    .map(metaOf)
    .sort((a, b) => Number(b.pinned) - Number(a.pinned) || b.updatedAt - a.updatedAt);
  sendJson(res, 200, { conversations: list });
}

export async function handleCreateConversation(req, res) {
  const user = requireUser(req);
  const body = await readJson(req, { limit: 64 * 1024 });
  const list = listOf(user.id);
  if (list.length >= MAX_CONVERSATIONS) {
    return sendJson(res, 400, { error: `会话数量已达上限（${MAX_CONVERSATIONS}）` });
  }
  const now = Date.now();
  // 允许客户端传 id：本地先建的会话可保留同一 id 上传，避免合并冲突
  const clientId = typeof body.id === 'string' && /^[a-zA-Z0-9_-]{6,64}$/.test(body.id)
    ? body.id
    : null;
  if (clientId && list.some((c) => c.id === clientId)) {
    return sendJson(res, 200, { conversation: metaOf(list.find((c) => c.id === clientId)) });
  }
  const conv = {
    id: clientId || randomUUID(),
    title: String(body.title || '新的对话').slice(0, MAX_TITLE_CHARS) || '新的对话',
    pinned: false,
    createdAt: now,
    updatedAt: now,
    messages: [],
  };
  list.push(conv);
  await saveDb();
  sendJson(res, 200, { conversation: metaOf(conv) });
}

export async function handleGetConversation(req, res, id) {
  const user = requireUser(req);
  const conv = findOf(user.id, id);
  if (!conv) return sendJson(res, 404, { error: '会话不存在' });
  sendJson(res, 200, { conversation: { ...metaOf(conv), messages: conv.messages } });
}

export async function handleUpdateConversation(req, res, id) {
  const user = requireUser(req);
  const conv = findOf(user.id, id);
  if (!conv) return sendJson(res, 404, { error: '会话不存在' });
  const body = await readJson(req, { limit: 1024 * 1024 });

  if (typeof body.title === 'string' && body.title.trim()) {
    conv.title = body.title.trim().slice(0, MAX_TITLE_CHARS);
  }
  if (typeof body.pinned === 'boolean') {
    conv.pinned = body.pinned;
  }
  if (body.messages !== undefined) {
    const cleaned = cleanMessages(body.messages);
    if (!cleaned) return sendJson(res, 400, { error: 'messages 必须是数组' });
    if (JSON.stringify(cleaned).length > 512 * 1024) {
      return sendJson(res, 400, { error: '会话内容过大' });
    }
    conv.messages = cleaned;
  }
  conv.updatedAt = Date.now();
  await saveDb();
  sendJson(res, 200, { conversation: metaOf(conv) });
}

export async function handleDeleteConversation(req, res, id) {
  const user = requireUser(req);
  const list = listOf(user.id);
  const idx = list.findIndex((c) => c.id === id);
  if (idx < 0) return sendJson(res, 404, { error: '会话不存在' });
  list.splice(idx, 1);
  await saveDb();
  sendJson(res, 200, { ok: true });
}
