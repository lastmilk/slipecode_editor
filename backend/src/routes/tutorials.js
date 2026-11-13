// 社区教程：课程清单 + 单课内容
//
// 课程定义放在 content/tutorials/（随后端代码发布），
// 大资源放在 data/tutorials/，由 /tutorial-assets/* 静态路由按需下载。

import { readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { DATA_DIR } from '../db.js';
import { sendJson } from '../http.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

export const TUTORIALS_DIR =
  process.env.TUTORIALS_DIR || join(__dirname, '..', '..', 'content', 'tutorials');
export const TUTORIAL_ASSETS_DIR =
  process.env.TUTORIAL_ASSETS_DIR || join(DATA_DIR, 'tutorials');

const CACHE_TTL_MS = 5 * 60 * 1000;
let manifestCache = null;
let manifestCachedAt = 0;

async function readJson(file) {
  const text = await readFile(file, 'utf8');
  return JSON.parse(text);
}

export async function loadManifest() {
  if (manifestCache && Date.now() - manifestCachedAt < CACHE_TTL_MS) {
    return manifestCache;
  }
  try {
    const manifest = await readJson(join(TUTORIALS_DIR, 'manifest.json'));
    const tracks = Array.isArray(manifest.tracks) ? manifest.tracks : [];
    const normalized = {
      version: manifest.version || 1,
      updatedAt: manifest.updatedAt || '',
      tracks: tracks
        .filter((t) => t && typeof t === 'object')
        .map((track) => ({
          id: String(track.id || ''),
          name: String(track.name || ''),
          description: String(track.description || ''),
          lessons: (Array.isArray(track.lessons) ? track.lessons : [])
            .filter((l) => l && l.id)
            .map((lesson) => ({
              id: String(lesson.id),
              title: String(lesson.title || ''),
              summary: String(lesson.summary || ''),
              order: Number(lesson.order || 0),
              durationMin: Number(lesson.durationMin || 0),
              stepCount: Number(lesson.stepCount || 0),
              tags: Array.isArray(lesson.tags) ? lesson.tags.map(String) : [],
              assets: Array.isArray(lesson.assets)
                ? lesson.assets.map((a) => ({
                    id: String(a.id || ''),
                    name: String(a.name || '资源包'),
                    size: Number(a.size || 0),
                    url: String(a.url || ''),
                  }))
                : [],
            }))
            .sort((a, b) => a.order - b.order),
        }))
        .filter((t) => t.id),
    };
    manifestCache = normalized;
    manifestCachedAt = Date.now();
    return normalized;
  } catch (err) {
    if (err.code !== 'ENOENT') {
      console.warn('[tutorials] 读取 manifest 失败：', err.message);
    }
    return { version: 1, updatedAt: '', tracks: [] };
  }
}

/** GET /api/tutorials */
export async function handleListTutorials(req, res) {
  const manifest = await loadManifest();
  const total = manifest.tracks.reduce((sum, t) => sum + t.lessons.length, 0);
  sendJson(res, 200, { ...manifest, total });
}

/** GET /api/tutorials/:id */
export async function handleGetTutorial(req, res, id) {
  const safeId = String(id || '').trim();
  if (!/^[a-zA-Z0-9_-]+$/.test(safeId)) {
    return sendJson(res, 400, { error: '课程 ID 不合法' });
  }
  const manifest = await loadManifest();
  const allLessons = manifest.tracks.flatMap((t) => t.lessons);
  const meta = allLessons.find((l) => l.id === safeId);
  if (!meta) return sendJson(res, 404, { error: '课程不存在' });

  try {
    const lesson = await readJson(join(TUTORIALS_DIR, 'lessons', `${safeId}.json`));
    sendJson(res, 200, {
      ...lesson,
      id: safeId,
      track: lesson.track || manifest.tracks.find((t) => t.lessons.some((l) => l.id === safeId))?.id || '',
      assets: meta.assets,
    });
  } catch (err) {
    if (err.code === 'ENOENT') {
      return sendJson(res, 404, { error: '课程内容尚未发布' });
    }
    console.warn('[tutorials] 读取课程失败：', safeId, err.message);
    return sendJson(res, 500, { error: '课程内容读取失败' });
  }
}
