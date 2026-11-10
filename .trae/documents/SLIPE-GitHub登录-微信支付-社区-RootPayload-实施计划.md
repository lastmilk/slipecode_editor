# SLIPE：GitHub 登录修复 + 微信支付上线 + 社区（TDesign）+ 自定义 Root Payload 实施计划

> 版本基线：Flutter 3.47.8 / Dart 3.13.7；后端 Node.js（线上 v24.22.1，宝塔 Node 项目 `slipecode-api`）。
> 本计划中的路径、行号、线上状态均来自当前仓库与线上服务器（`/www/wwwroot/slipecode-api`）的实地核查。

---

## 1. 摘要

| # | 需求 | 交付要点 |
|---|---|---|
| 1 | GitHub 登录失效 | 修正线上深链协议/路径不一致；后端回调改为 HTML 桥接页；App 增加冷启动 initial-link 与回前台补捞 |
| 2 | 微信支付上线 | 复用线上已实现的 H5 支付页 + JSAPI；App 内展示支付二维码、轮询订单、到账刷新；对齐会员档位 |
| 3 | 社区功能 | 主界面右划进入；TDesign 视觉；含交互式教程（APP 基础 + 图片中的 21 个 Flutter 主题，资源按需下载)、Payload 列表、发帖/评论/点赞、关键词过滤、首帖审核、社区公约 |
| 4 | 自定义 Root Payload | Root Payload = 环境变量组 + GitHub Actions workflow；支持创建/编辑/删除/发布社区/导入，并在创建 Loader 项目时注入 workflow 与 `.env.example` |

**实施顺序（强依赖）：**
0. 同步线上后端源码回仓库（否则后续部署会覆盖线上支付能力）
1. GitHub OAuth 修复
2. 微信支付 App 端接入
3. 自定义 Root Payload
4. 社区后端（论坛 + 教程 + 审核 + 公约）
5. 社区 App（TDesign + 右划 + 教程）
6. 教程内容与资源制作/上传
7. 部署与端到端验收

---

## 2. 现状分析与关键发现

### 2.1 线上后端比仓库新（必须先同步）

线上 `/www/wwwroot/slipecode-api` 已包含仓库中不存在的支付能力：

- `src/routes/membership.js`（858 行）：会员档位、微信下单、订单查询、支付回调、H5 支付页、JSAPI 调用、管理员订单列表
- `src/services/wechat_pay.js`（381 行）：API v3 签名、平台证书、回调解密、JSAPI 预下单、查单、网页授权
- `src/config.js`（370 行，本地仅 152 行）：`MEMBERSHIP_PLANS`、`MEMBERSHIP_CYCLES`、`wechatPayConfig()`、`wechatPayReady()`
- `src/db.js`（364 行，本地 287 行）：`payOrders`、`config.wechatPay`
- `src/server.js`（482 行，本地 423 行）：`/api/billing/wechat/order`、`/api/pay/wechat/notify`、`/pay`、`/pay/oauth`、`/pay/api/jsapi`、`/pay/api/status`、`/pay/api/confirm`
- `admin/app.js` / `admin/index.html` 均比仓库新

线上 `data/db.json` 已存在 `config.wechatPay`（appId / appSecret / mchId / serialNo / apiV3Key / privateKeyPem / publicKeyPem / publicKeyId / notifyUrl / pageBase 均已配置）与 `payOrders: []`。

**结论：先把线上后端源码完整同步回 `backend/`，以线上为基线再开发。**

### 2.2 GitHub 登录失效的直接根因

- App 监听深链：`.env` → `GITHUB_DEEP_LINK=slipe://gitoauth2`；`lib/config/app_config.dart:38-41`
- Android 只声明了 `slipe` scheme（`android/app/src/main/AndroidManifest.xml:53-59`），iOS `CFBundleURLSchemes` 也是 `slipe`（`ios/Runner/Info.plist:28-40`）
- 线上启动脚本实际环境变量：`GITHUB_DEEP_LINK=slipecode://oauth/callback`

→ 后端换到 token 后 302 到 `slipecode://oauth/callback`，App 永远收不到，最终表现为「授权后没有回调、等待超时」。

次要风险：
1. Chrome Custom Tab 对服务端 302 跳转自定义 scheme 常被拦截（`ERR_UNKNOWN_URL_SCHEME`），需要 HTML 桥接页 + 用户点击。
2. 冷启动场景：App 被系统回收后由深链拉起，`app_links` 的 `uriLinkStream` 不一定补发初始链接，当前 `GitHubAuthService.signIn` 未调用 `getInitialLink()`（`lib/services/github_auth_service.dart:98-121`）。
3. 线上 `GITHUB_REDIRECT_URI=https://ser1996.niav.cn/api/oauth/github/callback`，App 使用 `https://api.lineregre.com/api/oauth/github/callback`；后端虽按真实 Host 反推，但需确保 GitHub OAuth App 注册的是 App 实际使用的回调域名。

