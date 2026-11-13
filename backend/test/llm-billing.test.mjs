// LLM 计费并发预留回归测试
//
// 回归缺陷：余额校验发生在请求开始，实际扣费在响应结束后且钳制不低于 0。
// 修复前，并发请求共用同一次余额校验结果（1 积分可发起任意数量的并发调用），
// 且超大 prompt 的预估成本（可达上千积分）只需 1 积分余额即可放行。
// 修复后：放行前按 prompt 侧预估成本预留，结算时释放。
import { test, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// 必须在后端模块 import 前设置（config.js / db.js 在模块加载时读取）
process.env.DATA_DIR = mkdtempSync(join(tmpdir(), 'slipe-llm-test-'));
process.env.JWT_SECRET = 'test-secret';

const { handleLlmChat, inflightReservedFor } = await import('../src/routes/llm.js');
const { issueUserToken } = await import('../src/security.js');
const { getDb } = await import('../src/db.js');

const MODEL_ID = 'm_test_model';
const USER_A = 'u_test_a';
const USER_B = 'u_test_b';
const USER_C = 'u_test_c';

function seed() {
  const db = getDb();
  db.llmModels.push({
    id: MODEL_ID,
    name: '测试模型',
    apiBase: 'https://upstream.example/v1',
    apiKey: 'sk-test',
    model: 'test-model',
    multiplier: 1,
    enabled: true,
  });
  for (const [id, credits] of [
    [USER_A, 2],
    [USER_B, 1],
    [USER_C, 5],
  ]) {
    db.users.push({ id, credits, status: 'active', creditLogs: [] });
  }
}
seed();

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

/** 上游桩：返回带 usage 的最小 JSON 响应（total_tokens=10 → 计 1 积分） */
function stubFetch() {
  globalThis.fetch = async () => ({
    ok: true,
    status: 200,
    text: async () =>
      JSON.stringify({
        choices: [{ message: { content: 'ok' } }],
        usage: { total_tokens: 10 },
      }),
  });
}

/** 构造 handleLlmChat 可读取的请求桩（readJson 监听 data/end） */
function chatReq(token, bodyObj) {
  const req = new EventEmitter();
  req.headers = { authorization: `Bearer ${token}` };
  const payload = Buffer.from(JSON.stringify(bodyObj));
  queueMicrotask(() => {
    req.emit('data', payload);
    req.emit('end');
  });
  return req;
}

function chatRes() {
  return {
    statusCode: 0,
    body: '',
    writeHead(status) {
      this.statusCode = status;
    },
    end(body) {
      this.body = String(body ?? '');
    },
  };
}

function userById(id) {
  return getDb().users.find((u) => u.id === id);
}

test('并发请求按预留校验：余额 2 积分时，第三个并发请求被 402 拒绝', async () => {
  stubFetch();
  const token = issueUserToken(USER_A);
  const responses = [];
  const pending = [1, 2, 3].map(() => {
    const res = chatRes();
    responses.push(res);
    return handleLlmChat(chatReq(token, { model: MODEL_ID, messages: [{ role: 'user', content: 'hi' }] }), res);
  });
  await Promise.all(pending);

  assert.equal(responses[0].statusCode, 200);
  assert.equal(responses[1].statusCode, 200);
  assert.equal(responses[2].statusCode, 402, '超出余额的并发请求必须被拒绝');
  assert.equal(userById(USER_A).credits, 0, '2 个成功调用 × 1 积分 = 2');
  assert.equal(inflightReservedFor(USER_A), 0, '全部结算后预留必须释放');
});

test('大 prompt 预估成本超出余额时直接 402，不再放行', async () => {
  stubFetch();
  const token = issueUserToken(USER_B);
  const res = chatRes();
  await handleLlmChat(
    chatReq(token, { model: MODEL_ID, messages: [{ role: 'user', content: 'x'.repeat(12000) }] }),
    res,
  );

  assert.equal(res.statusCode, 402, '预估成本 6 积分 > 余额 1，必须拒绝');
  assert.equal(userById(USER_B).credits, 1, '拒绝时不得扣费');
  assert.equal(inflightReservedFor(USER_B), 0);
});

test('单次请求正常计费、预留释放，后续请求不受影响', async () => {
  stubFetch();
  const token = issueUserToken(USER_C);
  const res1 = chatRes();
  await handleLlmChat(chatReq(token, { model: MODEL_ID, messages: [{ role: 'user', content: 'hi' }] }), res1);

  assert.equal(res1.statusCode, 200);
  assert.equal(inflightReservedFor(USER_C), 0, '结算后预留必须释放');
  assert.equal(userById(USER_C).credits, 4, '5 - 1 = 4');

  const res2 = chatRes();
  await handleLlmChat(chatReq(token, { model: MODEL_ID, messages: [{ role: 'user', content: 'hi' }] }), res2);
  assert.equal(res2.statusCode, 200, '预留未泄漏，后续请求可正常发起');
  assert.equal(userById(USER_C).credits, 3);
});
