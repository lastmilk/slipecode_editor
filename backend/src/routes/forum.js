// 社区论坛：帖子 / 评论 / 点赞 / 举报 / 公约 / 关键词过滤
//
// 设计要点：
// - 首次发帖进入 pending，管理员审核通过后该作者后续帖子自动发布；
// - 所有帖子与评论在服务端强制关键词过滤；
// - 被禁言 / 封禁用户不能发帖、评论；
// - 帖子与评论均使用 Markdown 原文存储，客户端渲染。

import { randomBytes } from 'node:crypto';

import { getDb, saveDb } from '../db.js';
import { httpError, readJson, sendJson } from '../http.js';
import { publicUser, requireAdmin, requireUser } from '../security.js';

const MAX_TITLE = 80;
const MAX_CONTENT = 20 * 1024;
const MAX_COMMENT = 1000;
const MAX_TAGS = 5;
const POST_INTERVAL_MS = 60 * 1000;
const COMMENT_INTERVAL_MS = 3 * 1000;
const REPORT_REASON_MAX = 200;

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

function settings() {
  const raw = getDb().communitySettings || {};
  return {
    keywords: Array.isArray(raw.keywords) ? raw.keywords : [],
    covenant: typeof raw.covenant === 'string' ? raw.covenant : '',
    firstPostReview: raw.firstPostReview !== false,
    maxPostsPerDay: Number(raw.maxPostsPerDay) > 0 ? Number(raw.maxPostsPerDay) : 20,
    updatedAt: raw.updatedAt || '',
  };
}

function normalizeForFilter(text) {
  return String(text || '')
    .toLowerCase()
    .replace(/[\s\p{P}\p{S}]/gu, '');
}

function findKeyword(text) {
  const normalized = normalizeForFilter(text);
  if (!normalized) return '';
  for (const keyword of settings().keywords) {
    const needle = normalizeForFilter(keyword);
    if (needle && normalized.includes(needle)) return keyword;
  }
  return '';
}

function assertClean(...texts) {
  const hit = findKeyword(texts.join('\n'));
  if (hit) throw httpError(400, `内容包含违规关键词：${hit}，请修改后再试`);
}

function assertNoUnsafeHtml(text) {
  if (/<\s*(script|iframe|object|embed|style)[\s>]/i.test(text) || /javascript:/i.test(text)) {
    throw httpError(400, '内容包含不允许的 HTML 标签');
  }
}

function communityOf(user) {
  if (!user.community || typeof user.community !== 'object') {
    user.community = { approvedPosts: 0, mutedUntil: '', banned: false };
  }
  return user.community;
}

function assertUserActive(user) {
  const c = communityOf(user);
  if (c.banned) throw httpError(403, '账号已被社区封禁，如有异议请提交申诉');
  if (c.mutedUntil && Date.parse(c.mutedUntil) > Date.now()) {
    throw httpError(403, `账号已被禁言至 ${new Date(c.mutedUntil).toLocaleString('zh-CN')}`);
  }
}

function countTodayPosts(userId) {
  const start = new Date();
  start.setHours(0, 0, 0, 0);
  return getDb().communityPosts.filter(
    (p) => p.authorId === userId && Date.parse(p.createdAt || 0) >= start.getTime(),
  ).length;
}

function normalizeTags(tags) {
  if (!Array.isArray(tags)) return [];
  return tags
    .map((t) => String(t || '').trim())
    .filter(Boolean)
    .slice(0, MAX_TAGS)
    .map((t) => t.slice(0, 20));
}

function authorName(user) {
  return publicUser(user).displayName || user.email || '匿名';
}

function publicPost(post, { withContent = false } = {}) {
  const base = {
    id: post.id,
    authorId: post.authorId,
    authorName: post.authorName,
    title: post.title,
    excerpt: String(post.content || '').replace(/\s+/g, ' ').slice(0, 160),
    tags: post.tags || [],
    status: post.status,
    likes: Array.isArray(post.likedBy) ? post.likedBy.length : 0,
    commentCount: post.commentCount || 0,
    createdAt: post.createdAt,
    updatedAt: post.updatedAt,
    reviewedAt: post.reviewedAt || '',
    reviewNote: post.reviewNote || '',
  };
  if (withContent) base.content = post.content || '';
  return base;
}