### 2.3 微信支付：后端已完成，App 未接入

- 线上接口契约：
  - `POST /api/billing/wechat/order`（需登录）body `{planId, cycleId}` → `{ok, order, payUrl, appId}`，其中 `payUrl = ${pageBase}/pay?order=<outTradeNo>`
  - `GET /api/billing/wechat/order?outTradeNo=...`（需登录）→ 订单状态；pending 时服务端节流 4 秒查单并自动结算
  - `GET /api/billing/plans` 现在返回 `plans`（会员档位）、`cycles`、`creditPlans`（激活码面额）、`wechatPay: {enabled, pageBase}`
- 支付页 `/pay` 在微信内完成网页授权（`/pay/oauth`）→ `/pay/api/jsapi` 预下单 → `WeixinJSBridge` 唤起支付；`/pay/api/confirm` 支持手动确认。
- App 现状：`lib/models/credits.dart` 只有旧 `CreditPlan`；`lib/services/account_service.dart:583-603` 只解析 `plans[].credits/price`；`lib/widgets/credits_sheet.dart` 仍是「套餐 + 激活码」，没有二维码入口。

→ 需求中的「App 内展示二维码 → 用户截图 → 微信识别 → 微信内充值界面」正好对应线上 `payUrl` 的 H5 支付页。

### 2.4 社区现状

- `lib/screens/community_screen.dart` 只有「社区包 / 我的发布」两个 Tab，用于 Payload 分享。
- `lib/services/community_service.dart` + `backend/src/routes/community.js` 只有 Payload 包的发布/列表/下载/审核（`KINDS = system | block`）。
- 没有帖子、评论、教程、公约、关键词过滤、首帖审核。

### 2.5 Root Payload 现状

- `lib/payloads/loader/loader_payload.dart:116-149,355-407`：`RootPayloadSpec` 与 `RootPayloadRegistry.all` 为内置常量，无自定义能力。
- `lib/services/custom_payload_service.dart`：只支持 System / Block 的自定义与持久化。
- `lib/services/loader_project_service.dart:218-221`：直接把 `rootSpec.resolveWorkflow()` 写入 `.github/workflows/...`，没有环境变量注入。
- `lib/screens/custom_payload_manager_screen.dart` / `custom_payload_editor_screen.dart`：只有 system/block 编辑器。

---

## 3. 决策与假设（无需再问，直接执行）

1. **线上后端源码作为唯一基线**：先原样同步回仓库，再在其上增量开发；同步时保留线上 `data/` 与 `admin/vendor/` 不动。
2. **微信支付采用线上已实现的 H5 支付页 + JSAPI**，App 只负责展示 `payUrl` 二维码与轮询结果；不在 App 内直接拉起微信。
3. **充值 UI 对齐线上会员体系**：Personal（免费）/ Lite / Pro / Ultimate，周期月/季/年；激活码保留为人工充值渠道。
4. **社区视觉使用 `tdesign_flutter`**（1.1.0，要求 Flutter ≥3.32，当前 3.47.8 满足），仅在社区路由子树包 `TTheme`，不改变 App 全局 Material 主题。
5. **「右划进入社区」= 手指从左向右滑动**，在主界面触发；同时保留右上角显式入口。
6. **教程内容按图片中的 21 个 Flutter 主题全部编写**，另加 6 课「APP 基本操作」，共 27 课；每课为结构化 JSON（文本/代码/测验/动手步骤），资源包按需下载，不在安装包内置。
7. **首帖审核定义**：用户历史「已通过」帖子数 = 0 时，新帖进入 `pending`；管理员通过后该作者后续帖子自动发布（仍过关键词过滤）。
8. **关键词过滤在服务端强制执行**，客户端只做提交前提示；管理端可热更新词库。
9. **不引入数据库**：继续使用单文件 `db.json`，新字段在 `loadDb()` 中做默认值合并，旧数据自动兼容。
10. **教程资源与内容放服务器**：课程定义随后端代码发布到 `content/tutorials/`；大资源放 `data/tutorials/`，通过静态路由下载。

---

## 4. 详细变更

### 阶段 0：同步线上后端基线

**怎么做**
- 通过宝塔 MCP 的 `Read` 逐文件读取线上内容，再用本地 `Write` 覆盖到 `backend/`：
  - `src/config.js`、`src/db.js`、`src/http.js`、`src/security.js`、`src/server.js`
  - `src/routes/*.js`（新增 `membership.js`）
  - `src/services/wechat_pay.js`（新增）
  - `admin/app.js`、`admin/index.html`、`admin/styles.css`
  - `README.md`、`deploy.sh`、`package.json`
