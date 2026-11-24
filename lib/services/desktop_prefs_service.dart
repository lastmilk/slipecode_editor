import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'desktop_platform.dart';

/// 机器本地桌面偏好。
///
/// 与 [AppSettings] 不同，这里的字段（窗口几何、面板宽度、本机 Shell、
/// 工具链默认版本等）不参与云端同步，避免跨设备互相覆盖。
class DesktopPrefsService extends ChangeNotifier {
  DesktopPrefsService._();

  static final DesktopPrefsService instance = DesktopPrefsService._();

  File? _file;
  Timer? _saveTimer;
  bool _loaded = false;
  Map<String, Object?> _luaOverrides = const {};

  bool get isLoaded => _loaded;

  // 窗口几何
  bool hasWindowPlacement = false;
  double windowX = 0;
  double windowY = 0;
  double _windowWidth = 1440;
  double _windowHeight = 900;
  bool windowMaximized = false;

  double get windowWidth => _doubleOverride('view.windowWidth', _windowWidth);
  set windowWidth(double value) => _windowWidth = value;
  double get windowHeight =>
      _doubleOverride('view.windowHeight', _windowHeight);
  set windowHeight(double value) => _windowHeight = value;

  // 布局
  double sidebarWidth = 260;
  bool _sidebarVisible = true;
  double panelHeight = 220;
  bool _panelVisible = false;

  bool get sidebarVisible =>
      _boolOverride('view.sidebarVisible', _sidebarVisible);
  set sidebarVisible(bool value) => _sidebarVisible = value;
  bool get panelVisible => _boolOverride('view.panelVisible', _panelVisible);
  set panelVisible(bool value) => _panelVisible = value;

  /// SOLO 布局：AI 面板常驻左侧 + 代码区（IDE 布局则是代码区 + 右侧 AI）
  bool _soloLayout = false;

  bool get soloLayout => _boolOverride('view.soloLayout', _soloLayout);
  set soloLayout(bool value) => _soloLayout = value;

  /// AI 常驻侧边栏宽度（IDE 在右、SOLO 在左，共用同一宽度）
  double _aiPanelWidth = 360;

  double get aiPanelWidth =>
      _doubleOverride('view.aiPanelWidth', _aiPanelWidth);
  set aiPanelWidth(double value) => _aiPanelWidth = value;

  // 启动行为
  String lastProjectPath = '';
  bool restoreLastProject = true;

  /// Hub 打开项目后自身的处理方式：close（关闭）/ ask（每次询问）
  String hubExitMode = 'close';

  // Linux 保守内存策略（仅本机生效，不参与云同步）
  bool linuxMemoryGuardEnabled = true;
  int linuxMemoryWarnPercent = 60;
  int linuxMemoryExitPercent = 80;
  int linuxMemoryCheckSeconds = 5;

  // 终端
  String shellPath = '';
  double _terminalFontSize = 13;

  double get terminalFontSize =>
      _doubleOverride('terminal.fontSize', _terminalFontSize);
  set terminalFontSize(double value) => _terminalFontSize = value;

  // 工具链
  String toolchainMirror = 'cn';
  final Map<String, String> defaultToolchains = {};
  final Map<String, Map<String, String>> projectToolchains = {};

  // 语言服务（LSP）
  bool _lspEnabled = true;

  bool get lspEnabled => _boolOverride('lsp.enabled', _lspEnabled);
  set lspEnabled(bool value) => _lspEnabled = value;

  /// 应用内存中的 Lua 覆盖层。setter 与 save 始终只操作基础值。
  /// 窗口尺寸覆盖仅供下一次启动的 WindowOptions 使用，映射后不 resize。
  void applyLuaOverrides(Map<String, Object?> overrides) {
    _luaOverrides = Map.unmodifiable(overrides);
    notifyListeners();
  }

  double _doubleOverride(String key, double base) {
    final value = _luaOverrides[key];
    return value is num ? value.toDouble() : base;
  }

