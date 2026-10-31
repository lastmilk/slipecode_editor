// AI 对话记录云同步（用户可选开启）

import { getDb, saveDb } from '../db.js';
import { readJson, sendJson } from '../http.js';
import { requireUser } from '../security.js';

export async function handleGetChatHistory(req, res) {
  const user = requireUser(req);
  sendJson(res, 200, { messages: getDb().chatHistory[user.id] || [] });
}

export async function handlePutChatHistory(req, res) {
  const user = requireUser(req);
  const body = await readJson(req, { limit: 512 * 1024 });
  const list = Array.isArray(body.messages) ? body.messages : null;
  if (!list) return sendJson(res, 400, { error: 'messages 必须是数组' });
  const cleaned = list
    .filter((m) => m && (m.role === 'user' || m.role === 'assistant'))
    .map((m) => ({
      role: m.role,
      content: String(m.content || '').slice(0, 20000),
      ts: Number.isFinite(m.ts) ? m.ts : Date.now(),
    }))
    .slice(-200);
  if (JSON.stringify(cleaned).length > 256 * 1024) {
    return sendJson(res, 400, { error: '对话记录过大' });
  }
  const db = getDb();
  db.chatHistory[user.id] = cleaned;
  await saveDb();
  sendJson(res, 200, { ok: true, count: cleaned.length });
}

export async function handleDeleteChatHistory(req, res) {
  const user = requireUser(req);
  getDb().chatHistory[user.id] = [];
  await saveDb();
  sendJson(res, 200, { ok: true });
}