- 不覆盖：`backend/data/`、`backend/admin/vendor/`、本地 `.env`。

**为什么**
- 本地缺少支付模块，若直接部署本地 `backend/` 会删除线上微信支付接口。

**怎么验收**
- 本地与线上对每个文件做 MD5 对比，除 `data/`、`vendor/` 外全部一致。
- `node --check` 所有 `src/**/*.js` 通过。

---

### 阶段 1：GitHub 登录修复

#### 1.1 后端：回调改 HTML 桥接页

**文件**：`backend/src/routes/oauth.js`

- 新增 `sendDeepLinkBridge(res, deepLink, params)`：
  - 返回 `200 text/html`（不再直接 302 到自定义 scheme）。
  - 页面内容：
    - 自动尝试 `location.href = "slipe://gitoauth2?..."`；
    - 明显的「打开 SLIPE 完成登录」按钮（用户手势，Custom Tab 必过）；
    - 失败/错误时展示 `error_description` 与「复制 ticket」按钮；
    - 3 秒后提示「若未自动跳转，请点击上方按钮」。
  - `Cache-Control: no-store`、`X-Content-Type-Options: nosniff`。
- `handleGithubCallback` 的所有分支（error / missing_code / exchange_failed / success）统一走桥接页。
- 兼容旧配置：若 `GITHUB.deepLink` 不以 `slipe://` 开头，日志打印警告，但仍按配置生成。

**文件**：`backend/src/config.js`
- `GITHUB.deepLink` 默认值保持 `slipe://gitoauth2`。

- 修改 `/www/wwwroot/slipecode-api/slipecode-api_start.sh`：
  - `export GITHUB_DEEP_LINK=slipe://gitoauth2`
  - `export GITHUB_REDIRECT_URI=https://api.lineregre.com/api/oauth/github/callback`（与 App `.env` 完全一致）
  - 三个域名（api.lineregre.com / api.slipe.cn / ser1996.niav.cn）都指向同一站点，但 GitHub OAuth App 后台登记的必须是 api.lineregre.com 这一个。

#### 1.2 App：冷启动与回前台补捞深链

**新增**：`lib/services/oauth_link_bus.dart`
- 单例，`init()` 时：
  - `AppLinks().getInitialLink()` 缓存初始链接；
  - 订阅 `uriLinkStream`，缓存最后一条 `slipe://` 链接并广播给等待者。
- 提供 `waitFor(Uri matcher, Duration timeout)`：先检查已缓存链接，再等待流事件。
- `main()` 在 `runApp` 前调用 `OAuthLinkBus.instance.init()`。

**修改**：`lib/services/github_auth_service.dart`
- 用 `OAuthLinkBus` 替换内部 `_linkSub`/`_pendingCallback`。
- `_isCallbackUri` 同时接受：
  - `slipe://gitoauth2`
  - `slipecode://oauth/callback`（兼容线上旧配置，避免灰度期失败）
- 超时提示改为可操作文案：「未收到授权回调。请在浏览器中点击『打开 SLIPE』，或返回 App 后重试」。
- 保留 state 校验、ticket/code 二选一逻辑。

**修改**：`lib/services/gitee_auth_service.dart`
- 同样接入 `OAuthLinkBus`（Gitee 回调 `slipe://oauth/gitee/callback` 也受冷启动影响）。

**修改**：`lib/main.dart`
- 初始化 `OAuthLinkBus`；若初始链接是 OAuth 回调，等待 Provider 初始化完成后再投递（`addPostFrameCallback`）。

**兼容声明**
- `android/app/src/main/AndroidManifest.xml` 追加 `slipecode` scheme 的 intent-filter（host `oauth`，pathPrefix `/callback`），防止旧版服务端/旧链接无法唤起。
- `ios/Runner/Info.plist` 的 `CFBundleURLSchemes` 追加 `slipecode`。

**验收**
- 浏览器打开授权页 → GitHub 授权 → 出现桥接页 → 点「打开 SLIPE」→ App 回到前台并登录成功。
- 冷启动：先在浏览器授权，再让 App 被回收，点击深链后仍能登录。
- 错误场景（state 不匹配/后端换 token 失败）在 App 内有明确文案。

---

### 阶段 2：微信支付 App 端接入

#### 2.1 依赖

`pubspec.yaml` 增加：
- `qr_flutter: ^4.1.0`

#### 2.2 模型

