# SLIPE：LLM 列表 + 账号安全 + 保存/持久化 + AI 体验 实施计划

> 目标版本：在现有 SLIPE（Flutter 客户端 + `backend/` 零依赖 Node 服务）上完成 11 项增强。
> 本计划所有路径与行号均基于当前代码的实地调研。

---

## 1. 摘要

| # | 需求 | 交付要点 |
|---|---|---|
| 1 | LLM 列表 | 多模型配置（Provider Profile）+ 8 个预置服务商 + 可选云同步（默认不含 Key） |
| 2.1 | 极验验证 | Android 原生 GT4 AAR（来自 `gt4-android-sec.zip`）+ MethodChannel + 后端 `/validate` |
| 2.2 | 阿里云短信 | 后端直连 DyPnsApi `SendSmsVerifyCode`/`CheckSmsVerifyCode`（V3 签名，零依赖）；注册必填手机号+验证码 |
| 3 | 保存体系 | 退出/返回/切后台统一落盘；未保存弹窗（保存并退出/不保存/取消）；修复自动保存存错文件 |
| 4 | 上次编辑 | `Project.lastEditedAt` + 首页「上次编辑」卡片 |
| 5 | GitHub 409 | 建仓改 `auto_init: true` + ref 冲突容错重试 + 补齐超时 |
| 6 | 项目持久化 | 云端项目列表（路径 + 仓库映射）+ 登录后按网络策略自动恢复 |
| 7 | 头像/壁纸 | 账号头像双向绑定；壁纸云同步（≤5MB、非 GIF/MP4）；上传前自由裁剪；MP4 动态壁纸 |
| 8 | VibeCoding | 回车触发；生成期间编辑区锁定；思考过程实时展示在 Agent 面板 |
| 9 | 删除提示 | 移除 AI 面板顶部快捷 chips |
| 10 | AI 助手 | SSE 流式输出 + Markdown 渲染 + 可选云端对话记录 |
| 11 | 偏好设置 | 6 个 Tab + 顶部搜索 |

---

## 2. 现状分析（关键事实）

**LLM 配置**
- 单配置三字段：`lib/models/app_settings.dart:29-35`（`llmApiBase/llmApiKey/llmModel`），默认 `gpt-4o-mini`（:96-98）。
- 存储：SharedPreferences 单 key `slipe_app_settings`，整份 JSON（`lib/providers/settings_provider.dart:15,197-200`）。
- 云同步：`main.dart:35-38` 绑定 `AccountProvider.pushSettingsIfLoggedIn`（`account_provider.dart:136-150`，1.5s 防抖 PUT `/api/settings`），**当前连 `llmApiKey` 一起上传**，与设置页“仅存本地”文案矛盾（`settings_screen.dart:321-324`）。
- 后端已有 `GET /api/llm/models`、`POST /api/llm/chat`（`backend/src/server.js:593-686,821-822`），客户端未使用。

**AI 面板**
- `ai_chat_screen.dart`：标题栏 90-130 / 未配置提示 133-155 / **快捷 chips 158-192** / 消息列表 195-230 / 工具调用 chips 233-278 / 输入行 299-349。
- 消息渲染仅 `Text(message.content)`（:417-426），**无 Markdown、无流式**。
- `AgentService.run(maxSteps: 6)`（`agent_service.dart:57-147`）非流式；`AiProvider` 仅内存消息（`ai_provider.dart:38`）。

**VibeCoding**
- `code_editor.dart`：`_detectVibeRequest`(137-161) 行首 `..`/`。。`；`_scheduleVibeCoding`(163-178) 700ms 防抖；`_runVibeCoding`(190-283) 非流式、`readOnly` 未启用、生成期间编辑器可继续输入。

**保存**
- `editor_provider.dart`：`saveFile`(149-168) 保存后 `remove + add` 会打乱标签顺序；`closeFile`(43-60) 无保存/提示；`saveAll`(171-178) 未被 UI 调用。
- `editor_screen.dart`：`_scheduleAutoSave`(121-132) 1s 防抖但只保存**当时的 activeFile**；`dispose`(70-80) 只 cancel timer，不落盘；全库无 `PopScope/WillPopScope`、无生命周期保存。
- `editor_tabs.dart:35` 关闭标签直接 `closeFile`。

**上次编辑 / 持久化**
- `ProjectHistoryService`（`lib/services/project_history_service.dart`）：key `slipe_project_history`，最多 30 条，仅 `{name,path,createdAt}`；`ProjectProvider.refreshFileTree`(:57-59) 写入。
- 仓库映射仅本地 SharedPreferences：`slipe_repo::<path>`（`github_provider.dart:42,117-141`）、`slipe_gitee_repo::`（`gitee_provider.dart:42`），**不上云**。

**GitHub 409**
- `createRepo` 使用 `auto_init: false`（`github_api_service.dart:232-244`）→ 空仓库所有 git 接口都可能返回 409；`pushFiles` 仅在 `GET git/ref` 处容忍 404/409（:296-298），`POST/PATCH refs`（:340-350）未容错；`getRepo`(247-252)、`fileExists`(255-263) 未加超时。
- 服务端注册接口的 409 是本项目唯一已知 409（`server.js:275-277`），与建仓无关。

