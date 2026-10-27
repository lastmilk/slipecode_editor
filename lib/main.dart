import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:provider/provider.dart';

import 'providers/account_provider.dart';
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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 加载 .env（各平台 OAuth Client ID、账号后端地址；不含任何 secret）
  await dotenv.load(fileName: '.env', isOptional: true);

  // 偏好设置先加载，决定首帧主题
  final settingsProvider = SettingsProvider();
  await settingsProvider.load();

  // Git 平台登录态
  final githubProvider = GitHubProvider();
  await githubProvider.init();
  final giteeProvider = GiteeProvider();
  await giteeProvider.init();

  // 账号体系：登录后可同步偏好设置
  final accountProvider = AccountProvider(settingsProvider);
  settingsProvider.attachRemoteSync(
    accountProvider.pushSettingsIfLoggedIn,
  );
  await accountProvider.init();

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
    ),
  );
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
      ],
      child: Consumer<SettingsProvider>(
        builder: (context, settings, _) {
          return MaterialApp(
            title: 'SlipCode — Flutter Editor',
            debugShowCheckedModeBanner: false,
            themeMode: settings.settings.themeMode,
            theme: _buildLightTheme(),
            darkTheme: _buildDarkTheme(),
            home: const HomeScreen(),
          );
        },
      ),
    );
  }

  ThemeData _buildLightTheme() {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF0175C2), // Flutter 蓝
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: const Color(0xFFF5F7FA),
    );
  }

  ThemeData _buildDarkTheme() {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF0175C2),
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xFF1E1E1E),
    );
  }
}