function publicComment(comment) {
  return {
    id: comment.id,
    postId: comment.postId,
    authorId: comment.authorId,
    authorName: comment.authorName,
    content: comment.content,
    status: comment.status || 'published',
    createdAt: comment.createdAt,
  };
}

function findPost(id) {
  return getDb().communityPosts.find((p) => p.id === id) || null;
}

function maybeViewer(req) {
  try {
    return requireUser(req);
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// 帖子
// ---------------------------------------------------------------------------

/** 发帖：首帖 pending，后续自动发布（仍过关键词过滤） */
export async function handleCreatePost(req, res) {
  const user = requireUser(req);
  assertUserActive(user);
  const body = await readJson(req, { limit: 64 * 1024 });

  const title = String(body.title || '').trim().slice(0, MAX_TITLE);
  const content = String(body.content || '').trim().slice(0, MAX_CONTENT);
  if (!title) return sendJson(res, 400, { error: '标题不能为空' });
  if (!content) return sendJson(res, 400, { error: '正文不能为空' });

  assertClean(title, content);
  assertNoUnsafeHtml(title + '\n' + content);

  const c = communityOf(user);
  const lastAt = Number(c.lastPostAt || 0);
  if (Date.now() - lastAt < POST_INTERVAL_MS) {
    return sendJson(res, 429, { error: '发帖过于频繁，请 1 分钟后再试' });
  }
  const maxPerDay = settings().maxPostsPerDay;
  if (countTodayPosts(user.id) >= maxPerDay) {
    return sendJson(res, 429, { error: `今日发帖已达上限（${maxPerDay} 条）` });
  }

  const needReview = settings().firstPostReview && Number(c.approvedPosts || 0) === 0;
  const now = new Date().toISOString();
  const post = {
    id: `post_${randomBytes(8).toString('hex')}`,
    authorId: user.id,
    authorName: authorName(user),
    title,
    content,
    tags: normalizeTags(body.tags),
    status: needReview ? 'pending' : 'published',
    likedBy: [],
    commentCount: 0,
    createdAt: now,
    updatedAt: now,
    reviewedAt: '',
    reviewNote: '',
  };
  getDb().communityPosts.push(post);
  c.lastPostAt = Date.now();
  await saveDb();
  sendJson(res, 201, {
    post: publicPost(post, { withContent: true }),
    needReview,
    message: needReview ? '首帖已提交审核，通过后其他用户可见' : '发布成功',
  });
}

/** 帖子流（仅 published） */
export async function handleListFeed(req, res) {
  const url = new URL(req.url, 'http://localhost');
  const tab = String(url.searchParams.get('tab') || 'latest');
  const keyword = String(url.searchParams.get('q') || '').trim().toLowerCase();
  const page = Math.max(1, Number(url.searchParams.get('page') || 1));
  const pageSize = Math.min(30, Math.max(1, Number(url.searchParams.get('pageSize') || 10)));

  let list = getDb()
    .communityPosts.filter((p) => p.status === 'published')
    .filter((p) => {
      if (!keyword) return true;
      return `${p.title} ${p.content} ${p.authorName}`
        .toLowerCase()
        .includes(keyword);
    });

  if (tab === 'hot') {
    list = list.sort((a, b) => {
      const scoreA = (a.likedBy?.length || 0) * 2 + (a.commentCount || 0);
      const scoreB = (b.likedBy?.length || 0) * 2 + (b.commentCount || 0);
      if (scoreA !== scoreB) return scoreB - scoreA;
      return String(b.createdAt).localeCompare(String(a.createdAt));
    });
  } else {
    list = list.sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
  }

  const total = list.length;
  const start = (page - 1) * pageSize;
  sendJson(res, 200, {
    posts: list.slice(start, start + pageSize).map((p) => publicPost(p)),
    total,
    page,
    pageSize,
    hasMore: start + pageSize < total,
  });
}

/** 帖子详情：pending/rejected 仅作者或管理员可见 */
export async function handleGetPost(req, res, id) {
  const post = findPost(id);
  if (!post) return sendJson(res, 404, { error: '帖子不存在' });
  const viewer = maybeViewer(req);
  const isOwner = viewer && viewer.id === post.authorId;
  if (post.status !== 'published' && !isOwner) {
    return sendJson(res, 404, { error: '帖子不存在或尚未通过审核' });
  }
  const liked = viewer ? (post.likedBy || []).includes(viewer.id) : false;
  sendJson(res, 200, {
    post: publicPost(post, { withContent: true }),
    liked,
  });
}

/** 删除帖子（作者本人） */
export async function handleDeletePost(req, res, id) {
  const user = requireUser(req);
  const db = getDb();
  const index = db.communityPosts.findIndex((p) => p.id === id);
  if (index === -1) return sendJson(res, 404, { error: '帖子不存在' });
  const post = db.communityPosts[index];
  if (post.authorId !== user.id) {
    return sendJson(res, 403, { error: '只能删除自己的帖子' });
  }
  db.communityPosts.splice(index, 1);
  db.communityComments = db.communityComments.filter((c) => c.postId !== id);
  await saveDb();
  sendJson(res, 200, { ok: true, id });
}

/** 点赞 / 取消点赞 */
export async function handleToggleLike(req, res, id) {
  const user = requireUser(req);
  const post = findPost(id);
  if (!post) return sendJson(res, 404, { error: '帖子不存在' });
  if (post.status !== 'published') {
    return sendJson(res, 403, { error: '帖子尚未通过审核' });
  }
  if (!Array.isArray(post.likedBy)) post.likedBy = [];
  const index = post.likedBy.indexOf(user.id);
  if (index === -1) {
    post.likedBy.push(user.id);
  } else {
    post.likedBy.splice(index, 1);
  }
  await saveDb();
  sendJson(res, 200, {
    liked: index === -1,
    likes: post.likedBy.length,
  });
}

/** 我发布的帖子（含审核状态） */
export async function handleMyPosts(req, res) {
  const user = requireUser(req);
  const list = getDb()
    .communityPosts.filter((p) => p.authorId === user.id)
    .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))
    .map((p) => publicPost(p, { withContent: true }));
  sendJson(res, 200, { posts: list, community: communityOf(user) });
}