**账号/后端**
- 前端：`account_service.dart` 仅 `register/login/me/settings`；`AccountUser` 无 `avatarUrl/phone`（:9-33）。
- 后端：`backend/src/server.js` 单文件零依赖；`db={users,settings,llmModels}`(:64)、`saveDb`(:85-92)、`readJson`(:162)、`requireUser`(:193)、`publicUser`(:205)、`throttle`(:235)、`signToken`(:115)；设置上限 16KB/64 字段（:330-336）。**无任何短信/极验/上传能力**。
- `MAX_BODY_BYTES = 1MB`（:29），上传头像/壁纸需按路由放宽。

**壁纸/头像**
- 壁纸字段 `backgroundImagePath/Scope/Opacity`（`app_settings.dart:47-54`）；`app_background.dart:44-63` 仅 `Image.file`（GIF 可动，MP4 不支持，pubspec 无 `video_player`）。
- 头像为本地文件 `AppSettings.avatarPath`（:86-87），选择逻辑 `settings_screen.dart:619-648`，展示 `home_screen.dart:475-539`。

**极验 SDK**
- `gt4-android-sec.zip/SDK/geetest_captcha_android_v1.8.14_20260804.aar`（示例用 `implementation(files(sdkDir...aar))`）；API 为 `GTCaptcha4Client.getClient(ctx).init(captchaId, cfg)` + `addOnSuccessListener { status, response }`，`response` 为 JSON 字符串。
- 现有 Android 壳：`android/app/build.gradle.kts`（minSdk=flutter 默认、Java 17）、`MainActivity.kt` 已注册 MethodChannel（`slipe/container`、`slipe/volume` 等）。

---

## 3. 决策与假设（无需再问，直接执行）

1. **极验仅 Android 原生强制**：iOS/桌面无该 SDK，`CaptchaService.isSupported=false`，请求中不带 `captcha` 且携带 `captchaPlatform:'unsupported'`；后端在未收到 captcha 且声明 unsupported 时放行（记录日志）。这是本次唯一的安全折中。
2. **阿里云凭据留空时走开发模式**：`ALIYUN_ACCESS_KEY_ID/SECRET` 为空 → `/api/auth/sms/send` 返回 `{dev:true, devCode:'123456'}`，注册校验固定码 `123456`；配置凭据后自动切换真实短信。生产部署必须在 `backend/README.md` 标注关闭方式。
3. **云同步默认关闭**：LLM 配置含 Key 的云同步（`llmCloudSync`）与对话记录云同步（`chatCloudSync`）默认 `false`；网络策略默认“仅 Wi-Fi”（`syncNetwork = wifi`）。
4. **壁纸云同步限制**：仅 `png/jpg/jpeg/webp`、≤5MB；GIF/MP4 只存本机；头像 ≤2MB，正方形裁剪 512×512。
5. **MP4 动态壁纸**引入 `video_player`；GIF 用 `Image.file` 原生播放。
6. **Markdown 渲染**引入 `flutter_markdown`（不自研解析器）。
7. **后端“Wi-Fi 下自动同步”由客户端判定网络后调用后端接口**（后端无法感知客户端网络），符合需求原意。
8. **本地历史与云端项目列表合并**：云端路径若在设备上不存在则保留记录并标记 `missing`（首页灰显、点击提示），不删除。
9. **GitHub 409 修复策略**：优先 `auto_init: true` 从根上避免空仓库分支；同时保留 ref 冲突重试，兼容历史仓库。
10. 不新增原生 iOS 代码；iOS 端极验缺失按决策 1 处理。

---

## 4. 新增依赖

`pubspec.yaml` dependencies 追加：

```yaml
flutter_markdown: ^0.7.6   # AI 消息 Markdown 渲染
connectivity_plus: ^6.0.5  # Wi-Fi / 移动网络判定（云同步策略）
video_player: ^2.9.2       # MP4 动态壁纸
```

> 如果 `flutter_markdown` 与当前 SDK（Dart `^3.13.7`）解析冲突，改用 `markdown_widget` 或锁定 `flutter_markdown: 0.7.3+1`；不阻塞其它任务。

---

## 5. 实施阶段

### Phase A — 数据模型与设置基础（先做，后续全部依赖）

**A1. `lib/models/llm_profile.dart`（新建）**

```dart
class LlmProfile {
  final String id;        // 'p_<ts>_<rand>'；内置示例可用固定 id
  final String name;      // 展示名，如 "DeepSeek"
  final String apiBase;   // 不含末尾 /
  final String apiKey;
  final String model;
  final String? presetId; // 来源预置
  bool get isConfigured => apiBase.isNotEmpty && model.isNotEmpty; // 本地模型允许空 key
  LlmProfile copyWith({...});
  Map<String,dynamic> toJson({bool includeKey = true});
  factory LlmProfile.fromJson(Map<String,dynamic>);
}
```

**A2. `lib/services/llm_presets.dart`（新建）** — 预置清单：

| id | 名称 | apiBase | 默认模型 |
|---|---|---|---|
| `openai` | OpenAI | `https://api.openai.com/v1` | `gpt-4o-mini` |
| `deepseek` | DeepSeek | `https://api.deepseek.com/v1` | `deepseek-chat` |
| `dashscope` | 阿里云百炼（通义） | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `qwen-plus` |
| `moonshot` | 月之暗面 Kimi | `https://api.moonshot.cn/v1` | `moonshot-v1-8k` |
| `zhipu` | 智谱 GLM | `https://open.bigmodel.cn/api/paas/v4` | `glm-4-flash` |
| `siliconflow` | 硅基流动 | `https://api.siliconflow.cn/v1` | `deepseek-ai/DeepSeek-V3` |
| `ollama` | 本地 Ollama | `http://127.0.0.1:11434/v1` | `qwen2.5-coder:7b` |
| `slipcloud` | SLIPE 云端 | `<ACCOUNT_BACKEND_BASE_URL>/api/llm`（登录后可用，Key=账号 token） | 云端模型 id（从 `/api/llm/models` 选择） |
| `custom` | 自定义 | 空 | 空 |

