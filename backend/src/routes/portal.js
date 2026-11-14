// 官网聚合数据（公开只读）
//
// 官网首屏一次请求拿齐：最新安装包、运营统计、社区帖子、教程轨道、
// 会员套餐与 QQ 群。避免首页并发五六个接口，也便于以后做边缘缓存。

import {
  CHECKIN_REWARD,
  INITIAL_CREDITS,
  MEMBERSHIP_CYCLES,
  MEMBERSHIP_PLANS,
  TOKENS_PER_CREDIT,
} from '../config.js';
import { getDb } from '../db.js';
import { sendJson } from '../http.js';
import { publicRelease } from './releases.js';
import { loadManifest } from './tutorials.js';

/** 首页最多展示的社区帖子数 */
const MAX_POSTS = 3;

function excerptOf(content) {
  return String(content || '').replace(/\s+/g, ' ').trim().slice(0, 160);
}

/** GET /api/public/overview */
export async function handlePublicOverview(req, res) {
  const db = getDb();
  const release = db.release && db.release.version ? publicRelease(db.release) : null;

  const published = db.communityPosts.filter((p) => p.status === 'published');
  const posts = published
    .slice()
    .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))
    .slice(0, MAX_POSTS)
    .map((p) => ({
      id: p.id,
      authorName: p.authorName || '',
      title: p.title || '',
      excerpt: excerptOf(p.content),
      tags: Array.isArray(p.tags) ? p.tags : [],
      likes: Array.isArray(p.likedBy) ? p.likedBy.length : 0,
      commentCount: p.commentCount || 0,
      createdAt: p.createdAt,
    }));

  const manifest = await loadManifest();
  const tutorials = manifest.tracks.map((track) => ({
    id: track.id,
    name: track.name,
    description: track.description,
    lessonCount: track.lessons.length,
    durationMin: track.lessons.reduce((sum, lesson) => sum + (lesson.durationMin || 0), 0),
  }));
  const lessonTotal = tutorials.reduce((sum, track) => sum + track.lessonCount, 0);

  sendJson(res, 200, {
    release,
    stats: {
      users: db.users.length,
      posts: published.length,
      tutorials: tutorials.length,
      lessons: lessonTotal,
      downloads: release ? release.downloads || 0 : 0,
    },
    posts,
    tutorials,
    plans: {
      plans: MEMBERSHIP_PLANS,
      cycles: MEMBERSHIP_CYCLES,
      pricing: {
        tokensPerCredit: TOKENS_PER_CREDIT,
        initialCredits: INITIAL_CREDITS,
        checkinReward: CHECKIN_REWARD,
        currency: 'CNY',
      },
    },
    qqGroup: String(db.config?.portal?.qqGroup || ''),
    serverTime: Date.now(),
  });
}
