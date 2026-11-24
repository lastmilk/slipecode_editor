import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:window_manager/legacy.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:path/path.dart' as p;
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
import 'providers/local_build_provider.dart';
import 'providers/lsp_provider.dart';
import 'providers/project_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/terminal_provider.dart';
import 'providers/toolchain_provider.dart';
import 'screens/desktop/crash_report_screen.dart';
import 'screens/editor_screen.dart';
import 'screens/main_shell.dart';
import 'services/app_globals.dart';
import 'services/app_info.dart';
import 'services/ai_connector_service.dart';
import 'services/ai_extensions_service.dart';
import 'services/crash_log_service.dart';
import 'services/custom_payload_service.dart';
import 'services/desktop_platform.dart';
import 'services/desktop_prefs_service.dart';
import 'services/editor_process_service.dart';
import 'services/git_host_ai_connectors.dart';
import 'services/github_hosts_service.dart';
import 'services/hub_bridge_service.dart';
import 'services/knowledge_service.dart';
import 'services/launch_args.dart';
import 'services/lsp/lsp_manager.dart';
import 'services/lua/lua_runtime_service.dart';
import 'services/memory_guard_service.dart';
import 'services/oauth_link_bus.dart';
import 'services/overlay_service.dart';
import 'services/plugin_service.dart';
import 'services/project_history_service.dart';
import 'widgets/ai_quick_chat.dart';
import 'widgets/app_background.dart';
import 'widgets/app_lock_gate.dart';
import 'widgets/desktop/desktop_window_host.dart';
import 'widgets/policy_gate.dart';
import 'widgets/plugin_install_link_handler.dart';

Future<void> main(List<String> arguments) async {
  LaunchArgs.parse(arguments);

  // 进程级日志：Hub 与 Editor 各自独立落盘（崩溃时用于导出与自动分析）
  await CrashLogService.instance.init(
    role: LaunchArgs.isEditor ? 'editor' : 'hub',
    extra: {if (LaunchArgs.isEditor) '项目': LaunchArgs.projectPath},
  );

  WidgetsFlutterBinding.ensureInitialized();
  _installErrorHandlers();
  await _bootstrap();
}

void _installErrorHandlers() {
  FlutterError.onError = (details) {
    // 框架层错误（布局断言、构建异常等）记录为 ERROR，不直接结束进程
    CrashLogService.instance.write(
      'ERROR',
      '${details.exceptionAsString()}\n${details.stack ?? ''}',
    );
    FlutterError.presentError(details);
  };
  if (LaunchArgs.isEditor) {
    // 异步未捕获异常：写日志后以非 0 退出码结束，交给 Hub 弹出异常窗口
    WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
      CrashLogService.instance.fatal(error, stack, source: 'platform');
      // 让日志先落盘，再结束进程
      Timer.run(() => exit(1));
      return true;
    };
  }
}