`LlmPreset` 含 `models`（候选列表）、`docsUrl`、`requiresLogin`。

**A3. `lib/models/app_settings.dart` 修改**

- 新增字段：`List<LlmProfile> llmProfiles`、`String activeLlmId`、`bool llmCloudSync=false`、`bool chatCloudSync=false`、`String syncNetwork='wifi'`（`wifi|any|never`）、`String wallpaperCloudVersion=''`。
- 保留旧的 `llmApiBase/llmApiKey/llmModel`（只读兼容 + 迁移）；新增 `LlmProfile? get activeLlm`、`bool get isLlmConfigured => activeLlm?.isConfigured ?? false`。
- `copyWith` / `toJson({bool includeSecrets = true})` / `fromJson`：
  - `fromJson`：若 `llmProfiles` 为空且旧三字段已配置，构造 `id:'legacy'` 的 profile，`activeLlmId='legacy'`（迁移）。
  - `toJson(includeSecrets:false)`：profile 的 `apiKey` 输出为空串；**不再输出旧三字段的 key**，仅输出 `llmModel` 供旧版本读取。
- `backgroundImagePath` 等保持原样；新增 `wallpaper` 不参与 16KB 云端上限问题（仅版本号）。

**A4. `lib/providers/settings_provider.dart` 修改**

- 新增：`upsertLlmProfile(LlmProfile)`、`removeLlmProfile(String id)`、`setActiveLlm(String id)`、`setLlmCloudSync(bool)`、`setChatCloudSync(bool)`、`setSyncNetwork(String)`。
- `_save()`：推送云端时调用 `settings.toJson(includeSecrets: settings.llmCloudSync)`；`applyRemote(Map)` 合并时若远端 profile 的 `apiKey` 为空且本地同 id 有 key，则保留本地 key。
- 新增 `Future<void> applyServerAvatarPath(String path)`、`applyServerWallpaperPath(String path, String version)` 供同步服务调用（内部走 setter + `_save()`）。

**A5. `lib/services/network_policy.dart`（新建）**

```dart
class NetworkPolicy {
  static Future<bool> canSyncNow(AppSettings s) async; // never→false; wifi→仅 WiFi; any→有网即可
}
```

### Phase B — LLM 列表 UI（需求 1）

**B1. `lib/screens/settings_screen.dart`**：Phase J 会整体拆 Tab；本阶段先在「AI 助手」区块上方新增 `AI 模型` 区块：
- `ListView`：每个 profile 一行（名称 / model / apiBase 摘要 / 当前激活勾选 / 编辑 / 删除）。
- 「+ 添加模型」→ 底部弹窗：预置服务商 chips（A2）→ 表单（名称、API Base、API Key（本地 Ollama 可空）、模型下拉+自定义）→ 保存。
- 开关：「将模型配置同步到云端（含 API Key）」= `llmCloudSync`。
- 旧的三个 `_editText` 项（`llmApiBase/Key/Model`）删除，改为指向激活 profile 的编辑入口。

**B2. 调用方切换到 `activeLlm`**
- `lib/providers/ai_provider.dart`：`_s.llmApiBase/Key/Model` → `final llm = _s.activeLlm!`（未配置时走原错误提示）。
- `lib/widgets/code_editor.dart` 的 VibeCoding（Phase H 重构后由 `AiProvider` 调用，同样使用 `activeLlm`）。
- `lib/agent/agent_service.dart` 保持不变（由调用方传入 apiBase/key/model）。
- `slipcloud` 预置：Key 使用 `AccountProvider.token`（新增 `String? get token`），apiBase 为 `${AppConfig.accountBackendBase}/api/llm`；模型列表来自 `GET /api/llm/models`（新增 `AccountService.fetchLlmModels()`）。

**B3. 后端**：`/api/settings` 体积上限 16KB→64KB、字段上限 64→128（`server.js:330-336`），容纳多 profile。

### Phase C — 账号安全：极验 + 阿里云短信（需求 2.1 / 2.2）

**C1. Android 极验接入**
1. 复制 `gt4-android-sec.zip` 内 `SDK/geetest_captcha_android_v1.8.14_20260804.aar` → `android/app/libs/geetest_captcha_android.aar`。
2. `android/app/build.gradle.kts` `dependencies` 追加 `implementation(files("libs/geetest_captcha_android.aar"))`；`packaging.jniLibs.useLegacyPackaging` 保持现状。
3. 新建 `android/app/src/main/kotlin/com/slipe/slipe_editor/GeeTestPlugin.kt`：
   - `MethodChannel("slipe/geetest")`，方法 `verify`（`captchaId` 参数）。
   - `GTCaptcha4Client.getClient(activity).init(captchaId, GTCaptcha4Config.Builder().setTimeOut(10000).build())`；
   - `addOnSuccessListener { status, response -> if (status) result.success(jsonToMap(response)) else result.error("CAPTCHA_FAILED", ...) }`、`addOnFailureListener { result.error("CAPTCHA_ERROR", it.message, null) }`；
   - `onDetachedFromActivity` 时 `client.destroy()`（若 SDK 无 `destroy` 则仅置空引用）。