**文件**：`lib/models/credits.dart`
- 新增：
  - `MembershipPlan {id, name, free, monthlyCredits, checkinReward, prices: Map<String,double>, description, badge}`
  - `MembershipCycle {id, name, months, unit}`
  - `WechatPayInfo {enabled, pageBase}`
  - `WechatOrder {id, outTradeNo, planId, planName, cycleId, cycleName, amount, amountFen, status, createdAt, paidAt, transactionId}`
- 保留 `CreditPlan`（服务端 `creditPlans` 仍用于激活码面额展示）。
- `BillingInfo` 扩展：`plans`（会员）、`cycles`、`creditPlans`、`wechatPay`。

#### 2.3 服务与 Provider

**文件**：`lib/services/account_service.dart`
- `fetchBillingPlans()` 改为解析新结构，兼容旧后端（无 `cycles` 时回退到旧 `plans`）。
- 新增：
  - `Future<({WechatOrder order, String payUrl, String appId})> createWechatOrder(String token, {required String planId, required String cycleId})`
  - `Future<({WechatOrder order, bool paid, int credits, String warning})> fetchWechatOrder(String token, String outTradeNo)`

**文件**：`lib/providers/account_provider.dart`
- 新增 `wechatPayInfo`、`createWechatOrder`、`pollWechatOrder`（带取消标记，避免弹窗关闭后继续请求）。

#### 2.4 UI

**修改**：`lib/widgets/credits_sheet.dart`
- 余额卡片下方改为会员档位卡片（横向滚动），每张卡片展示：档位名、徽标、每月积分、签到积分、月/季/年价格切换。
- 点击付费档位 → 打开 `WechatPayQrDialog`。
- 「激活码兑换」保留为次要入口。
- 无微信支付配置时（`wechatPay.enabled == false`）禁用按钮并提示「管理员未完成微信支付配置」。

**新增**：`lib/widgets/wechat_pay_qr_dialog.dart`
- 流程：
  1. 调用下单接口 → 获取 `payUrl`。
  2. `QrImageView(data: payUrl, size: 220)` 展示二维码。
  3. 文案（分步骤）：「① 截图保存二维码 → ② 打开微信『扫一扫』→ ③ 点右上角相册，选择刚保存的截图 → ④ 在微信内完成支付」。
  4. 底部按钮：「我已完成支付」+「复制支付链接」+「关闭」。
  5. 每 2.5 秒轮询 `fetchWechatOrder`，最多 5 分钟；`paid == true` 时：
     - 停止轮询，展示成功态与到账积分；
     - 调用 `account.refreshCredits()` / `refreshCreditLogs()`；
     - 3 秒后自动关闭或用户手动关闭。
  6. 订单关闭/超时展示对应状态。
- 生命周期：`dispose` 时取消 `Timer`，避免泄漏。

#### 2.5 后端小修（如需要）

- 若 `payUrl` 的 `pageBase` 仍为 `https://ser1996.niav.cn`，在 `.env` / 管理端保留该域名（微信网页授权域名必须与此一致）；App 不做域名硬编码。
- 管理端订单列表：线上已有 `GET /api/admin/orders`（`handleAdminListOrders`），但 `admin/index.html` 还没有入口；新增「支付订单」菜单与只读列表（状态筛选、订单号/邮箱搜索）。

**验收**
- `/api/billing/plans` 返回会员档位且 `wechatPay.enabled=true`。
- App 点击档位出现二维码；微信扫码（相册识别）打开支付页并能拉起 JSAPI 支付。
- 测试支付后 2.5 秒内弹窗变为成功、积分到账、流水出现「会员开通」记录。

---

### 阶段 3：自定义 Root Payload

#### 3.1 模型

**文件**：`lib/payloads/loader/loader_payload.dart`
- 新增 `RootEnvVar {key, value, secret, description}` + `toMap/fromMap`。
- `RootPayloadSpec` 增加：
  - `final List<RootEnvVar> envVars;`
  - `bool get isBuiltin;`
  - `Map<String,dynamic> toMap()`
  - `factory RootPayloadSpec.fromMap(...)`
  - `String resolveWorkflow([Map<String,String>? envVars])`：
    - 替换 `{{ENV}}` 为 YAML `env:` 块；
    - 替换 `{{env.KEY}}` 为对应值（secret 用 `${{ secrets.KEY }}`）；
    - 若模板不含 `{{ENV}}`，把生成的 `env:` 块前置到 workflow 顶部（YAML 顶层 env 合法）。
- `RootPayloadRegistry`：
  - `builtin` 保持不变；
  - `static List<RootPayloadSpec> _custom`、`setCustom()`；
  - `all` 改为 `[...builtin, ..._custom]`；
  - `byId()` 在合并列表查找；
  - `isBuiltin(id)`。