Future<void> _bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 加载 .env（各平台 OAuth Client ID、账号后端地址；不含任何 secret）
  await dotenv.load(fileName: '.env', isOptional: true);

  // OAuth 深链总线：必须在任何授权流程之前初始化，
  // 否则冷启动时由深链拉起 App 的 initial link 会丢失
  await OAuthLinkBus.instance.init();

  // 偏好设置先加载，决定首帧主题
  final settingsProvider = SettingsProvider();
  await settingsProvider.load();

  // 私人知识库：首屏前加载本地缓存，登录后由文档页触发云端同步
  // 编辑器进程只在 AI 面板使用前需要，交给分阶段加载后台完成，避免阻塞窗口出现
  if (LaunchArgs.isEditor) {
    unawaited(KnowledgeService.instance.ensureLoaded());
  } else {
    await KnowledgeService.instance.ensureLoaded();
  }

  // 桌面：机器本地偏好（窗口几何 / 面板宽度 / 终端 shell 等，不参与云端同步）
  final desktopPrefs = DesktopPrefsService.instance;
  if (DesktopPlatform.isDesktop) {
    await desktopPrefs.load();
    await LuaRuntimeService.instance.loadUserConfig();
    LuaRuntimeService.instance.attachSettings(settingsProvider);
    // Hub 与 Editor 是独立进程：窗口标题、几何持久化策略各自独立
    final projectName = p.basename(LaunchArgs.projectPath);
    await DesktopWindowHost.instance.initialize(
      desktopPrefs,
      title: LaunchArgs.isEditor
          ? (projectName.isEmpty
                ? AppInfo.editorName
                : '${AppInfo.editorName} · $projectName')
          : AppInfo.hubName,
      persistPlacement: !LaunchArgs.isEditor,
      center: LaunchArgs.isEditor,
      preferredSize: LaunchArgs.isEditor ? const Size(1360, 860) : null,
    );
  }

  // 桌面：插件注册表（语言服务 / 命令 / 片段），与项目 Payload 无关
  // Editor 角色在「预加载项目」阶段再加载，缩短无界面等待
  if (DesktopPlatform.isDesktop && !LaunchArgs.isEditor) {
    await PluginService.instance.ensureLoaded();
  }

  // 第三方 MCP / 外源 Skill 的本地配置（仅本机保存）
  if (!LaunchArgs.isEditor) {
    await AiExtensionsService.instance.ensureLoaded();
  }

  // GitHub 专用 Hosts：先读本地缓存，过期时后台从服务端更新
  // （仅作用于应用内 HTTP 请求，不涉及 VPN / 代理 / 系统 hosts）
  unawaited(
    GithubHostsService.instance.ensureLoaded(
      enabled: settingsProvider.settings.githubHostsEnabled,
    ),
  );

  // 用户自定义 Payload：启动时注入 System / Block 注册表，
  // 保证设计稿编排器与 Loader 构建能立即看到自定义条目
  // Editor 角色在「预加载项目」阶段再初始化（Payload 检测在 openProject 中才发生）
  if (!LaunchArgs.isEditor) {
    await CustomPayloadService.instance.init();
  }

  // Git 平台与账号的登录态恢复放后台执行：
  // 未配置后端/凭据或网络不可达时降级为未登录，绝不阻塞首屏
  final githubProvider = GitHubProvider();
  final giteeProvider = GiteeProvider();
  final connectorService = ConnectorService()
    ..register(GitHubAiConnector(githubProvider))
    ..register(GiteeAiConnector(giteeProvider));
  await connectorService.ensureLoaded();

  // 账号体系：登录后可同步偏好设置 / 头像 / 壁纸
  final accountProvider = AccountProvider(settingsProvider);
  settingsProvider.attachRemoteSync(accountProvider.pushSettingsIfLoggedIn);

  // 其余 Provider 依赖上面三者，直接实例化后注入
  final projectProvider = ProjectProvider();
  final editorProvider = EditorProvider();

  // 桌面：语言服务（LSP）- 根据项目根目录自动启动 Dart 语言服务
  final lspProvider = LspProvider(editorProvider: editorProvider);
  if (DesktopPlatform.isDesktop) {
    LuaRuntimeService.instance.attachLsp(lspProvider);
  }

  // 桌面：把未保存状态与保存能力交给窗口层，用于关闭确认
  if (DesktopPlatform.isDesktop) {
    DesktopWindowHost.instance.hasUnsavedChanges = () =>
        editorProvider.hasUnsavedChanges;
    DesktopWindowHost.instance.saveAll = () async {
      final pending = editorProvider.openFiles
          .where((f) => f.isModified)
          .length;
      final saved = await editorProvider.saveAll();
      return saved >= pending;
    };

    // Linux 保守内存策略：接近上限时降载，超过硬阈值保存后退出
    unawaited(
      MemoryGuardService.instance.start(
        saveState: () async {
          await DesktopWindowHost.instance.saveAll?.call();
          await desktopPrefs.save();
        },
      ),
    );
  }
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

  // AI 助手（Agent 面板依赖它；未注册会导致侧边栏 Agent 页空白）
  final aiProvider = AiProvider(
    settingsProvider,
    editorProvider,
    buildProvider,
    projectProvider,
    accountProvider,
    connectors: connectorService,
    terminal: terminalProvider,
  );

  // 项目隔离：切换项目时重置编辑器、构建状态与 AI 会话（每个项目独立会话）
  projectProvider.onProjectChanged = (path) async {
    await editorProvider.switchProject(path);
    buildProvider.resetForProject();
    await aiProvider.handleProjectChanged();
    // 桌面：同步 LSP 会话与上次项目路径（仅 Hub 负责记忆，避免两个进程互相覆盖）
    unawaited(lspProvider.setProject(path));
    if (DesktopPlatform.isDesktop && !LaunchArgs.isEditor) {
      desktopPrefs.update(() => desktopPrefs.lastProjectPath = path ?? '');
      await desktopPrefs.save();
    }
  };

  // 桌面：工具链管理（安装 / 切换 Flutter、Dart、Node、JDK）
  final toolchainProvider = ToolchainProvider();
  if (DesktopPlatform.isDesktop) {
    unawaited(toolchainProvider.initialize());
  }

  // 桌面：本地构建 / 运行 / 测试
  final localBuildProvider = LocalBuildProvider();

  runApp(
    SLIPEApp(
      settingsProvider: settingsProvider,
      accountProvider: accountProvider,
      githubProvider: githubProvider,
      giteeProvider: giteeProvider,
      connectorService: connectorService,
      projectProvider: projectProvider,
      editorProvider: editorProvider,
      containerProvider: containerProvider,
      terminalProvider: terminalProvider,
      gitSyncProvider: gitSyncProvider,
      buildProvider: buildProvider,
      aiProvider: aiProvider,
      toolchainProvider: toolchainProvider,
      localBuildProvider: localBuildProvider,
      lspProvider: lspProvider,
      editorProjectPath: LaunchArgs.isEditor ? LaunchArgs.projectPath : null,
    ),
  );

  if (DesktopPlatform.isDesktop && LaunchArgs.isHub) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(LuaRuntimeService.instance.start());
    });
  }

  // Hub：编辑器子进程异常退出时，弹出「SLIPE 异常窗口」
  if (LaunchArgs.isHub && DesktopPlatform.isDesktop) {
    // 窗口互斥：Hub 隐藏后，Editor 通过控制桥请求恢复；全部编辑器关闭也会恢复
    unawaited(
      HubBridgeService.instance.startHubListener(
        onShow: DesktopWindowHost.instance.showWindow,
      ),
    );
    EditorProcessService.instance.onAllClosed =
        DesktopWindowHost.instance.showWindow;
    EditorProcessService.instance.onCrash = (report) {
      CrashLogService.instance.write(
        'INFO',
        '编辑器异常退出（exit=${report.exitCode}），打开 SLIPE 异常窗口',
      );
      final navigator = appNavigatorKey.currentState;
      if (navigator == null) return;
      navigator.push(
        MaterialPageRoute(builder: (_) => CrashReportScreen(report: report)),
      );
    };
  }

  // 首帧渲染后再恢复登录态；任一初始化失败只影响对应入口
  unawaited(
    _initAuthInBackground(githubProvider, giteeProvider, accountProvider),
  );

  // 编辑器：低帧率/持续重绘诊断（写入崩溃日志，便于定位输入迟滞）
  if (LaunchArgs.isEditor && DesktopPlatform.isDesktop) {
    _installFrameDiagnostics();
  }

  // Hub 默认保持全局上下文；项目只由用户在首页显式挂载。
  if (!DesktopPlatform.isDesktop) {
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
}