4. `MainActivity.kt` 的 `configureFlutterEngine` 中 `GeeTestPlugin.register(flutterEngine)`。
5. `lib/config/app_config.dart`：新增 `GEETEST_CAPTCHA_ID`（默认 `bad52dace656f61eab4b052c157d00b2`）+ `.env.example` 同步。
6. `lib/services/captcha_service.dart`（新建）：
   ```dart
   class CaptchaResult { final String lotNumber, captchaOutput, passToken, genTime; Map<String,dynamic> toJson(); }
   class CaptchaService {
     static bool get isSupported => !kIsWeb && Platform.isAndroid;
     static Future<CaptchaResult?> verify(); // 取消/失败抛 CaptchaException
   }
   ```

**C2. 后端极验校验**
- `server.js` 顶部读取：`GEETEST_CAPTCHA_ID`（默认给定 ID）、`GEETEST_CAPTCHA_KEY`（默认给定 Key）、`GEETEST_ENFORCE`（默认 `'1'`）。
- 新增 `async function verifyGeetest(captcha)`：
  - `sign_token = HMAC-SHA256(lot_number, GEETEST_CAPTCHA_KEY)`（hex）；
  - `POST https://gcaptcha4.geetest.com/validate?captcha_id=...`，form：`lot_number, captcha_output, pass_token, gen_time, sign_token`；
  - 解析 `{result:'success'}`；异常/超时（5s）返回 false，并记录 `console.warn`。
- `handleRegister` / `handleLogin`：读取 `body.captcha`；若 `GEETEST_ENFORCE==='1'` 且 `body.captchaPlatform!=='unsupported'` 则必须校验，失败返回 400 `{error:'人机验证失败'}`。
- 新增路由（可选，供后端独立预校验）：`POST /api/auth/captcha/validate`。

**C3. 阿里云短信**
- `server.js` 读取：`ALIYUN_ACCESS_KEY_ID`、`ALIYUN_ACCESS_KEY_SECRET`、`ALIYUN_DYPNS_ENDPOINT=dypnsapi.aliyuncs.com`、`ALIYUN_REGION=cn-hangzhou`、`ALIYUN_SMS_SIGN_NAME=恒创联众`、`ALIYUN_SMS_TEMPLATE_CODE=100001`、`ALIYUN_SMS_VALID_MINUTES=5`。
- 新增通用 `async function aliyunRpc(action, params)`：ACS3-HMAC-SHA256 V3 签名（`x-acs-action/x-acs-version=2017-05-25/x-acs-date/x-acs-signature-nonce/x-acs-content-sha256`），`POST https://<endpoint>/?Action=...`，返回 JSON。
- `POST /api/auth/sms/send` body `{phone}`：
  - 校验 `^1[3-9]\d{9}$`；`throttle('sms:'+phone, 60s/1次, 每日5次)`；
  - 有凭据 → `SendSmsVerifyCode`（`PhoneNumber, SignName, TemplateCode, TemplateParam:{"code":"","min":5}, CodeLength:6, ValidTime:300`）；
  - 无凭据 → `{ok:true, dev:true, devCode:'123456'}`。
- 注册时 `handleRegister` 读取 `phone/smsCode`：
  - 手机号必填、唯一（`db.users.some(u=>u.phone===phone)` → 409）；
  - 有凭据 → `CheckSmsVerifyCode`（`PhoneNumber, VerifyCode`）；无凭据 → 比较 `'123456'`；
  - 失败返回 400 `{error:'短信验证码不正确'}`。
- `publicUser` 增加 `phone`、`avatarUrl`；`user` 增加 `avatarUrl`、`wallpaper`（见 Phase G）。

**C4. 前端账号 UI**
- `lib/services/account_service.dart`：
  - `register({email,password,displayName,phone,smsCode,captcha,captchaPlatform})`；
  - `login({email,password,captcha,captchaPlatform})`；
  - `sendSmsCode(String phone) → (bool ok, bool dev, String? devCode)`；
  - `AccountUser` 增加 `phone/avatarUrl`。
- `lib/providers/account_provider.dart`：`register/login` 透传验证参数；`sendSmsCode` 包装；登录成功除 `_pullSettings()` 外追加 `_syncAfterLogin()`（Phase E/G）。
- `lib/screens/account_screen.dart`：注册模式新增「手机号」「短信验证码」两个输入框 + 「获取验证码」按钮（60s 倒计时；dev 模式自动回填 123456 并 SnackBar 提示）；`_submit` 先 `CaptchaService.verify()` 再调后端；未登录页底部说明“注册需短信验证”。

### Phase D — 保存体系 + 上次编辑（需求 3 / 4）

**D1. `lib/providers/editor_provider.dart`**
- `saveFile` 改为**原位替换**（记录 index，`_openFiles[i] = fresh`），不改变标签顺序。
- 新增 `Future<bool> saveContent(String path, String content)`：直接写盘并刷新 `originalContent`（供自动保存使用）。
- `closeFile` 保持不变；新增 `bool isModified(String path)`。
- `saveAll()` 保留。