#### 3.2 本地服务

**文件**：`lib/services/custom_payload_service.dart`
- 新增 `_roots`、`rootPayloads`、`findRoot`、`upsertRoot`、`removeRoot`、`importRoot`。
- 新 key：`slipe_custom_root_payloads`。
- `_syncRegistries()` 同步 `RootPayloadRegistry.setCustom(_roots)`。
- `totalCount` 纳入 roots。

#### 3.3 编辑器

**文件**：`lib/screens/custom_payload_editor_screen.dart`
- `kind` 增加 `'root'`。
- Root 表单：
  - 名称、描述、图标、构建环境标识（`flutter` / `node` / `custom`）、环境展示名（如 `Flutter (stable)`）。
  - 环境变量列表：`Key`、`Value`、`是否 Secret`、`说明`，支持增删行。
  - Workflow YAML 多行编辑器，默认填充 `GitHubActionsTemplates.flutterBuildWorkflow` 并在 `env:` 位置插入 `{{ENV}}` 占位。
  - 保存校验：`key` 必须匹配 `[A-Z0-9_]+`；workflow 非空。
- System / Block 表单保持现有逻辑。

**文件**：`lib/screens/custom_payload_manager_screen.dart`
- 新增「Root 镜像」分组 + 「新建 Root Payload」按钮。
- 分组内支持编辑、删除、发布到社区。
- 发布对话框支持 kind=`root`，说明「Root 会影响构建环境与 Secrets，审核会更严格」。

#### 3.4 项目生成

**文件**：`lib/services/loader_project_service.dart`
- `createLoaderProject`：
  - 生成 `env` 块：secret 用 `${{ secrets.KEY }}`，非 secret 用 YAML 字面量；
  - 调用 `rootSpec.resolveWorkflow(envMap)` 写 workflow；
  - 写 `.env.example`（secret 留空，非 secret 填值）；
  - `loader.json` 的 `root` 增加 `envVars`；
  - `PAYLOAD.md` 增加「环境变量」表格（secret 值显示 `***`）。
- `loader_build_screen.dart` 读取旧 manifest 时兼容无 `envVars` 的情况。

#### 3.5 社区联动

- `backend/src/routes/community.js`：`KINDS` 增加 `'root'`；`MAX_SPEC_BYTES` 对 root 放宽到 1MB（workflow 文本）。
- `lib/services/community_service.dart`：`CommunityPackage.isRoot`。
- `lib/services/custom_payload_service.dart`：`importRoot`（id 冲突时 `user_root_*`）。
- 社区筛选 chip 增加「Root 镜像」。
- 设计稿编排器 `lib/widgets/payload_graph_editor.dart:413` 自动展示自定义 Root（无需改逻辑，只依赖 Registry 合并）。

**验收**
- 创建自定义 Root（含 2 个 secret、1 个普通变量 + 自定义 workflow）。
- 新建 Loader 项目：`.github/workflows/*.yml` 中出现正确 `env:` 块；`.env.example` 正确；`loader.json` 含 envVars。
- 发布到社区 → 管理端审核 → 另一账号下载导入后可在 Root 列表选择。

---

### 阶段 4：社区后端

#### 4.1 数据层

**文件**：`backend/src/db.js`
- `DEFAULT_DB` 新增：
  - `communityPosts: []`
  - `communityComments: []`
  - `communityReports: []`
  - `communitySettings: { keywords: [...默认词库], covenant: <默认公约 Markdown>, maxPostsPerDay: 20, firstPostReview: true }`
- `loadDb()` / `mergeConfig` 增加对应默认值合并。
- 用户对象新增运行时字段（无需迁移）：`user.community = { approvedPosts: 0, mutedUntil: '', banned: false }`。

#### 4.2 论坛路由

**新增**：`backend/src/routes/forum.js`

| 方法 | 路径 | 鉴权 | 说明 |
|---|---|---|---|
| GET | `/api/community/feed` | 可选 | `?tab=latest\|hot&q=&page=&pageSize=`，仅 `published` |
| POST | `/api/community/posts` | 登录 | `{title, content, tags?, payloadId?}` |
| GET | `/api/community/posts/:id` | 可选 | 详情（pending 仅作者可见） |
| DELETE | `/api/community/posts/:id` | 登录 | 作者本人或管理员 |
| POST | `/api/community/posts/:id/like` | 登录 | 点赞/取消 |
| GET | `/api/community/posts/:id/comments` | 可选 | 评论列表（published） |
| POST | `/api/community/posts/:id/comments` | 登录 | `{content}` |
| DELETE | `/api/community/comments/:id` | 登录 | 作者本人或管理员 |
| POST | `/api/community/posts/:id/report` | 登录 | `{reason}` |
| GET | `/api/community/mine` | 登录 | 我的帖子（含 pending/rejected） |
| GET | `/api/community/covenant` | 公开 | 公约 Markdown + 更新时间 |
| GET | `/api/community/settings` | 公开 | 仅返回关键词数量/首帖审核开关，不返回词库 |