/// 帧率与事件循环诊断：编辑器出现持续重绘或同步阻塞时写入日志。
///
/// 每 5 秒统计一次帧数与平均 build/raster 耗时；同时用 1 秒定时器测量
/// 事件循环延迟（延迟大 = 主 isolate 被同步代码占住），异常时才记录。
void _installFrameDiagnostics() {
  var frames = 0;
  var buildUs = 0;
  var rasterUs = 0;
  var windowStart = DateTime.now();
  var lastLogAt = DateTime.fromMillisecondsSinceEpoch(0);
  var lastTickAt = DateTime.now();

  SchedulerBinding.instance.addTimingsCallback((timings) {
    for (final timing in timings) {
      frames++;
      buildUs += timing.buildDuration.inMicroseconds;
      rasterUs += timing.rasterDuration.inMicroseconds;
    }
  });

  Timer.periodic(const Duration(seconds: 1), (_) {
    final now = DateTime.now();
    // 真实的事件循环延迟：与上一次 tick 的间隔（正常约 1000ms）
    final lagMs = now.difference(lastTickAt).inMilliseconds;
    lastTickAt = now;

    final elapsed = now.difference(windowStart);
    if (elapsed < const Duration(seconds: 5)) return;

    final fps = frames * 1000 / elapsed.inMilliseconds;

    // 距上次记录至少 15 秒，避免刷日志
    if (now.difference(lastLogAt) < const Duration(seconds: 15)) {
      frames = 0;
      buildUs = 0;
      rasterUs = 0;
      windowStart = now;
      return;
    }

    final heavyRepaint = fps > 15;
    final blocked = lagMs > 1200;
    // 持续记录（每 15 秒一行），便于把点击时间与帧率对应起来定位问题
    CrashLogService.instance.write(
      '${heavyRepaint || blocked ? 'WARN' : 'INFO'}',
      'UI 诊断：${fps.toStringAsFixed(1)}fps，'
          '平均 build=${frames == 0 ? 0 : (buildUs / frames / 1000).toStringAsFixed(1)}ms '
          'raster=${frames == 0 ? 0 : (rasterUs / frames / 1000).toStringAsFixed(1)}ms '
          '事件循环延迟=${lagMs}ms '
          '活跃动画=${SchedulerBinding.instance.transientCallbackCount} '
          '有待渲染帧=${SchedulerBinding.instance.hasScheduledFrame}',
    );
    lastLogAt = now;
    frames = 0;
    buildUs = 0;
    rasterUs = 0;
    windowStart = now;
  });
}