**D2. `lib/screens/editor_screen.dart`**
- `_scheduleAutoSave` 改为捕获 `path` + `content` 快照：
  ```dart
  final path = editor.activeFile!.path;
  final content = editor.activeFile!.content;
  _autoSaveTimer = Timer(1s, () async {
    final ok = await editor.saveContent(path, content);
    if (ok) gitSync.markChanged(path);
  });
  ```
- `dispose` 中 `_autoSaveTimer?.cancel()` 前执行 `unawaited(saveAllModified())`（fire-and-forget 落盘）。
- `_EditorScreenState` 混入 `WidgetsBindingObserver`：`AppLifecycleState.inactive/paused` → `saveAll()`（无论 autoSave 开关）。
- 用 `PopScope(canPop: false, onPopInvokedWithResult:)` 包住 `Scaffold`：
  1. 有未保存（`editor.hasUnsavedChanges`）→ `showDialog`：`保存并退出 / 不保存 / 取消`；
  2. 保存 → `saveAll()`（失败提示）→ `Navigator.pop`；
  3. 取消 → 不 pop。
- `lib/widgets/editor_tabs.dart`：关闭标签时若 `file.isModified` → 弹 `保存 / 不保存 / 取消`；回调改为向 `EditorScreen` 传 `onRequestClose(path)`（新增参数，默认原行为）。
- `lib/screens/home_screen.dart`：同样注册生命周期 observer，`paused` 时 `saveAll()`。

**D3. 上次编辑**
- `lib/models/project.dart`：新增 `DateTime? lastEditedAt`（`toJson/fromJson` 兼容缺失）。
- `lib/services/project_history_service.dart`：`touch(path,{name})` 写 `lastEditedAt=now`；新增 `Project? get lastEdited`（`list()` 已按 `lastEditedAt ?? createdAt` 倒序）。
- `lib/screens/home_screen.dart`：项目列表上方新增「上次编辑」卡片（`_LastEditedCard`）：项目名 + 相对时间（“刚刚 / x 分钟前 / 昨天 14:20”）+ 「继续编辑」按钮 → `_openProjectPath`；无历史不渲染。
- `lib/screens/editor_screen.dart` AppBar 下（或标题 tooltip）显示 `上次编辑：<相对时间>`。

### Phase E — GitHub 409 + 项目持久化（需求 5 / 6）

**E1. 409 修复（`lib/services/github_api_service.dart`）**
1. `createRepo`：`auto_init: true`（:241）。
2. `pushFiles`：
   - `GET git/ref/heads/<branch>` 容忍 `404/409`（现状保留）；
   - `POST /git/refs` 返回 409/422 → 视为“分支已存在”，重新 `GET` head 后改走 `PATCH`；
   - `PATCH /git/refs/heads/<branch>` 返回 409/422 → 重试整个推送（最多 2 次，间隔 800ms，重新读取 head 作为 parent）；
   - 全部失败抛出带 `HTTP xxx + message` 的既有 `HttpExceptionWithBody`。
3. `getRepo`(:247)、`fileExists`(:255)、`GET git/ref`(:286) 统一补 `.timeout(_timeout)`。
4. `lib/providers/github_provider.dart` `createRepoWithInitialPush`：
   - `client.createRepo` 捕获 422/409 → 用 `uniqueRepoName('${name}_$i')` 重试 1 次；
   - 初始推送使用 `repo.defaultBranch`（当前已如此）；
   - `uniqueRepoName` 的 `getRepo` 捕获非 404 时返回“已存在”而不是直接抛出（仅对 409/422）。
5. `lib/screens/create_project_screen.dart`：建仓失败时日志追加原始错误体（`_outputLines` 已有），并 SnackBar 保留原错误。

**E2. 后端项目持久化（`server.js`）**
- `db` 增加 `projects: {}`（`userId → [{path,name,repoFullName,host,lastEditedAt}]`），`loadDb` 兜底。
- `GET /api/projects` → `{projects: [...]}`；`PUT /api/projects` body `{projects}`：
  - 上限 100 条、序列化 ≤32KB；每条裁剪为 `{path,name,repoFullName,host,lastEditedAt}`。
- 路由表新增两条（`server.js:810-822` 附近）。

**E3. 客户端同步**
- `lib/services/account_service.dart`：`fetchProjects(token)`、`pushProjects(token, list)`。
- `lib/services/project_sync_service.dart`（新建）：`syncProjects()`：
  1. `NetworkPolicy.canSyncNow(settings)` 不通过则跳过；
  2. 本地 `ProjectHistoryService.list()` + `github.repoFor/gitee.repoFor` 组装；
  3. 拉云端 → 合并（本地优先，云端补缺）→ `PUT`；
  4. 回填：不存在的路径标记 `missing`（`Project` 新增 `bool missing`，仅内存/首页灰显）；仓库映射写入 `prefs` + `provider.linkRepo`。
- `lib/providers/account_provider.dart`：`_syncAfterLogin()` 串行调用 `_pullSettings → project_sync → avatar_sync → wallpaper_sync → chat_history`；新增 `Future<void> syncProjectsNow()` 供设置页“立即同步”。
- 触发点：登录成功、App 启动已登录（`main.dart` 后台 `_initAuthInBackground` 完成后）、打开/关闭项目后 5s 防抖（`ProjectProvider` 调用 `ProjectSyncService.schedule()`）。

### Phase F — 头像与壁纸（需求 7）

