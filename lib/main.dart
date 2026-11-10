import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:provider/provider.dart';

import 'l10n/app_localizations.dart';
import 'providers/account_provider.dart';
import 'providers/ai_provider.dart';
import 'providers/build_provider.dart';
import 'providers/container_provider.dart';
import 'providers/editor_provider.dart';
import 'providers/git_sync_provider.dart';
import 'providers/gitee_provider.dart';
import 'providers/github_provider.dart';
import 'providers/project_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/terminal_provider.dart';
import 'screens/home_screen.dart';
import 'services/app_globals.dart';
import 'services/ai_extensions_service.dart';
import 'services/custom_payload_service.dart';
import 'services/github_hosts_service.dart';
import 'services/oauth_link_bus.dart';
import 'services/overlay_service.dart';
import 'services/project_history_service.dart';
import 'widgets/ai_quick_chat.dart';
import 'widgets/app_background.dart';
import 'widgets/app_lock_gate.dart';
import 'widgets/policy_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 加载 .env（各平台 OAuth Client ID、账号后端地址；不含任何 secret）
  await dotenv.load(fileName: '.env', isOptional: true);

  // OAuth 深链总线：必须在任何授权流程之前初始化，
  // 否则冷启动时由深链拉起 App 的 initial link 会丢失
  await OAuthLinkBus.instance.init();

  // 偏好设置先加载，决定首帧主题
  final settingsProvider = SettingsProvider();
  await settingsProvider.load();

  // 第三方 MCP / 外源 Skill 的本地配置（仅本机保存）
  await AiExtensionsService.instance.ensureLoaded();

  // GitHub 专用 Hosts：先读本地缓存，过期时后台从服务端更新
  // （仅作用于应用内 HTTP 请求，不涉及 VPN / 代理 / 系统 hosts）
  unawaited(
    GithubHostsService.instance.ensureLoaded(
      enabled: settingsProvider.settings.githubHostsEnabled,
    ),
  );

  // 用户自定义 Payload：启动时注入 System / Block 注册表，
  // 保证设计稿编排器与 Loader 构建能立即看到自定义条目
  await CustomPayloadService.instance.init();

  // Git 平台与账号的登录态恢复放后台执行：
  // 未配置后端/凭据或网络不可达时降级为未登录，绝不阻塞首屏
  final githubProvider = GitHubProvider();
  final giteeProvider = GiteeProvider();

  // 账号体系：登录后可同步偏好设置 / 头像 / 壁纸
  final accountProvider = AccountProvider(settingsProvider);
  settingsProvider.attachRemoteSync(accountProvider.pushSettingsIfLoggedIn);

  // 其余 Provider 依赖上面三者，直接实例化后注入
  final projectProvider = ProjectProvider();
  final editorProvider = EditorProvider();
  final containerProvider = ContainerProvider();
  final terminalProvider = TerminalProvider();
  final gitSyncProvider = GitSyncProvider(
    githubProvider,
    giteeProvider,
    projectProvider,
  );
  final buildProvider = BuildProvider(
    githubProvider,
    giteeProvider,
    gitSyncProvider,
    projectProvider,
    accountProvider,
    settingsProvider,
  );

  // 项目隔离：切换项目时重置编辑器工作区（按项目恢复标签页）与构建状态
  projectProvider.onProjectChanged = (path) async {
    await editorProvider.switchProject(path);
    buildProvider.resetForProject();
  };
  // AI 助手（Agent 面板依赖它；未注册会导致侧边栏 Agent 页空白）
  final aiProvider = AiProvider(
    settingsProvider,
    editorProvider,
    buildProvider,
    projectProvider,
    accountProvider,
    terminal: terminalProvider,
  );

  runApp(
    SLIPEApp(
      settingsProvider: settingsProvider,
      accountProvider: accountProvider,
      githubProvider: githubProvider,
      giteeProvider: giteeProvider,
      projectProvider: projectProvider,
      editorProvider: editorProvider,
      containerProvider: containerProvider,
      terminalProvider: terminalProvider,
      gitSyncProvider: gitSyncProvider,
      buildProvider: buildProvider,
      aiProvider: aiProvider,
    ),
  );

  // 首帧渲染后再恢复登录态；任一初始化失败只影响对应入口
  unawaited(
    _initAuthInBackground(githubProvider, giteeProvider, accountProvider),
  );

  // 系统悬浮球：点击后直接弹出轻量 AI 对话窗（不进入主界面）
  unawaited(
    OverlayService.instance.init(
      onOpenAiChat: (request) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          AiQuickChatSheet.showFromGlobal(
            prompt: request.prompt,
            projectPath: request.projectPath,
          );
        });
      },
    ),
  );

  // 把项目列表同步给系统悬浮球面板（项目选择用）
  unawaited(ProjectHistoryService.instance.publishOverlayProjects());
}

