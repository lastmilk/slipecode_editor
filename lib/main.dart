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
import 'widgets/app_background.dart';
import 'widgets/app_lock_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 加载 .env（各平台 OAuth Client ID、账号后端地址；不含任何 secret）
  await dotenv.load(fileName: '.env', isOptional: true);

  // 偏好设置先加载，决定首帧主题
  final settingsProvider = SettingsProvider();
  await settingsProvider.load();

  // Git 平台与账号的登录态恢复放后台执行：
  // 未配置后端/凭据或网络不可达时降级为未登录，绝不阻塞首屏
  final githubProvider = GitHubProvider();
  final giteeProvider = GiteeProvider();

  // 账号体系：登录后可同步偏好设置 / 项目列表 / 头像 / 壁纸
  final accountProvider = AccountProvider(settingsProvider);
  accountProvider.attachSyncProviders(
    github: githubProvider,
    gitee: giteeProvider,
  );
  settingsProvider.attachRemoteSync(
    accountProvider.pushSettingsIfLoggedIn,
  );

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
  );
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
    SlipCodeApp(
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
  unawaited(_initAuthInBackground(githubProvider, giteeProvider, accountProvider));
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

class SlipCodeApp extends StatelessWidget {
  const SlipCodeApp({
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
            home: const AppLockGate(child: HomeScreen()),
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