**F1. 后端**
- `readJson(req, {limit = MAX_BODY_BYTES})` 扩展；上传路由用 8MB。
- `POST /api/me/avatar` body `{base64, mime}`（≤2MB，mime `image/png|jpeg`）：
  - 写 `DATA_DIR/uploads/<userId>/avatar.<ext>`，`user.avatarUrl = /api/avatars/<userId>?v=<ts>`。
- `GET /api/avatars/:userId`（公开）→ 返回图片字节 + `Content-Type`。
- `POST /api/me/wallpaper`（≤5MB，`png|jpeg|webp`）→ `uploads/<userId>/wallpaper.<ext>`，`user.wallpaper = {version, mime, size, updatedAt}`；`GET /api/me/wallpaper` → `{base64, mime, updatedAt}`；`DELETE /api/me/wallpaper`。
- 路由表追加；静态字节输出用 `sendBytes(res, 200, buf, mime)` 新帮助函数。

**F2. 客户端**
- `lib/services/avatar_service.dart`（新建）：`downloadAvatar(AccountUser) → 本地路径`（缓存文件名含 `avatarUrl` 版本哈希，写入 `<documents>/avatars/account_<hash>.jpg`）；`uploadAvatar(File)`。
- `lib/services/wallpaper_sync_service.dart`（新建）：`uploadIfEligible()`（登录 + `canSyncNow` + 非 gif/mp4 + ≤5MB）、`downloadIfNewer()`（比较 `wallpaperCloudVersion`）。
- `lib/services/settings_provider.dart` 新 setter 已在 A4。
- `lib/screens/settings_screen.dart`：
  - 头像项：选择图片 → `ImageCropDialog`（1:1，512×512）→ 保存本地 `setAvatarPath` → 已登录则 `uploadAvatar`；
  - 壁纸项：选择 → `ImageCropDialog`（9:16 / 屏比，最长边 1440）→ 保存本地 → 提示“已上传云端/仅本机（GIF、MP4 或超过 5MB）”。
- `lib/widgets/image_crop_dialog.dart`（新建）：
  - `Future<Uint8List?> showImageCropDialog(context,{path,aspectRatio,outputWidth})`；
  - `InteractiveViewer` + 裁剪框遮罩 + 双指缩放/拖动；确认时 `ui.PictureRecorder` 按裁剪区域绘制到目标尺寸 → `toByteData(png)`。
- `lib/widgets/app_background.dart`：按扩展名分派 —— `.mp4` → `VideoPlayer`（`video_player`，静音、循环、`BoxFit.cover`）；其它 → `Image.file`；文件缺失回退无背景。
- `lib/screens/home_screen.dart` `_HomeAvatar`：`settings.avatarPath`（登录后已同步为账号头像本地副本）→ 无则默认渐变头像；账号页 `_buildProfile` 使用同一头像。
- `lib/screens/account_screen.dart`：已登录头部显示账号头像 + 「更换头像」（裁剪后上传，成功后同步本地）。

### Phase G — VibeCoding 重构（需求 8）

**G1. `lib/widgets/code_editor.dart`**
- 删除 `_vibeTimer/_vibeMessageTimer/_vibeBusy/_vibeMessage/_lastVibeKey`、`_scheduleVibeCoding`、`_runVibeCoding`、`_unwrapCode`、`_buildVibeBar`（及 `LlmService/SettingsProvider` 相关 import）。
- 新增回调：
  ```dart
  final void Function(String requirement, int lineStart, int lineEnd)? onVibeRequest;
  ```
- 触发方式：`_onTextChanged` 中比较 `_lastText`，若新文本在光标处新增了 `\n`，取**上一行**文本，匹配 `^\s*(?:\.\.|。。)(.+)$` → `onVibeRequest(requirement, lineStart, lineEnd)`；`_lastText` 每次更新。
- 保留 `readOnly` 行为（生成期间由父级传入 `true`）。

**G2. `lib/providers/ai_provider.dart`**
- 新增：
  ```dart
  bool get vibeBusy;
  Future<void> runVibeCoding({required String filePath, required String requirement, required int lineStart, required int lineEnd});
  void cancelVibe();
  ```
  流程：
  1. 校验 `activeLlm`；`_vibeBusy=true; _steps.clear(); notify`；
  2. 通过 `EditorProvider` 删除触发行并保存（保证磁盘与缓冲一致）：`editor.replaceRangeAndSave(filePath, lineStart, lineEnd, '')`；
  3. `AgentService.run(history:[user: "在 `$filePath` 的第 N 行附近实现需求：$requirement，直接使用工具修改文件"])`，`onStep` 追加步骤（Agent 面板实时可见），`isCancelled: () => _vibeCancelled`；
  4. 结束后 `editor.reloadFile(filePath)`，`_vibeBusy=false`；失败 `_error` 展示。
- `AgentService.run` 增加 `bool Function()? isCancelled`（循环每步检查，抛 `AgentCancelled`）。

**G3. `lib/screens/editor_screen.dart`**
- `CodeEditor(... onVibeRequest: (req, s, e) => ai.runVibeCoding(filePath: active.path, requirement: req, lineStart: s, lineEnd: e))`。
- 生成期间：`readOnly: ai.vibeBusy` + `AbsorbPointer(absorbing: ai.vibeBusy)`，编辑区顶部覆盖条：“AI 正在编辑 · 可在右侧 Agent 面板查看思考过程” + 「取消」按钮（`ai.cancelVibe()`）。
- 侧边栏（文件/Agent）保持可用；不自动关闭。