审核与限制：
- `normalize(text)`：小写、去空白、去常见标点。
- 命中关键词 → `400 {error: "内容包含违规关键词：xxx"}`，并记录 `stats`。
- `user.community.banned` → 403；`mutedUntil` 未到期 → 403。
- 频率：同一用户两次发帖 ≥60 秒；每日 ≤20 帖。
- 长度：标题 ≤80，正文 ≤20000，评论 ≤1000。
- 首帖审核：`approvedPosts === 0` → `status = pending`，响应提示「首帖已提交审核」。
- 点赞用 `post.likedBy: string[]`（单实例 JSON 足够）。
- 所有 Markdown 原样存储，客户端渲染；后端拒绝 `<script`、`<iframe` 等危险标签。

#### 4.3 教程路由

**新增**：`backend/src/routes/tutorials.js`

- 课程内容目录：`backend/content/tutorials/`
  - `manifest.json`：课程轨道与课程列表（id/title/summary/track/order/durationMin/tags/assets）。
  - `lessons/<id>.json`：完整步骤（text/code/quiz/action）。
- 资源目录：`data/tutorials/<lessonId>/...`（zip/图片/视频）。
- 接口：
  - `GET /api/tutorials` → manifest（缓存 5 分钟）
  - `GET /api/tutorials/:id` → 单课详情
  - `GET /api/tutorial-assets/*` → 静态资源（带 `Cache-Control: public, max-age=86400`，禁止 `..`）
- 服务端启动时校验 manifest JSON 合法性；缺失时返回空列表而不是崩溃。

#### 4.4 路由注册

**文件**：`backend/src/server.js`
- 注册论坛、教程、静态资源路由。
- 管理端：
  - `GET /api/admin/community/posts?status=`
  - `POST /api/admin/community/posts/:id/review` `{action: approve|reject, note}`
  - `DELETE /api/admin/community/posts/:id`
  - `GET/PUT /api/admin/community/settings`（关键词、公约、开关）
  - `GET /api/admin/community/reports`

#### 4.5 管理端 UI

**文件**：`backend/admin/index.html` / `backend/admin/app.js`
- 新增菜单：
  - 「社区审核」扩展为两个 Tab：`Payload 包` / `帖子与评论`
  - 「社区设置」：关键词编辑（每行一个）、公约 Markdown 编辑、首帖审核开关
  - 「支付订单」（若线上缺失）
- 复用现有 Element Plus 表格与审核弹窗风格。

**验收（本地临时 DATA_DIR）**
- 注册测试用户 → 首帖 → 状态 pending → 管理端通过 → 列表可见。
- 含关键词的帖子被拒绝；第二帖自动发布。
- 举报、删除、禁言、公约读取均正常。

---

### 阶段 5：社区 App（TDesign + 右划）

#### 5.1 依赖与主题

`pubspec.yaml` 增加 `tdesign_flutter: ^1.1.0`。

**新增**：`lib/community/community_theme.dart`
- `TTheme(data: TThemeData(...), child: ...)`，品牌色沿用 `Color(0xFF0175C2)`，深色模式跟随 `Theme.of(context).brightness`。
- 统一页面背景、卡片圆角、间距。

> 若 `tdesign_flutter 1.1.0` 的某个组件 API 与预期不符，使用同文件内的 Material 包一层并保持 TDesign 视觉规格（间距/圆角/字号/色板），不阻塞功能。

#### 5.2 首页右划入口

**文件**：`lib/screens/home_screen.dart`
- 用 `GestureDetector` 包裹 `Scaffold.body`：
  - `onHorizontalDragEnd`：`primaryVelocity > 300` 时 `_openCommunity()`。
  - 避免与列表纵向滚动冲突（只处理水平速度）。
- `_openCommunity()` 使用 `PageRouteBuilder` 从右侧滑入，时长 260ms，`Curves.easeOutCubic`。
- 右上角原「Payload 社区」图标改为「社区」入口（保留 tooltip），并新增首次进入的轻提示「右划可随时进入社区」（SharedPreferences 只提示一次）。

#### 5.3 社区页面结构

**重写**：`lib/screens/community_screen.dart` → 社区壳（TDesign）