/// 指针探针：记录鼠标按下事件的坐标、视图尺寸与像素比。
///
/// 用于区分两类故障：事件根本没送达窗口（坐标日志缺失），
/// 还是送达但坐标与绘制错位（坐标明显超出/偏离视图尺寸）。
class _PointerProbe extends StatefulWidget {
  const _PointerProbe({required this.child});

  final Widget child;

  @override
  State<_PointerProbe> createState() => _PointerProbeState();
}

class _PointerProbeState extends State<_PointerProbe> {
  DateTime _lastLogAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _loggedView = false;

  void _logViewOnce() {
    if (_loggedView) return;
    _loggedView = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final size = MediaQuery.maybeSizeOf(context);
      final ratio = MediaQuery.maybeDevicePixelRatioOf(context);
      CrashLogService.instance.write(
        'INFO',
        '视图尺寸=${size?.width.toStringAsFixed(0)}x${size?.height.toStringAsFixed(0)} '
            '像素比=$ratio',
      );
    });
  }

  Future<void> _log(String kind, PointerDownEvent event) async {
    final now = DateTime.now();
    if (now.difference(_lastLogAt) < const Duration(seconds: 2)) return;
    _lastLogAt = now;
    final size = MediaQuery.maybeSizeOf(context);
    // 命中测试：确认该坐标下到底命中了哪些渲染对象
    String hitInfo;
    try {
      final result = HitTestResult();
      WidgetsBinding.instance.hitTestInView(
        result,
        event.position,
        event.viewId,
      );
      final names = result.path
          .map((entry) => entry.target.runtimeType.toString())
          .where((name) => name != 'RenderIgnorePointer')
          .take(4)
          .join(' < ');
      hitInfo = '命中层数=${result.path.length} [$names]';
    } catch (e) {
      hitInfo = '命中测试失败=$e';
    }
    String windowInfo = '';
    try {
      final windowSize = await windowManager.getSize();
      final position = await windowManager.getPosition();
      final maximized = await windowManager.isMaximized();
      windowInfo =
          ' 窗口=${windowSize.width.toStringAsFixed(0)}x'
          '${windowSize.height.toStringAsFixed(0)}'
          ' @${position.dx.toStringAsFixed(0)},${position.dy.toStringAsFixed(0)}'
          ' 最大化=$maximized';
    } catch (_) {}
    CrashLogService.instance.write(
      'INFO',
      '指针$kind：${event.position.dx.toStringAsFixed(0)},'
          '${event.position.dy.toStringAsFixed(0)} '
          '按钮=${event.buttons} 视图=${size?.width.toStringAsFixed(0)}x'
          '${size?.height.toStringAsFixed(0)} $hitInfo$windowInfo',
    );
  }

  @override
  Widget build(BuildContext context) {
    _logViewOnce();
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) => _log('按下', event),
      child: widget.child,
    );
  }
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
    required this.connectorService,
    required this.projectProvider,
    required this.editorProvider,
    required this.containerProvider,
    required this.terminalProvider,
    required this.gitSyncProvider,
    required this.buildProvider,
    required this.aiProvider,
    required this.toolchainProvider,
    required this.localBuildProvider,
    required this.lspProvider,
    this.editorProjectPath,
  });

  final SettingsProvider settingsProvider;
  final AccountProvider accountProvider;
  final GitHubProvider githubProvider;
  final GiteeProvider giteeProvider;
  final ConnectorService connectorService;
  final ProjectProvider projectProvider;
  final EditorProvider editorProvider;
  final ContainerProvider containerProvider;
  final TerminalProvider terminalProvider;
  final GitSyncProvider gitSyncProvider;
  final BuildProvider buildProvider;
  final AiProvider aiProvider;
  final ToolchainProvider toolchainProvider;
  final LocalBuildProvider localBuildProvider;
  final LspProvider lspProvider;

  /// 非空表示当前进程是 Editor 角色：直接打开该项目并进入编辑器
  final String? editorProjectPath;

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
        ChangeNotifierProvider.value(value: connectorService),
        ChangeNotifierProvider.value(value: gitSyncProvider),
        ChangeNotifierProvider.value(value: buildProvider),
        ChangeNotifierProvider.value(value: aiProvider),
        ChangeNotifierProvider.value(value: toolchainProvider),
        ChangeNotifierProvider.value(value: localBuildProvider),
        ChangeNotifierProvider.value(value: lspProvider),
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
            scaffoldMessengerKey: appScaffoldMessengerKey,
            builder: (context, child) => PluginInstallLinkHandler(
              child: editorProjectPath == null
                  ? (child ?? const SizedBox.shrink())
                  : _PointerProbe(child: child ?? const SizedBox.shrink()),
            ),
            // 动态壁纸感知路由切换：被页面遮挡时暂停，返回时恢复
            navigatorObservers: [AppBackground.routeObserver],
            // Editor 角色：独立进程，直接打开指定项目；
            // Hub 角色：政策门禁 + 应用锁 + 项目中心
            home: editorProjectPath == null
                ? AppLockGate(child: PolicyGate(child: MainShell()))
                : _EditorProcessRoot(projectPath: editorProjectPath!),
          );
        },
      ),
    );
  }

  ThemeData _buildLightTheme(String fontFamily) {
    return _desktopAdjust(
      ThemeData(
        useMaterial3: true,
        fontFamily: fontFamily.isEmpty ? null : fontFamily,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0175C2), // Flutter 蓝
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F7FA),
      ),
    );
  }

  ThemeData _buildDarkTheme(String fontFamily) {
    return _desktopAdjust(
      ThemeData(
        useMaterial3: true,
        fontFamily: fontFamily.isEmpty ? null : fontFamily,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0175C2),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF1E1E1E),
      ),
    );
  }

  /// 桌面密度与滚动条：移动端保持原样。
  ThemeData _desktopAdjust(ThemeData base) {
    if (!DesktopPlatform.isDesktop) return base;
    return base.copyWith(
      visualDensity: VisualDensity.compact,
      scrollbarTheme: ScrollbarThemeData(
        thumbVisibility: const WidgetStatePropertyAll(true),
        thickness: const WidgetStatePropertyAll(9),
        radius: const Radius.circular(5),
        thumbColor: WidgetStatePropertyAll(
          base.colorScheme.onSurface.withValues(alpha: 0.28),
        ),
      ),
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 450),
      ),
      dividerTheme: DividerThemeData(
        space: 1,
        thickness: 1,
        color: base.colorScheme.outlineVariant.withValues(alpha: 0.6),
      ),
    );
  }
}