### Phase H — AI 助手：流式 + Markdown + 云端记录（需求 9 / 10）

**H1. 删除快捷提示**：`lib/screens/ai_chat_screen.dart` 删除 158-192 的快捷 chips 容器与 `_QuickChip` 类；删除 `_sendWithFile`、`_triggerBuild`（无引用后）与 `sendWithCurrentFile`（`ai_provider.dart:117-129`）。

**H2. 流式（`lib/services/llm_service.dart`）**
- 新增：
  ```dart
  Stream<LlmStreamChunk> streamChatMessage({... , List<Map<String,dynamic>>? tools});
  // LlmStreamChunk: { String? deltaText; Map<String,dynamic>? finalMessage; }
  ```
  实现：`http.Client().send(http.Request('POST', uri)..headers..body)` → `res.stream.transform(utf8.decoder).transform(const LineSplitter())`；逐行解析 `data: {...}`；累积 `choices[0].delta.content` 与 `delta.tool_calls`（按 index 合并 `id/function.name/arguments`）；结束时输出 `finalMessage`（OpenAI assistant 结构）。
- 保留 `chatMessage`（非流式）作为降级路径。

**H3. Agent 流式（`lib/agent/agent_service.dart`）**
- `run` 增加 `void Function(String delta)? onDelta`；每轮改用 `streamChatMessage`，边收边 `onDelta` 并累积 tool_calls；无 tools 的模型仍走带回退（首轮异常 → `chat`）。

**H4. Provider 与 UI**
- `lib/providers/ai_provider.dart`：新增 `bool isStreaming`、`String? streamingText`；`sendMessage` 时插入一条临时 assistant 气泡（渲染 `streamingText`），`onDelta` 拼接并 `notifyListeners()`（节流 80ms）；结束后替换为正式消息并清空 `streamingText`。
- `lib/screens/ai_chat_screen.dart` `_MessageBubble`：改用 `MarkdownBody`（`flutter_markdown`）：
  - `styleSheet`：正文 13/1.5；`code` 背景 `#2D2D30`、等宽、圆角；`pre` 支持横向滚动 + 「复制」按钮（`builders: {'pre': ...}`）；
  - 流式气泡末尾追加闪烁光标；
  - 自动滚动在流式期间保持到底部。

**H5. 对话记录云同步**
- `lib/services/chat_history_service.dart`（新建）：本地 key `slipe_chat_history`，存 `[{role,content,ts}]`，上限 200 条；`load/save/clear`。
- `server.js`：`db.chatHistory[userId]`；`GET /api/chat/history`、`PUT /api/chat/history`（≤256KB、≤200 条）。
- `ai_provider`：初始化时 `load()`；每次完成一轮后 `save()`；`chatCloudSync && canSyncNow` 时 2s 防抖 `pushChatHistory`（`AccountProvider` 提供方法）。
- 登录后 `_syncAfterLogin`：`chatCloudSync` 开启才拉取并合并（按 `ts` 去重，云端优先补缺）。
- 设置页「AI 助手」Tab 增加开关与「清空记录」（同时 `DELETE` 云端）。

### Phase I — 偏好设置 Tab + 搜索（需求 11）

**I1. `lib/screens/settings_screen.dart` 重构**
- 结构：`Scaffold` → `DefaultTabController(length: 6)`：
  - `AppBar(title:'偏好设置', bottom: TabBar(isScrollable:true, tabs: [外观, 编辑器, 项目与 Git, AI 模型, AI 助手, 账号与同步]))`
  - `body: Column[ 搜索框(Padding + TextField), Expanded(TabBarView([...])) ]`
- 迁移映射（现有行号 → Tab）：
  - 外观：主题（40-70）、背景图片/范围/不透明度（73-156）、首页标题/头像（335-366）。
  - 编辑器：字号、自动保存、补全、音量键（现有 “编辑器”“代码补全” 区块）。
  - 项目与 Git：默认平台、建仓开关（“Git 与项目”）、同步网络策略、立即同步项目。
  - AI 模型：Phase B 的 profile 列表。
  - AI 助手：悬浮球、系统悬浮窗、对话记录云同步开关、清空记录。
  - 账号与同步：`_SyncCard`、登录/账号入口、LLM 配置云同步开关。
- 搜索：
  - 定义 `List<_SettingEntry> _entries`，每条 `{tabIndex, title, keywords, Widget Function(BuildContext)}`；
  - 查询非空时，`TabBarView` 替换为结果列表（渲染匹配条目的 widget，按 Tab 分组显示小标题）；
  - 空查询恢复 TabBarView；搜索结果点击条目后清空搜索并 `animateTo(tabIndex)`（条目行本身可操作）。
- 所有设置项保持原有 setter 调用，仅改布局。

### Phase J — 后端部署与文档

- `backend/README.md`：补 `GEETEST_*`、`ALIYUN_*`、上传限制、新接口表。
- `backend/deploy.sh` 与既有部署流程不变；部署包如需重新生成，沿用现有 `backend-deploy.zip` 方式（不自动部署，交付时说明）。
- 根 `.env.example`：新增 `GEETEST_CAPTCHA_ID`。

---

## 6. 后端接口总览（新增/变更）

