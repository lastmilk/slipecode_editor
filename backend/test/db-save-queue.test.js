import test from 'node:test';
import assert from 'node:assert/strict';
import { access, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// DATA_DIR 在模块加载时读取，因此必须先设置再动态导入
const root = await mkdtemp(join(tmpdir(), 'slipe-db-'));
process.env.DATA_DIR = join(root, 'data');
const { DB_FILE, saveDb } = await import('../src/db.js');

test('单次写盘失败后，后续 saveDb 仍能恢复并正常落盘', async (t) => {
  t.after(() => rm(root, { recursive: true, force: true }));

  // 用普通文件占住 DATA_DIR，让 mkdir 失败，模拟磁盘故障
  await writeFile(process.env.DATA_DIR, 'occupied');
  await assert.rejects(saveDb());

  // 故障恢复后，写入队列不应被上一次失败永久污染
  await rm(process.env.DATA_DIR);
  await mkdir(process.env.DATA_DIR, { recursive: true });
  await assert.doesNotReject(saveDb());
  await access(DB_FILE);
});
