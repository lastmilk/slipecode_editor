import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:provider/provider.dart';
import 'providers/build_provider.dart';
import 'providers/container_provider.dart';
import 'providers/editor_provider.dart';
import 'providers/git_sync_provider.dart';
import 'providers/github_provider.dart';
import 'providers/project_provider.dart';
import 'providers/terminal_provider.dart';
import 'screens/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 加载 .env（GitHub OAuth Client ID 等；PKCE 模式下不含任何 secret）
  await dotenv.load(fileName: '.env', isOptional: true);

  final githubProvider = GitHubProvider();
  await githubProvider.init();

  runApp(SlipCodeApp(githubProvider: githubProvider));
}

class SlipCodeApp extends StatelessWidget {
  const SlipCodeApp({super.key, required this.githubProvider});

  final GitHubProvider githubProvider;

  @override
  Widget build(BuildContext context) {
    // 注册全局 Provider
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ProjectProvider()),
        ChangeNotifierProvider(create: (_) => EditorProvider()),
        ChangeNotifierProvider(create: (_) => ContainerProvider()),
        ChangeNotifierProvider(create: (_) => TerminalProvider()),
        ChangeNotifierProvider.value(value: githubProvider),
        // 代码自动同步依赖 GitHub 登录态与当前项目
        ChangeNotifierProxyProvider2<GitHubProvider, ProjectProvider,
            GitSyncProvider>(
          create: (context) => GitSyncProvider(
            context.read<GitHubProvider>(),
            context.read<ProjectProvider>(),
          ),
          update: (context, github, project, previous) =>
              previous ?? GitSyncProvider(github, project),
        ),
        // 云端构建依赖 GitHub 与同步状态
        ChangeNotifierProxyProvider2<GitHubProvider, GitSyncProvider,
            BuildProvider>(
          create: (context) => BuildProvider(
            context.read<GitHubProvider>(),
            context.read<GitSyncProvider>(),
          ),
          update: (context, github, gitSync, previous) =>
              previous ?? BuildProvider(github, gitSync),
        ),
      ],
      child: MaterialApp(
        title: 'SlipCode — Flutter Editor',
        debugShowCheckedModeBanner: false,
        themeMode: ThemeMode.system,
        theme: _buildLightTheme(),
        darkTheme: _buildDarkTheme(),
        home: const HomeScreen(),
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
