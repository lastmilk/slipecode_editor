// 回归测试：saveDb 写入队列自恢复 + AI 附件解压上限
//
// 运行：cd backend && node --test test/

import test from 'node:test';
import assert from 'node:assert/strict';

import { PassThrough } from 'node:stream';
import { mkdtemp, mkdir, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { deflateRawSync } from 'node:zlib';

// db.js 在模块加载时读取 DATA_DIR，必须先设置再 import
process.env.DATA_DIR = await mkdtemp(join(tmpdir(), 'slipe-backend-test-'));

const { DB_FILE, getDb, saveDb } = await import('../src/db.js');
const { signToken } = await import('../src/security.js');
const { handleAiUnzip } = await import('../src/routes/ai_files.js');

function fakeRes() {
  return {
    statusCode: 0,
    headers: null,
    body: '',
    writeHead(status, headers) {
      this.statusCode = status;
      this.headers = headers;
    },
    end(body) {
      this.body = body || '';
    },
  };
}

/** 构造最小 Zip（store / deflate），仅供 readZipEntries 解析 */
function buildZip(entries) {
  const chunks = [];
  const central = [];
  let offset = 0;
  for (const e of entries) {
    const nameBuf = Buffer.from(e.name, 'utf8');
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0, 6); // flags
    local.writeUInt16LE(e.method, 8);
    local.writeUInt32LE(0, 14); // crc（readZipEntries 不校验）
    local.writeUInt32LE(e.data.length, 18);
    local.writeUInt32LE(e.uncompSize, 22);
    local.writeUInt16LE(nameBuf.length, 26);
    chunks.push(local, nameBuf, e.data);

    const cd = Buffer.alloc(46);
    cd.writeUInt32LE(0x02014b50, 0);
    cd.writeUInt16LE(20, 4);
    cd.writeUInt16LE(20, 6);
    cd.writeUInt16LE(e.method, 10);
    cd.writeUInt32LE(e.data.length, 20);
    cd.writeUInt32LE(e.uncompSize, 24);
    cd.writeUInt16LE(nameBuf.length, 28);
    cd.writeUInt32LE(offset, 42);
    central.push(cd, nameBuf);
    offset += 30 + nameBuf.length + e.data.length;
  }
  const cdBuf = Buffer.concat(central);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(entries.length, 8);
  eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(cdBuf.length, 12);
  eocd.writeUInt32LE(offset, 16);
  return Buffer.concat([...chunks, cdBuf, eocd]);
}

test('saveDb：一次写盘失败后队列必须恢复，后续写入仍要落盘', async () => {
  getDb().users.push({
    id: 'u_recover_a',
    email: 'a@test.io',
    displayName: 'a',
    credits: 1,
  });
  await saveDb();

  // 让 DB_FILE 变成目录，rename 必然失败，模拟一次磁盘错误
  await rm(DB_FILE);
  await mkdir(DB_FILE);
  await assert.rejects(() => saveDb());

  // 解除阻碍后，下一次 saveDb 必须真正写入（修复前队列被毒化，永远失败）
  await rm(DB_FILE, { recursive: true });
  getDb().users.push({
    id: 'u_recover_b',
    email: 'b@test.io',
    displayName: 'b',
    credits: 2,
  });
  await saveDb();

  const raw = JSON.parse(await readFile(DB_FILE, 'utf8'));
  assert.ok(
    raw.users.some((u) => u.id === 'u_recover_b'),
    '失败后恢复的 saveDb 必须把数据写入磁盘',
  );
});

test('AI 附件解压：超限条目被跳过并给出大小上限原因（防 Zip 炸弹）', async () => {
  const user = {
    id: 'u_zip_test',
    email: 'zip@test.io',
    displayName: 'zip',
    credits: 1,
  };
  getDb().users.push(user);
  const token = signToken({
    sub: user.id,
    exp: Math.floor(Date.now() / 1000) + 600,
  });

  // 100MB 全零 → DEFLATE 后约 100KB，解压输出远超默认 50MB 上限
  const bomb = Buffer.alloc(100 * 1024 * 1024, 0);
  const ok = Buffer.from('hello slipe');
  const zip = buildZip([
    { name: 'bomb.txt', method: 8, data: deflateRawSync(bomb), uncompSize: bomb.length },
    { name: 'ok.txt', method: 0, data: ok, uncompSize: ok.length },
  ]);

  const req = new PassThrough();
  req.headers = { authorization: `Bearer ${token}` };
  req.end(JSON.stringify({ name: 'bomb.zip', dataBase64: zip.toString('base64') }));
  const res = fakeRes();

  await handleAiUnzip(req, res);

  assert.equal(res.statusCode, 200);
  const payload = JSON.parse(res.body);
  assert.equal(payload.count, 1, '只有未超限的文件应解压成功');
  assert.ok(payload.files.some((f) => f.path === 'ok.txt'));
  assert.ok(
    payload.skipped.some(
      (s) => s.path === 'bomb.txt' && s.reason === '超过解压大小上限',
    ),
    '炸弹条目必须在解压阶段（而非总量统计阶段）被拦截',
  );
});

test('AI 附件解压：正常小文件仍可解压并返回文本预览（回归保护）', async () => {
  const user = { id: 'u_zip_ok', email: 'ok@test.io', displayName: 'ok', credits: 1 };
  getDb().users.push(user);
  const token = signToken({
    sub: user.id,
    exp: Math.floor(Date.now() / 1000) + 600,
  });

  const content = Buffer.from('print("hello")\n'.repeat(10));
  const zip = buildZip([
    { name: 'main.py', method: 8, data: deflateRawSync(content), uncompSize: content.length },
  ]);

  const req = new PassThrough();
  req.headers = { authorization: `Bearer ${token}` };
  req.end(JSON.stringify({ name: 'tiny.zip', dataBase64: zip.toString('base64') }));
  const res = fakeRes();

  await handleAiUnzip(req, res);

  assert.equal(res.statusCode, 200);
  const payload = JSON.parse(res.body);
  assert.equal(payload.count, 1);
  assert.equal(payload.files[0].path, 'main.py');
  assert.equal(payload.files[0].text, content.toString('utf8'));
});