/// Editor 进程根组件
///
/// 独立进程启动时只有一件事：打开指定的项目并进入编辑器。
/// 打开失败时给出明确提示，而不是留在空白页面。
class _EditorProcessRoot extends StatefulWidget {
  const _EditorProcessRoot({required this.projectPath});

  final String projectPath;

  @override
  State<_EditorProcessRoot> createState() => _EditorProcessRootState();
}

class _EditorProcessRootState extends State<_EditorProcessRoot> {
  _LoadStage _stage = _LoadStage.opening;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    setState(() {
      _loading = true;
      _error = null;
      _stage = _LoadStage.opening;
    });
    try {
      // 先让加载页完成首帧，后续阶段才有可见的进度变化
      await Future<void>.delayed(const Duration(milliseconds: 32));
      if (!mounted) return;

      setState(() => _stage = _LoadStage.preloading);
      await _loadDeferredServices();
      if (!mounted) return;

      final provider = context.read<ProjectProvider>();
      // 打开项目包含 AI 历史等后台任务，给一个上限避免极端情况下卡在加载页
      await provider
          .openProject(widget.projectPath)
          .timeout(const Duration(seconds: 20), onTimeout: () {});
      if (!mounted) return;

      setState(() => _stage = _LoadStage.warming);
      final lsp = context.read<LspProvider>();
      unawaited(lsp.setProject(widget.projectPath));
      await _waitForLsp(lsp);
      if (!mounted) return;

      setState(() => _stage = _LoadStage.finishing);
      // 避免加载页一闪而过
      await Future<void>.delayed(const Duration(milliseconds: 180));
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// 编辑器专属的延迟初始化（_bootstrap 中已为 Editor 角色跳过）
  Future<void> _loadDeferredServices() async {
    await PluginService.instance.ensureLoaded();
    // 此时加载页已经完成首帧，插件 main.lua 不阻塞窗口出现。
    unawaited(LuaRuntimeService.instance.start());
    await CustomPayloadService.instance.init();
    await AiExtensionsService.instance.ensureLoaded();
  }

  /// 预热语言服务：最多等待 2s，超时直接进入完成阶段
  Future<void> _waitForLsp(LspProvider lsp) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      if (lsp.state != LspManagerState.starting) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loading && _error == null) {
      return const EditorScreen();
    }
    final name = p.basename(widget.projectPath);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: _error == null
              ? _StagedLoadingView(projectName: name, stage: _stage)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.folder_off_outlined, size: 44),
                    const SizedBox(height: 14),
                    Text(
                      '无法打开项目「$name」',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      widget.projectPath,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _error ?? '',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12, height: 1.6),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FilledButton(onPressed: _open, child: const Text('重试')),
                        const SizedBox(width: 10),
                        OutlinedButton(
                          onPressed: () =>
                              DesktopWindowHost.instance.requestClose(),
                          child: const Text('关闭窗口'),
                        ),
                      ],
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// 编辑器启动阶段
enum _LoadStage { opening, preloading, warming, finishing }

