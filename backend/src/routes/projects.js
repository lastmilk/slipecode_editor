// 项目列表云同步（本地路径 + Git 仓库映射）
//
// 用途：重装 App 并登录后，按云端记录恢复「打开过的项目」与仓库绑定。
// 路径不存在时由客户端忽略（missing）。

import { getDb, saveDb } from '../db.js';
import { readJson, sendJson } from '../http.js';
import { requireUser } from '../security.js';

export async function handleGetProjects(req, res) {
  const user = requireUser(req);
  sendJson(res, 200, { projects: getDb().projects[user.id] || [] });
}

export async function handlePutProjects(req, res) {
  const user = requireUser(req);
  const body = await readJson(req);
  const list = Array.isArray(body.projects) ? body.projects : null;
  if (!list) return sendJson(res, 400, { error: 'projects 必须是数组' });
  if (list.length > 100) {
    return sendJson(res, 400, { error: '项目数量过多（最多 100 个）' });
  }
  const cleaned = list
    .map((item) => ({
      path: String(item?.path || '').slice(0, 512),
      name: String(item?.name || '').slice(0, 128),
      repoFullName: item?.repoFullName
        ? String(item.repoFullName).slice(0, 200)
        : undefined,
      host: item?.host ? String(item.host).slice(0, 16) : undefined,
      lastEditedAt: item?.lastEditedAt ? String(item.lastEditedAt).slice(0, 40) : undefined,
    }))
    .filter((item) => item.path);
  if (JSON.stringify(cleaned).length > 32 * 1024) {
    return sendJson(res, 400, { error: '项目列表过大' });
  }
  const db = getDb();
  db.projects[user.id] = cleaned;
  await saveDb();
  sendJson(res, 200, { ok: true, projects: cleaned });
}