- `TDNavBar`：标题「SLIPE 社区」；右侧「社区公约」「发帖」。
- `TDTabBar` + `TabBarView`：
  1. **推荐**：帖子流（最新/热门切换）、置顶公告、教程入口卡片。
  2. **教程**：两条轨道（APP 基本操作 / Flutter 基础），进度展示。
  3. **Payload**：复用现有社区包列表 + 发布入口（从旧 `community_screen.dart` 抽出）。
  4. **我的**：我的帖子（含审核状态）、我的发布、我的 Payload、社区公约、关键词规则说明。

**新增页面/组件**（`lib/community/`）：
- `feed_tab.dart`：帖子卡片、下拉刷新、分页、空态。
- `post_detail_screen.dart`：Markdown 正文、点赞、评论列表、评论输入。
- `create_post_sheet.dart`：标题/正文/标签；提交前提示「首次发帖需审核」「禁止内容见社区公约」；服务端关键词错误原样展示。
- `covenant_screen.dart`：拉取 `/api/community/covenant`，Markdown 渲染。
- `payload_tab.dart`：迁移现有 Payload 包逻辑（列表/筛选/下载/发布/我的发布）。
- `my_tab.dart`：个人帖子与发布记录。
- `tutorial_list_screen.dart`：轨道与课程卡片、进度、资源大小。
- `tutorial_lesson_screen.dart`：
  - 步骤式导航（上一步/下一步/完成）；
  - `text` Markdown、`code` 代码块（复用现有高亮/复制）、`quiz` 单选 + 解析、`action` 动手任务；
  - 「下载课程资源」按钮：显示进度、解压到应用文档目录 `tutorials/<id>/`；
  - 进度保存到 SharedPreferences `slipe_tutorial_progress`。

**服务层**：`lib/services/community_service.dart`
- 增加帖子/评论/公约/教程模型与 API。
- 新增 `lib/services/tutorial_service.dart`：
  - manifest/lesson 拉取 + 本地缓存（JSON 文件）；
  - 资源下载（`http` 流式 + `archive` 解压，复用项目已有依赖）；
  - 离线可用：已下载课程直接读本地。

#### 5.4 内容审核状态展示

- 我的帖子：`pending`（待审核）/`published`/`rejected`（附审核备注）/`hidden`。
- 首帖提交成功后跳转「我的」并高亮状态。

**验收**
- 主界面右划 → 社区从右滑入；返回手势正常。
- 四个 Tab 均可加载；Payload 功能与旧版一致。
- 发帖（含关键词/首帖）行为符合后端规则。
- 教程课程可离线打开、资源按需下载并解压成功。

---

### 阶段 6：教程内容与资源

**目录**：`backend/content/tutorials/`

- `manifest.json`：两条轨道。
- `lessons/*.json`：
  - APP 基本操作 6 课：主界面与项目、编辑器与标签、AI 助手、云端构建、Git 同步、偏好与账号。
  - Flutter 基础 21 课（与用户图片逐条一致）：
    1. 第一个 Flutter 应用
    2. Flutter 项目结构
    3. Flutter Widget 基础
    4. Flutter StatelessWidget
    5. Flutter 布局基础
    6. Flutter Container
    7. Flutter ListView
    8. Flutter 用户输入
    9. Flutter 状态管理
    10. Flutter HTTP 请求
    11. Flutter 导航与路由
    12. Flutter 表单与验证
    13. Flutter 主题与样式
    14. Flutter 动画基础
    15. Flutter 本地存储
    16. Flutter 图片与资源
    17. Flutter DevTools
    18. Flutter 平台特定代码
    19. Flutter 测试
    20. Flutter 打包与发布
    21. Flutter 最佳实践
- 每课 3-6 个步骤，含 1 个测验；语言为中文；代码为可运行的最小示例。
- 资源包（按需下载，示例）：
  - `app-basics/starter.zip`
  - `flutter-basics/widget-demo.zip`
  - `flutter-basics/state-demo.zip`
  - `flutter-basics/http-demo.zip`
  - 其余课程可无资源包（`assets: []`）。
- 部署时上传到服务器 `content/tutorials/` 与 `data/tutorials/`。

**验收**
- `GET /api/tutorials` 返回 27 课；每课 `GET /api/tutorials/:id` 可解析。
- App 教程 Tab 显示两条轨道；任意课程可打开、完成、记录进度。
- 有资源的课程可下载并解压。

---

### 阶段 7：部署与验收

#### 7.1 后端部署（宝塔）