  bool _boolOverride(String key, bool base) {
    final value = _luaOverrides[key];
    return value is bool ? value : base;
  }

  /// 常用命令（命令面板 / 终端历史）。
  final List<String> recentCommands = [];

  /// 最近本地构建记录（JSON 字符串，最多 20 条）。
  final List<String> recentBuilds = [];

  String get effectiveShell => shellPath.trim().isEmpty
      ? DesktopPlatform.defaultShell
      : shellPath.trim();

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    if (!DesktopPlatform.isDesktop) return;
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File(
        '${dir.path}${Platform.pathSeparator}desktop_prefs.json',
      );
      _file = file;
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return;
      final map = raw.cast<String, dynamic>();

      hasWindowPlacement = map['hasWindowPlacement'] == true;
      windowX = _double(map['windowX'], windowX);
      windowY = _double(map['windowY'], windowY);
      windowWidth = _double(map['windowWidth'], _windowWidth);
      windowHeight = _double(map['windowHeight'], _windowHeight);
      windowMaximized = map['windowMaximized'] == true;

      sidebarWidth = _double(map['sidebarWidth'], sidebarWidth).clamp(180, 480);
      sidebarVisible = map['sidebarVisible'] != false;
      panelHeight = _double(map['panelHeight'], panelHeight).clamp(120, 720);
      panelVisible = map['panelVisible'] == true;
      soloLayout = map['soloLayout'] == true;
      // 兼容旧字段 soloPanelWidth
      aiPanelWidth = parseAiPanelWidth(map, fallback: _aiPanelWidth);

      lastProjectPath = (map['lastProjectPath'] as String?) ?? '';
      restoreLastProject = map['restoreLastProject'] != false;

      final hubMode = (map['hubExitMode'] as String?) ?? hubExitMode;
      hubExitMode = normalizeHubExitMode(hubMode);

      linuxMemoryGuardEnabled = map['linuxMemoryGuardEnabled'] != false;
      linuxMemoryWarnPercent = _int(
        map['linuxMemoryWarnPercent'],
        linuxMemoryWarnPercent,
      ).clamp(30, 90);
      linuxMemoryExitPercent = _int(
        map['linuxMemoryExitPercent'],
        linuxMemoryExitPercent,
      ).clamp(linuxMemoryWarnPercent + 5, 95);
      linuxMemoryCheckSeconds = _int(
        map['linuxMemoryCheckSeconds'],
        linuxMemoryCheckSeconds,
      ).clamp(2, 30);

      shellPath = (map['shellPath'] as String?) ?? '';
      terminalFontSize = _double(
        map['terminalFontSize'],
        _terminalFontSize,
      ).clamp(10, 24);

      toolchainMirror = (map['toolchainMirror'] as String?) ?? 'cn';
      lspEnabled = map['lspEnabled'] != false;

      final defaults = map['defaultToolchains'];
      if (defaults is Map) {
        defaults.forEach((key, value) {
          if (value is String) defaultToolchains['$key'] = value;
        });
      }

      final projects = map['projectToolchains'];
      if (projects is Map) {
        projects.forEach((project, pins) {
          if (pins is Map) {
            final converted = <String, String>{};
            pins.forEach((k, v) {
              if (v is String) converted['$k'] = v;
            });
            projectToolchains['$project'] = converted;
          }
        });
      }

      final commands = map['recentCommands'];
      if (commands is List) {
        recentCommands
          ..clear()
          ..addAll(commands.whereType<String>().take(30));
      }