// ---------------------------------------------------------------------------
// 评论
// ---------------------------------------------------------------------------

export async function handleListComments(req, res, id) {
  const post = findPost(id);
  if (!post) return sendJson(res, 404, { error: '帖子不存在' });
  if (post.status !== 'published') {
    return sendJson(res, 200, { comments: [] });
  }
  const comments = getDb()
    .communityComments.filter((c) => c.postId === id && c.status !== 'hidden')
    .sort((a, b) => String(a.createdAt).localeCompare(String(b.createdAt)))
    .map(publicComment);
  sendJson(res, 200, { comments });
}

export async function handleCreateComment(req, res, id) {
  const user = requireUser(req);
  assertUserActive(user);
  const post = findPost(id);
  if (!post) return sendJson(res, 404, { error: '帖子不存在' });
  if (post.status !== 'published') {
    return sendJson(res, 403, { error: '帖子尚未通过审核，暂不能评论' });
  }
  const body = await readJson(req, { limit: 16 * 1024 });
  const content = String(body.content || '').trim().slice(0, MAX_COMMENT);
  if (!content) return sendJson(res, 400, { error: '评论不能为空' });
  assertClean(content);
  assertNoUnsafeHtml(content);

  const c = communityOf(user);
  if (Date.now() - Number(c.lastCommentAt || 0) < COMMENT_INTERVAL_MS) {
    return sendJson(res, 429, { error: '评论过于频繁，请稍后再试' });
  }

  const comment = {
    id: `cmt_${randomBytes(8).toString('hex')}`,
    postId: id,
    authorId: user.id,
    authorName: authorName(user),
    content,
    status: 'published',
    createdAt: new Date().toISOString(),
  };
  getDb().communityComments.push(comment);
  post.commentCount = (post.commentCount || 0) + 1;
  c.lastCommentAt = Date.now();
  await saveDb();
  sendJson(res, 201, { comment: publicComment(comment) });
}