1. 备份线上 `src/` → `src.bak.<timestamp>`，`admin/` → `admin.bak.<timestamp>`。
2. 上传/写入本地同步后的 `src/**`、`admin/**`、`content/tutorials/**`。
3. 上传教程资源到 `data/tutorials/**`。
4. 修改启动脚本：
   - `GITHUB_DEEP_LINK=slipe://gitoauth2`
   - 保留现有微信支付配置（`db.config.wechatPay` 不动）。
5. 重启宝塔 Node 项目 `slipecode-api`，确认监听 8787。
6. 回滚策略：保留备份目录，异常时恢复 `src`/`admin` 并重启。

#### 7.2 客户端

- `flutter pub get`
- `flutter analyze`
- `flutter test`
- `flutter build apk --release`（签名当前为 debug key，按现有构建流程）

#### 7.3 冒烟检查

```bash
curl -s https://api.lineregre.com/api/health
curl -s https://api.lineregre.com/api/billing/plans
curl -s https://api.lineregre.com/api/tutorials
curl -sI "https://ser1996.niav.cn/pay?order=test"
```

预期：
- `health.ok == true`
- `billing.plans` 为会员档位，`wechatPay.enabled == true`
- `tutorials` 返回 27 课
- `/pay` 返回 HTML（200）

#### 7.4 手工验收清单

- [ ] GitHub：完整授权 → 桥接页 → 打开 App → 登录成功；冷启动再次验证。
- [ ] Gitee：回归验证未受影响。
- [ ] 微信支付：二维码 → 截图 → 微信相册识别 → 支付页 → JSAPI 支付 → App 自动到账。
- [ ] 社区：右划进入；发帖（首帖 pending）；管理端审核；评论/点赞/举报；关键词拦截；公约展示。
- [ ] 教程：列表、课程步骤、测验、进度、资源下载解压。
- [ ] Root Payload：创建 → 生成项目 → workflow/env 正确 → 发布/审核/下载/导入。

---

## 5. 风险与回滚

| 风险 | 缓解 |
|---|---|
| 线上后端源码包含未入库的手工改动 | 阶段 0 全量同步 + MD5 校验；部署前再次备份 |
| `tdesign_flutter` 依赖引入编译问题 | 先 `flutter pub get` + `flutter analyze`；社区页可局部回退 Material 组件 |
| 微信支付域名/授权域名不一致 | 保持 `pageBase` 与微信「网页授权域名」一致；App 不硬编码域名 |
| 自定义 workflow 注入 YAML 语法错误 | 生成前校验缩进；非 secret 值做 YAML 引号转义；创建项目时输出写入日志 |
| 关键词误伤 | 管理端可热更新词库；命中时返回具体词，便于用户修改 |
| 教程内容体积过大 | 课程 JSON 随代码发布；资源独立按需下载，不进入 APK |

---

## 6. 交付文件清单（新增/修改）

**新增**
- `lib/services/oauth_link_bus.dart`
- `lib/widgets/wechat_pay_qr_dialog.dart`
- `lib/services/tutorial_service.dart`
- `lib/community/community_theme.dart`
- `lib/community/feed_tab.dart`
- `lib/community/post_detail_screen.dart`
- `lib/community/create_post_sheet.dart`
- `lib/community/covenant_screen.dart`
- `lib/community/payload_tab.dart`
- `lib/community/my_tab.dart`
- `lib/community/tutorial_list_screen.dart`
- `lib/community/tutorial_lesson_screen.dart`
- `backend/src/routes/forum.js`
- `backend/src/routes/tutorials.js`
- `backend/content/tutorials/manifest.json`
- `backend/content/tutorials/lessons/*.json`
- `backend/data/tutorials/**`（部署侧资源，不入库）

**修改**
- `pubspec.yaml`
- `lib/main.dart`
- `lib/config/app_config.dart`（可选：深链别名）
- `lib/services/github_auth_service.dart`
- `lib/services/gitee_auth_service.dart`
- `android/app/src/main/AndroidManifest.xml`
- `ios/Runner/Info.plist`
- `lib/models/credits.dart`
- `lib/services/account_service.dart`
- `lib/providers/account_provider.dart`
- `lib/widgets/credits_sheet.dart`
- `lib/payloads/loader/loader_payload.dart`
- `lib/services/custom_payload_service.dart`
- `lib/screens/custom_payload_editor_screen.dart`
- `lib/screens/custom_payload_manager_screen.dart`
- `lib/services/loader_project_service.dart`
- `lib/services/community_service.dart`
- `lib/screens/community_screen.dart`
- `lib/screens/home_screen.dart`
- `backend/src/config.js`
- `backend/src/db.js`
- `backend/src/server.js`
- `backend/src/routes/oauth.js`
- `backend/src/routes/community.js`
- `backend/admin/index.html`
- `backend/admin/app.js`
- `backend/README.md`