      final builds = map['recentBuilds'];
      if (builds is List) {
        recentBuilds
          ..clear()
          ..addAll(builds.whereType<String>().take(20));
      }
    } catch (e) {
      debugPrint('读取桌面偏好失败：$e');
    }
  }

  /// 修改后延迟落盘，避免拖拽分隔条时频繁写文件。
  void update(void Function() mutate) {
    mutate();
    _saveTimer?.cancel();
    _saveTimer = Timer(
      const Duration(milliseconds: 400),
      () => unawaited(save()),
    );
  }

  Future<void> save() async {
    if (!DesktopPlatform.isDesktop) return;
    try {
      final file =
          _file ??
          File(
            '${(await getApplicationSupportDirectory()).path}'
            '${Platform.pathSeparator}desktop_prefs.json',
          );
      _file = file;
      await file.parent.create(recursive: true);
      final payload = <String, dynamic>{
        'hasWindowPlacement': hasWindowPlacement,
        'windowX': windowX,
        'windowY': windowY,
        'windowWidth': _windowWidth,
        'windowHeight': _windowHeight,
        'windowMaximized': windowMaximized,
        'sidebarWidth': sidebarWidth,
        'sidebarVisible': _sidebarVisible,
        'panelHeight': panelHeight,
        'panelVisible': _panelVisible,
        'soloLayout': _soloLayout,
        'aiPanelWidth': _aiPanelWidth,
        'lastProjectPath': lastProjectPath,
        'restoreLastProject': restoreLastProject,
        'hubExitMode': hubExitMode,
        'linuxMemoryGuardEnabled': linuxMemoryGuardEnabled,
        'linuxMemoryWarnPercent': linuxMemoryWarnPercent,
        'linuxMemoryExitPercent': linuxMemoryExitPercent,
        'linuxMemoryCheckSeconds': linuxMemoryCheckSeconds,
        'shellPath': shellPath,
        'terminalFontSize': _terminalFontSize,
        'toolchainMirror': toolchainMirror,
        'lspEnabled': _lspEnabled,
        'defaultToolchains': defaultToolchains,
        'projectToolchains': projectToolchains,
        'recentCommands': recentCommands,
        'recentBuilds': recentBuilds,
      };
      // 多进程（Hub / Editor）同时写入时使用各自的临时文件，
      // 避免重命名冲突导致保存失败
      final tmp = File('${file.path}.$pid.tmp');
      await tmp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload),
        flush: true,
      );
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('保存桌面偏好失败：$e');
    }
  }

  /// 项目级工具链固定版本。
  String? toolchainPin(String kind, String projectPath) {
    return projectToolchains[projectPath]?[kind];
  }

  void setToolchainPin(String kind, String projectPath, String? version) {
    update(() {
      final pins = projectToolchains.putIfAbsent(projectPath, () => {});
      if (version == null || version.isEmpty) {
        pins.remove(kind);
        if (pins.isEmpty) projectToolchains.remove(projectPath);
      } else {
        pins[kind] = version;
      }
    });
  }

  void addRecentCommand(String command) {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return;
    update(() {
      recentCommands.remove(trimmed);
      recentCommands.insert(0, trimmed);
      if (recentCommands.length > 30) {
        recentCommands.removeRange(30, recentCommands.length);
      }
    });
  }

  double _double(Object? value, double fallback) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? fallback;
    return fallback;
  }

  int _int(Object? value, int fallback) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }
}

/// Hub 打开项目后的处理方式。
///
/// 仅保留「关闭 / 每次询问」：在部分 Wayland 合成器上，隐藏的 Hub 窗口
/// 仍可能参与输入分发，导致编辑器窗口「点不动」。关闭 Hub 进程最稳妥，
/// 返回 Hub 时由编辑器拉起新的 Hub。
String normalizeHubExitMode(String value) {
  return switch (value) {
    'close' || 'ask' => value,
    // 历史值 hide / 非法值统一回落到 close
    _ => 'close',
  };
}

/// 解析 AI 面板宽度：兼容旧字段 soloPanelWidth，并夹取到 [280, 720]
double parseAiPanelWidth(Map map, {double fallback = 360}) {
  final raw = map['aiPanelWidth'] ?? map['soloPanelWidth'];
  double value;
  if (raw is num) {
    value = raw.toDouble();
  } else if (raw is String) {
    value = double.tryParse(raw) ?? fallback;
  } else {
    value = fallback;
  }
  return value.clamp(280.0, 720.0);
}