/** 删除评论（作者本人） */
export async function handleDeleteComment(req, res, id) {
  const user = requireUser(req);
  const db = getDb();
  const index = db.communityComments.findIndex((c) => c.id === id);
  if (index === -1) return sendJson(res, 404, { error: '评论不存在' });
  const comment = db.communityComments[index];
  if (comment.authorId !== user.id) {
    return sendJson(res, 403, { error: '只能删除自己的评论' });
  }
  db.communityComments.splice(index, 1);
  const post = findPost(comment.postId);
  if (post) post.commentCount = Math.max(0, (post.commentCount || 1) - 1);
  await saveDb();
  sendJson(res, 200, { ok: true, id });
}

// ---------------------------------------------------------------------------
// 举报 / 公约 / 公开设置
// ---------------------------------------------------------------------------

export async function handleReportPost(req, res, id) {
  const user = requireUser(req);
  const post = findPost(id);
  if (!post) return sendJson(res, 404, { error: '帖子不存在' });
  const body = await readJson(req, { limit: 8 * 1024 });
  const reason = String(body.reason || '').trim().slice(0, REPORT_REASON_MAX);
  if (!reason) return sendJson(res, 400, { error: '请填写举报原因' });

  const db = getDb();
  const exists = db.communityReports.some(
    (r) => r.postId === id && r.reporterId === user.id && r.status === 'open',
  );
  if (exists) return sendJson(res, 409, { error: '你已举报过该帖子，我们会尽快处理' });

  db.communityReports.push({
    id: `rep_${randomBytes(8).toString('hex')}`,
    postId: id,
    postTitle: post.title,
    reporterId: user.id,
    reporterName: authorName(user),
    reason,
    status: 'open',
    createdAt: new Date().toISOString(),
  });
  await saveDb();
  sendJson(res, 201, { ok: true, message: '举报已提交，管理员会尽快处理' });
}

export async function handleCovenant(req, res) {
  const s = settings();
  sendJson(res, 200, {
    covenant: s.covenant,
    updatedAt: s.updatedAt,
    firstPostReview: s.firstPostReview,
    keywordCount: s.keywords.length,
  });
}

export async function handleCommunitySettingsPublic(req, res) {
  const s = settings();
  sendJson(res, 200, {
    firstPostReview: s.firstPostReview,
    maxPostsPerDay: s.maxPostsPerDay,
    keywordCount: s.keywords.length,
  });
}

// ---------------------------------------------------------------------------
// 管理端
// ---------------------------------------------------------------------------

export async function handleAdminListPosts(req, res) {
  requireAdmin(req);
  const url = new URL(req.url, 'http://localhost');
  const status = String(url.searchParams.get('status') || '').trim();
  const keyword = String(url.searchParams.get('q') || '').trim().toLowerCase();
  let list = getDb().communityPosts.slice();
  if (status && status !== 'all') list = list.filter((p) => p.status === status);
  if (keyword) {
    list = list.filter((p) =>
      `${p.title} ${p.content} ${p.authorName}`.toLowerCase().includes(keyword),
    );
  }
  list.sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
  sendJson(res, 200, {
    posts: list.map((p) => publicPost(p, { withContent: true })),
    counts: {
      total: getDb().communityPosts.length,
      pending: getDb().communityPosts.filter((p) => p.status === 'pending').length,
      published: getDb().communityPosts.filter((p) => p.status === 'published').length,
      rejected: getDb().communityPosts.filter((p) => p.status === 'rejected').length,
    },
  });
}

export async function handleAdminReviewPost(req, res, id) {
  requireAdmin(req);
  const post = findPost(id);
  if (!post) return sendJson(res, 404, { error: '帖子不存在' });
  const body = await readJson(req);
  const action = String(body.action || '').trim();
  if (action !== 'approve' && action !== 'reject') {
    return sendJson(res, 400, { error: 'action 只能是 approve 或 reject' });
  }
  post.status = action === 'approve' ? 'published' : 'rejected';
  post.reviewNote = String(body.note || '').trim().slice(0, 400);
  post.reviewedAt = new Date().toISOString();
  post.updatedAt = post.reviewedAt;

  if (action === 'approve' && !post.approvedCounted) {
    const user = getDb().users.find((u) => u.id === post.authorId);
    if (user) {
      const c = communityOf(user);
      c.approvedPosts = Number(c.approvedPosts || 0) + 1;
    }
    post.approvedCounted = true;
  }
  await saveDb();
  sendJson(res, 200, { post: publicPost(post, { withContent: true }) });
}