| Method | Path | 说明 |
|---|---|---|
| POST | `/api/auth/register` | 变更：必填 `phone`、`smsCode`；支持 `captcha` |
| POST | `/api/auth/login` | 变更：支持 `captcha`（强制则必须） |
| POST | `/api/auth/sms/send` | 新增：发送短信验证码（dev 回退 123456） |
| POST | `/api/auth/captcha/validate` | 新增：极验二次校验 |
| GET/PUT | `/api/settings` | 上限 16KB→64KB |
| GET/PUT | `/api/projects` | 新增：云端项目列表 + 仓库映射 |
| GET/PUT/DELETE | `/api/chat/history` | 新增：对话记录云同步 |
| POST | `/api/me/avatar` | 新增：上传账号头像（≤2MB） |
| GET | `/api/avatars/:userId` | 新增：公开头像字节 |
| POST/GET/DELETE | `/api/me/wallpaper` | 新增：壁纸云同步（≤5MB，图片） |
| GET | `/api/me` | 变更：返回 `phone/avatarUrl` |

DB 结构扩展：`users[].phone/avatarUrl/wallpaper`、`db.projects`、`db.chatHistory`。

---

## 7. 涉及文件清单

**新建（Dart/Android）**
- `lib/models/llm_profile.dart`
- `lib/services/llm_presets.dart`
- `lib/services/captcha_service.dart`
- `lib/services/network_policy.dart`
- `lib/services/project_sync_service.dart`
- `lib/services/chat_history_service.dart`
- `lib/services/avatar_service.dart`
- `lib/services/wallpaper_sync_service.dart`
- `lib/widgets/image_crop_dialog.dart`
- `android/app/libs/geetest_captcha_android.aar`（从 zip 复制）
- `android/app/src/main/kotlin/com/slipe/slipe_editor/GeeTestPlugin.kt`

**修改（Dart）**
- `lib/models/app_settings.dart`、`lib/models/project.dart`
- `lib/providers/settings_provider.dart`、`account_provider.dart`、`editor_provider.dart`、`ai_provider.dart`、`project_provider.dart`、`github_provider.dart`
- `lib/services/account_service.dart`、`project_history_service.dart`、`llm_service.dart`、`agent_service.dart`、`github_api_service.dart`
- `lib/screens/settings_screen.dart`、`account_screen.dart`、`home_screen.dart`、`editor_screen.dart`、`ai_chat_screen.dart`、`create_project_screen.dart`
- `lib/widgets/code_editor.dart`、`editor_tabs.dart`、`app_background.dart`
- `lib/config/app_config.dart`、`lib/main.dart`、`pubspec.yaml`、`.env.example`

**修改（Android/后端）**
- `android/app/build.gradle.kts`、`android/app/src/main/kotlin/com/slipe/slipe_editor/MainActivity.kt`
- `backend/src/server.js`、`backend/README.md`

---

## 8. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 极验 AAR 在 Flutter AGP9/Java17 下编译异常 | 先单独 `flutter build apk --debug` 验证；失败则回退 WebView H5 方案（后端提供 load 参数） |
| `flutter_markdown` 与 SDK 版本冲突 | 锁定兼容版本或改用 `markdown_widget` |
| 设置云同步体积（多 profile）超限 | 后端上限调至 64KB；客户端 push 前裁剪（不含 Key） |
| 移动网络上传头像/壁纸耗流 | 严格 `NetworkPolicy` 判定 + 用户可见提示 |
| 云端项目路径跨设备不存在 | 标记 `missing` 灰显，不自动删除 |
| 保存弹窗频繁打断 | 仅在存在 `isModified` 时触发；自动保存仍优先 |
| 后端 1MB 请求体 | 上传路由单独 `readJson(limit)`，其余保持 1MB |

---

## 9. 验证步骤

1. `flutter analyze` → **No issues found**。
2. `node --check backend/src/server.js`；本地 `node backend/src/server.js` 起服务，curl 验证：
   - `/api/auth/sms/send`（无凭据 dev 返回 123456）；
   - `/api/projects` PUT/GET；
   - `/api/me/wallpaper` 上传下载；
   - 注册缺 `smsCode` → 400。
3. `flutter build apk --debug`（或 CI release）通过；Android 上真机验证极验弹层能返回 4 个字段。
4. 手测清单：
   - LLM：新增 DeepSeek + 本地 Ollama 两个 profile，切换后 AI 助手与 VibeCoding 均使用正确模型；关闭云同步时重新登录另一设备不出现 Key。
   - 注册：手机号 + 短信码 + 极验全流程；错误码提示正确。
   - 保存：改 3 个文件后 1s 内返回 → 弹窗；选“保存并退出”后文件已落盘；切后台自动保存。
   - 上次编辑：首页卡片显示最近项目与相对时间。
   - GitHub：新账号建仓 + 初始推送成功（无 409）；同名仓库自动 `_1`。
   - 项目持久化：卸载重装 → 登录 → 项目列表与仓库映射恢复（Wi-Fi 前提下）。
   - 头像/壁纸：裁剪上传后另一台设备登录可见；GIF/MP4 仅本机；>5MB 提示不同步。
   - VibeCoding：行首 `..调用 sdk` 回车 → 编辑区锁定、Agent 面板实时步骤、完成后文件已更新、可取消。
   - AI 助手：流式逐字、Markdown 代码块可复制、顶部无快捷 chips；开启云同步后换设备可见历史。
   - 设置：6 个 Tab 正常，搜索“字号/壁纸/模型/同步”均能定位到对应行。
