// 政策合规（用户服务协议 / 隐私政策）
//
// 管理员在 WorkAdmin 编辑与发布；
// App 端通过公开只读接口拉取全文（注册 / 版本更新时展示）。

import { getDb, saveDb } from '../db.js';
import { readJson, sendJson } from '../http.js';
import { requireAdmin } from '../security.js';

const MAX_TITLE = 80;
const MAX_VERSION = 32;
const MAX_CONTENT = 128 * 1024; // 128 KB
const POLICY_TYPES = ['userAgreement', 'privacyPolicy'];

function publicPolicy(policy) {
  return {
    title: policy.title,
    content: policy.content,
    version: policy.version,
    updatedAt: policy.updatedAt,
  };
}

function policiesPayload() {
  const policies = getDb().config?.policies || {};
  return {
    userAgreement: publicPolicy(policies.userAgreement || {}),
    privacyPolicy: publicPolicy(policies.privacyPolicy || {}),
  };
}

/** patch 号自动递增：1.0.0 → 1.0.1；非语义化版本时回退为 1.0.1 */
function bumpPatch(version) {
  const match = /^(\d+)\.(\d+)\.(\d+)$/.exec(String(version || '').trim());
  if (!match) return '1.0.1';
  return `${match[1]}.${match[2]}.${Number(match[3]) + 1}`;
}

// ---------------------------------------------------------------------------
// 公开接口（App 端）
// ---------------------------------------------------------------------------

/** 全部政策（含全文、版本与更新时间） */
export async function handleGetPolicies(req, res) {
  sendJson(res, 200, { policies: policiesPayload() });
}

// ---------------------------------------------------------------------------
// 管理端接口
// ---------------------------------------------------------------------------

export async function handleAdminGetPolicies(req, res) {
  requireAdmin(req);
  sendJson(res, 200, { policies: policiesPayload() });
}

/**
 * 更新一份政策：body { type, title?, content?, version? }
 * version 缺省时自动递增 patch 号，保存后立即对 App 端生效。
 */
export async function handleAdminUpdatePolicies(req, res) {
  requireAdmin(req);
  const body = await readJson(req);
  const type = String(body.type || '');
  if (!POLICY_TYPES.includes(type)) {
    return sendJson(res, 400, { error: 'type 必须是 userAgreement 或 privacyPolicy' });
  }
  const policy = getDb().config.policies[type];
  if (body.title !== undefined) {
    const title = String(body.title).trim().slice(0, MAX_TITLE);
    if (!title) return sendJson(res, 400, { error: '标题不能为空' });
    policy.title = title;
  }
  if (body.content !== undefined) {
    const content = String(body.content).slice(0, MAX_CONTENT);
    if (!content.trim()) return sendJson(res, 400, { error: '正文不能为空' });
    policy.content = content;
  }
  const nextVersion = String(body.version ?? '').trim().slice(0, MAX_VERSION);
  policy.version = nextVersion || bumpPatch(policy.version);
  policy.updatedAt = new Date().toISOString();
  await saveDb();
  sendJson(res, 200, { policy: publicPolicy(policy) });
}