export async function handleAdminDeletePost(req, res, id) {
  requireAdmin(req);
  const db = getDb();
  const index = db.communityPosts.findIndex((p) => p.id === id);
  if (index === -1) return sendJson(res, 404, { error: '帖子不存在' });
  db.communityPosts.splice(index, 1);
  db.communityComments = db.communityComments.filter((c) => c.postId !== id);
  await saveDb();
  sendJson(res, 200, { ok: true, id });
}

export async function handleAdminDeleteComment(req, res, id) {
  requireAdmin(req);
  const db = getDb();
  const index = db.communityComments.findIndex((c) => c.id === id);
  if (index === -1) return sendJson(res, 404, { error: '评论不存在' });
  const [removed] = db.communityComments.splice(index, 1);
  const post = findPost(removed.postId);
  if (post) post.commentCount = Math.max(0, (post.commentCount || 1) - 1);
  await saveDb();
  sendJson(res, 200, { ok: true, id });
}

export async function handleAdminGetCommunitySettings(req, res) {
  requireAdmin(req);
  sendJson(res, 200, { settings: settings() });
}

export async function handleAdminPutCommunitySettings(req, res) {
  requireAdmin(req);
  const body = await readJson(req, { limit: 256 * 1024 });
  const db = getDb();
  const current = settings();

  let keywords = current.keywords;
  if (typeof body.keywords === 'string' || Array.isArray(body.keywords)) {
    const rawList = Array.isArray(body.keywords)
      ? body.keywords
      : String(body.keywords).split(/[\n,，]/);
    keywords = rawList
      .map((k) => String(k || '').trim())
      .filter(Boolean)
      .map((k) => k.slice(0, 40))
      .slice(0, 300);
  }

  const covenant =
    typeof body.covenant === 'string' ? body.covenant.slice(0, 64 * 1024) : current.covenant;
  const firstPostReview =
    typeof body.firstPostReview === 'boolean'
      ? body.firstPostReview
      : current.firstPostReview;
  const maxPostsPerDay =
    Number(body.maxPostsPerDay) > 0
      ? Math.min(200, Math.trunc(Number(body.maxPostsPerDay)))
      : current.maxPostsPerDay;

  db.communitySettings = {
    keywords,
    covenant,
    firstPostReview,
    maxPostsPerDay,
    updatedAt: new Date().toISOString(),
  };
  await saveDb();
  sendJson(res, 200, { ok: true, settings: db.communitySettings });
}

export async function handleAdminListReports(req, res) {
  requireAdmin(req);
  const url = new URL(req.url, 'http://localhost');
  const status = String(url.searchParams.get('status') || '').trim();
  let list = getDb().communityReports.slice().reverse();
  if (status && status !== 'all') list = list.filter((r) => r.status === status);
  sendJson(res, 200, { reports: list.slice(0, 200), total: list.length });
}

/** 禁言 / 封禁 / 解封 */
export async function handleAdminUserCommunityStatus(req, res, userId) {
  requireAdmin(req);
  const user = getDb().users.find((u) => u.id === userId);
  if (!user) return sendJson(res, 404, { error: '用户不存在' });
  const body = await readJson(req);
  const c = communityOf(user);
  if (typeof body.banned === 'boolean') c.banned = body.banned;
  if (body.mutedHours !== undefined) {
    const hours = Number(body.mutedHours);
    c.mutedUntil =
      Number.isFinite(hours) && hours > 0
        ? new Date(Date.now() + hours * 60 * 60 * 1000).toISOString()
        : '';
  }
  await saveDb();
  sendJson(res, 200, { ok: true, community: c });
}