/// 后台恢复各平台登录态，带超时与异常兜底（降级为未登录）
Future<void> _initAuthInBackground(
  GitHubProvider github,
  GiteeProvider gitee,
  AccountProvider account,
) async {
  Future<void> guard(String name, Future<void> Function() init) async {
    try {
      await init().timeout(const Duration(seconds: 15));
    } catch (e) {
      debugPrint('$name 登录态恢复失败（已降级为未登录）：$e');
    }
  }

  await Future.wait([
    guard('GitHub', github.init),
    guard('Gitee', gitee.init),
    guard('账号', account.init),
  ]);
}

class SLIPEApp extends StatelessWidget {
  const SLIPEApp({
    super.key,
    required this.settingsProvider,
    required this.accountProvider,
    required this.githubProvider,
    required this.giteeProvider,
    required this.projectProvider,
    required this.editorProvider,
    required this.containerProvider,
    required this.terminalProvider,
    required this.gitSyncProvider,
    required this.buildProvider,
    required this.aiProvider,
  });

  final SettingsProvider settingsProvider;
  final AccountProvider accountProvider;
  final GitHubProvider githubProvider;
  final GiteeProvider giteeProvider;
  final ProjectProvider projectProvider;
  final EditorProvider editorProvider;
  final ContainerProvider containerProvider;
  final TerminalProvider terminalProvider;
  final GitSyncProvider gitSyncProvider;
  final BuildProvider buildProvider;
  final AiProvider aiProvider;

  @override
  Widget build(BuildContext context) {
    // 注册全局 Provider
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settingsProvider),
        ChangeNotifierProvider.value(value: accountProvider),
        ChangeNotifierProvider.value(value: projectProvider),
        ChangeNotifierProvider.value(value: editorProvider),
        ChangeNotifierProvider.value(value: containerProvider),
        ChangeNotifierProvider.value(value: terminalProvider),
        ChangeNotifierProvider.value(value: githubProvider),
        ChangeNotifierProvider.value(value: giteeProvider),
        ChangeNotifierProvider.value(value: gitSyncProvider),
        ChangeNotifierProvider.value(value: buildProvider),
        ChangeNotifierProvider.value(value: aiProvider),
      ],
      child: Consumer<SettingsProvider>(
        builder: (context, settings, _) {
          final s = settings.settings;
          return MaterialApp(
            title: t('app.title'),
            debugShowCheckedModeBanner: false,
            themeMode: s.themeMode,
            theme: _buildLightTheme(s.fontFamily),
            darkTheme: _buildDarkTheme(s.fontFamily),
            locale: L10n.locale,
            supportedLocales: const [
              Locale('zh'),
              Locale('zh', 'Hant'),
              Locale('en'),
            ],
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            navigatorKey: appNavigatorKey,
            // 动态壁纸感知路由切换：被页面遮挡时暂停，返回时恢复
            navigatorObservers: [AppBackground.routeObserver],
            // 政策门禁：未同意《用户协议》与《隐私政策》时弹窗确认，
            // 不同意则进入受限模式（应用锁之上、主页之下）
            home: AppLockGate(
              child: PolicyGate(child: HomeScreen()),
            ),
          );
        },
      ),
    );
  }

  ThemeData _buildLightTheme(String fontFamily) {
    return ThemeData(
      useMaterial3: true,
      fontFamily: fontFamily.isEmpty ? null : fontFamily,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF0175C2), // Flutter 蓝
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: const Color(0xFFF5F7FA),
    );
  }

  ThemeData _buildDarkTheme(String fontFamily) {
    return ThemeData(
      useMaterial3: true,
      fontFamily: fontFamily.isEmpty ? null : fontFamily,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF0175C2),
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xFF1E1E1E),
    );
  }
}
