import test from 'node:test';
import assert from 'node:assert/strict';

import { issueAdminToken, issueUserToken, requireAdmin } from '../src/security.js';

const bearer = (token) => ({ headers: { authorization: `Bearer ${token}` } });

test('未配置 ADMIN_TOKEN 时，仓库源码中的旧静态令牌无法通过管理端鉴权', () => {
  assert.throws(
    () => requireAdmin(bearer('dev-only-admin-token-7f3a9c1e5b2d48f0-change-me')),
    (err) => err.status === 401,
  );
});

test('管理员 JWT 可以通过鉴权', () => {
  assert.doesNotThrow(() => requireAdmin(bearer(issueAdminToken())));
});

test('普通用户 JWT 不能通过管理端鉴权', () => {
  assert.throws(
    () => requireAdmin(bearer(issueUserToken('u_test'))),
    (err) => err.status === 401,
  );
});