/// 分阶段加载视图（确定进度 + 阶段清单，避免无限转圈在卡顿时更明显）
class _StagedLoadingView extends StatefulWidget {
  const _StagedLoadingView({required this.projectName, required this.stage});

  final String projectName;
  final _LoadStage stage;

  @override
  State<_StagedLoadingView> createState() => _StagedLoadingViewState();
}

class _StagedLoadingViewState extends State<_StagedLoadingView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  static const _labels = {
    _LoadStage.opening: '打开项目',
    _LoadStage.preloading: '预加载项目',
    _LoadStage.warming: '预热编辑器',
    _LoadStage.finishing: '完成加载',
  };

  static const _progress = {
    _LoadStage.opening: 0.15,
    _LoadStage.preloading: 0.5,
    _LoadStage.warming: 0.85,
    _LoadStage.finishing: 1.0,
  };

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.stage.index;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RepaintBoundary(
          child: SizedBox(
            width: 40,
            height: 40,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) =>
                  CustomPaint(painter: _RingSpinnerPainter(_controller.value)),
            ),
          ),
        ),
        const SizedBox(height: 18),
        Text(
          '${_labels[widget.stage]}「${widget.projectName}」…',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: 260,
          child: Column(
            children: [
              for (final stage in _LoadStage.values)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(
                        stage.index < current
                            ? Icons.check_circle
                            : (stage.index == current
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked),
                        size: 15,
                        color: stage.index <= current
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).disabledColor,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _labels[stage]!,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: stage.index == current
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: stage.index <= current
                              ? null
                              : Theme.of(context).disabledColor,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: 260,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: _progress[widget.stage]!),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            builder: (context, value, _) => ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(value: value, minHeight: 3),
            ),
          ),
        ),
      ],
    );
  }
}

/// 加载圆环：渐变描边 + 匀速旋转，比 CircularProgressIndicator 更轻量
class _RingSpinnerPainter extends CustomPainter {
  _RingSpinnerPainter(this.turn);

  final double turn;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final start = turn * 6.283185307179586;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: start,
        endAngle: start + 4.2,
        colors: const [Color(0x000175C2), Color(0xFF0175C2)],
      ).createShader(rect);
    canvas.drawArc(rect.deflate(2), start, 4.2, false, paint);
  }

  @override
  bool shouldRepaint(covariant _RingSpinnerPainter oldDelegate) =>
      oldDelegate.turn != turn;
}
