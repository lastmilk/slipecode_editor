// 数据层：单文件 JSON 存储（原子写入）
//
// 数据量小、单实例部署，用 db.json + 队列写入即可。
// 结构：
//   users / settings / llmModels / projects / chatHistory
//   config  —— 运行期可配置的凭据（极验、阿里云、管理员密码哈希）
//   stats   —— 运营统计（总量 + 按天）

import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));

export const DATA_DIR =
  process.env.DATA_DIR || join(__dirname, '..', 'data');
export const DB_FILE = join(DATA_DIR, 'db.json');
/** 用户上传的头像 / 壁纸 */
export const UPLOAD_DIR = join(DATA_DIR, 'uploads');

const DEFAULT_DB = {
  users: [],
  settings: {},
  llmModels: [],
  projects: {},
  chatHistory: {},
  // 管理员发布的使用文档（Markdown）
  docs: [],
  // 运行期配置（优先级高于环境变量，便于在管理端热更新）
  config: {
    geetest: {},
    aliyun: {},
    admin: { passwordHash: '' },
    // 面向用户端的运营信息（公开只读）
    portal: { qqGroup: '' },
  },
  stats: {
    totals: {
      registers: 0,
      logins: 0,
      smsSent: 0,
      captchaPass: 0,
      captchaFail: 0,
      llmCalls: 0,
      tokensUsed: 0,
    },
    daily: {},
  },
};

let db = structuredClone(DEFAULT_DB);
let writeQueue = Promise.resolve();

/** 当前内存中的数据库对象（只读使用，修改后需调用 saveDb） */
export function getDb() {
  return db;
}

export async function loadDb() {
  await mkdir(DATA_DIR, { recursive: true });
  try {
    const raw = await readFile(DB_FILE, 'utf8');
    const parsed = JSON.parse(raw);
    db = {
      users: Array.isArray(parsed.users) ? parsed.users : [],
      settings:
        parsed.settings && typeof parsed.settings === 'object' ? parsed.settings : {},
      llmModels: Array.isArray(parsed.llmModels) ? parsed.llmModels : [],
      projects:
        parsed.projects && typeof parsed.projects === 'object' ? parsed.projects : {},
      chatHistory:
        parsed.chatHistory && typeof parsed.chatHistory === 'object'
          ? parsed.chatHistory
          : {},
      docs: Array.isArray(parsed.docs) ? parsed.docs : [],
      config: mergeConfig(parsed.config),
      stats: mergeStats(parsed.stats),
    };
  } catch (err) {
    if (err.code !== 'ENOENT') throw err;
    await saveDb();
  }
}

/** 合并旧版本 db.json 中缺失的字段，保证向后兼容 */
function mergeConfig(raw) {
  const base = structuredClone(DEFAULT_DB.config);
  if (!raw || typeof raw !== 'object') return base;
  return {
    geetest: { ...base.geetest, ...(raw.geetest || {}) },
    aliyun: { ...base.aliyun, ...(raw.aliyun || {}) },
    admin: { ...base.admin, ...(raw.admin || {}) },
    portal: { ...base.portal, ...(raw.portal || {}) },
  };
}

function mergeStats(raw) {
  const base = structuredClone(DEFAULT_DB.stats);
  if (!raw || typeof raw !== 'object') return base;
  return {
    totals: { ...base.totals, ...(raw.totals || {}) },
    daily: raw.daily && typeof raw.daily === 'object' ? raw.daily : {},
  };
}

/** 原子写盘（tmp + rename），并发调用串行执行 */
export function saveDb() {
  writeQueue = writeQueue.then(async () => {
    await mkdir(DATA_DIR, { recursive: true });
    const tmp = `${DB_FILE}.tmp`;
    await writeFile(tmp, JSON.stringify(db, null, 2), 'utf8');
    await rename(tmp, DB_FILE);
  });
  return writeQueue;
}

// ---------------------------------------------------------------------------
// 统计埋点
// ---------------------------------------------------------------------------

/** 服务器本地日期，YYYY-MM-DD */
export function todayStr() {
  const d = new Date();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${d.getFullYear()}-${m}-${day}`;
}

/**
 * 记录一次统计事件（总量 + 当日）。
 * @param {string} name 事件名，例如 registers / logins / smsSent
 * @param {number} amount 增量，默认 1
 */
export function bumpStat(name, amount = 1) {
  const stats = db.stats;
  stats.totals[name] = (stats.totals[name] || 0) + amount;
  const today = todayStr();
  const day = (stats.daily[today] ||= {});
  day[name] = (day[name] || 0) + amount;
  // 只保留最近 60 天，避免 db.json 无限增长
  const keys = Object.keys(stats.daily).sort();
  while (keys.length > 60) {
    delete stats.daily[keys.shift()];
  }
}

/** 取最近 N 天的统计序列（缺省补 0） */
export function dailySeries(days = 14) {
  const out = [];
  const now = new Date();
  for (let i = days - 1; i >= 0; i -= 1) {
    const d = new Date(now.getFullYear(), now.getMonth(), now.getDate() - i);
    const key = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(
      d.getDate(),
    ).padStart(2, '0')}`;
    const value = db.stats.daily[key] || {};
    out.push({
      date: key,
      registers: value.registers || 0,
      logins: value.logins || 0,
      smsSent: value.smsSent || 0,
    });
  }
  return out;
}
