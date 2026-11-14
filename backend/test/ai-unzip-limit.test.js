import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import { deflateRawSync } from 'node:zlib';

// DATA_DIR（决定 ai_tmp 位置）在模块加载时读取，必须先设置
const root = await mkdtemp(join(tmpdir(), 'slipe-unzip-'));
process.env.DATA_DIR = root;

const { handleAiUnzip } = await import('../src/routes/ai_files.js');
const { getDb } = await import('../src/db.js');
const { issueUserToken } = await import('../src/security.js');

const USER_ID = 'u_unzip_test';

/** 构造最小 Zip（仅 store / deflate，服务端不校验 CRC） */
function buildZip(entries) {
  const localParts = [];
  const centralParts = [];
  let offset = 0;

  for (const entry of entries) {
    const name = Buffer.from(entry.name, 'utf8');
    const payload =
      entry.method === 8 ? deflateRawSync(entry.data) : entry.data;

    const local = Buffer.alloc(30 + name.length);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(entry.method, 8);
    local.writeUInt32LE(payload.length, 18);
    local.writeUInt32LE(entry.data.length, 22);
    local.writeUInt16LE(name.length, 26);
    name.copy(local, 30);

    const central = Buffer.alloc(46 + name.length);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(entry.method, 10);
    central.writeUInt32LE(payload.length, 20);
    central.writeUInt32LE(entry.data.length, 24);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt32LE(offset, 42);
    name.copy(central, 46);

    localParts.push(local, payload);
    centralParts.push(central);
    offset += local.length + payload.length;
  }

  const centralDir = Buffer.concat(centralParts);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(entries.length, 8);
  eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(centralDir.length, 12);
  eocd.writeUInt32LE(offset, 16);

  return Buffer.concat([...localParts, centralDir, eocd]);
}

function makeReq(payload) {
  const req = Readable.from([Buffer.from(JSON.stringify(payload))], {
    objectMode: false,
  });
  req.headers = { authorization: `Bearer ${issueUserToken(USER_ID)}` };
  req.socket = { remoteAddress: '127.0.0.1' };
  return req;
}

function makeRes() {
  const out = { status: 0, json: null };
  return {
    writeHead(status) {
      out.status = status;
    },
    end(chunk) {
      out.json = chunk ? JSON.parse(String(chunk)) : null;
    },
    out,
  };
}

getDb().users.push({ id: USER_ID, email: 'unzip@example.com' });

test('正常 Zip 仍可解压并返回文本预览', async (t) => {
  t.after(() => rm(root, { recursive: true, force: true }));
  const zip = buildZip([
    { name: 'hello.txt', data: Buffer.from('hello world'), method: 8 },
  ]);
  const res = makeRes();
  await handleAiUnzip(
    makeReq({ name: 'hello.zip', dataBase64: zip.toString('base64') }),
    res,
  );
  assert.equal(res.out.status, 200);
  assert.equal(res.out.json.count, 1);
  assert.equal(res.out.json.files[0].text, 'hello world');
});

test('超过解压额度的条目不会在总量检查前被完整解压（Zip 炸弹）', async (t) => {
  t.after(() => rm(root, { recursive: true, force: true }));
  // 60MB 全零内容压缩后仅几十 KB，但解压会远超 50MB 上限
  const bomb = buildZip([
    { name: 'bomb.bin', data: Buffer.alloc(60 * 1024 * 1024), method: 8 },
  ]);
  const res = makeRes();
  await handleAiUnzip(
    makeReq({ name: 'bomb.zip', dataBase64: bomb.toString('base64') }),
    res,
  );
  assert.equal(res.out.status, 200);
  assert.equal(res.out.json.count, 0);
  assert.equal(res.out.json.totalSize, 0);
  assert.equal(res.out.json.skipped[0].reason, '解压失败');
});
