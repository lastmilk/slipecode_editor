import 'app_info.dart';

/// 一次编辑器进程异常退出的报告
class EditorCrashReport {
  EditorCrashReport({
    required this.projectPath,
    required this.projectName,
    required this.exitCode,
    required this.startedAt,
    required this.endedAt,
    required this.logPath,
    required this.logLines,
    this.editorLogPath = '',
    this.editorVersion = AppInfo.version,
  });

  final String projectPath;
  final String projectName;
  final int? exitCode;
  final DateTime startedAt;
  final DateTime endedAt;

  /// Hub 捕获的子进程输出日志
  final String logPath;

  /// 编辑器进程自己写的日志（若能从启动头中解析到）
  final String editorLogPath;

  /// 编辑器进程自报的版本
  final String editorVersion;

  /// 关键日志尾部
  final List<String> logLines;

  Duration get duration => endedAt.difference(startedAt);

  String get hubVersion => AppInfo.versionLabel;

  String get osLabel => AppInfo.osLabel;

  /// 退出码 / 信号的友好说明
  String get exitLabel {
    final code = exitCode;
    if (code == null) return '未知（进程未返回退出码）';
    // Linux 下被信号终止时 exitCode 为负数（-11 即 SIGSEGV），
    // 统一换算成 shell 习惯的 128 + signal
    final normalized = normalizeExitCode(code);
    final signal = switch (normalized) {
      129 => 'SIGHUP',
      130 => 'SIGINT',
      133 => 'SIGTRAP（调试陷阱）',
      134 => 'SIGABRT（主动中止 / 断言失败）',
      137 => 'SIGKILL（可能被系统或 OOM 杀死）',
      139 => 'SIGSEGV（段错误，原生层崩溃）',
      143 => 'SIGTERM（被终止）',
      _ => '',
    };
    return signal.isEmpty ? '$normalized' : '$normalized · $signal';
  }

  /// 从日志中抽取的关键错误信息
  String get keyError {
    final pattern = RegExp(
      r'(Unhandled Exception|MissingPluginException|PlatformException|'
      r'OutOfMemoryError|FileSystemException|PathNotFoundException|'
      r'SocketException|FormatException|Segmentation fault|Aborted|'
      r'FATAL|Exception:|Error:)',
    );
    for (final line in logLines.reversed) {
      final text = line.trim();
      if (text.isEmpty) continue;
      if (pattern.hasMatch(text)) return text;
    }
    final normalized = normalizeExitCode(exitCode);
    if (normalized != null && normalized >= 128) {
      return '进程被信号终止（$exitLabel），日志中没有异常堆栈——'
          '这类崩溃通常发生在原生层（图形驱动、原生插件等）。';
    }
    for (final line in logLines.reversed) {
      final text = line.trim();
      if (text.isEmpty) continue;
      if (text.startsWith('[') && text.contains('INFO]')) continue;
      return text;
    }
    return '（日志中没有可识别的错误行）';
  }
}

/// 自动错误分析结果
class CrashAnalysis {
  const CrashAnalysis({
    required this.headline,
    required this.findings,
    required this.suggestions,
  });

  /// 一句话结论
  final String headline;

  /// 识别到的信号 / 证据
  final List<String> findings;

  /// 建议的排查动作
  final List<String> suggestions;
}

/// 归一化退出码：负值表示被信号终止，换算为 128 + signal
int? normalizeExitCode(int? code) =>
    (code != null && code < 0) ? 128 + (-code) : code;

/// 根据退出码与日志尾部自动分析崩溃原因
CrashAnalysis analyzeEditorCrash({
  required int? exitCode,
  required List<String> logLines,
}) {
  final code = normalizeExitCode(exitCode);
  final findings = <String>[];
  final suggestions = <String>[];
  final text = logLines.join('\n');

  void add(String finding, String suggestion) {
    if (!findings.contains(finding)) findings.add(finding);
    if (!suggestions.contains(suggestion)) suggestions.add(suggestion);
  }

  // 1. 退出码 / 信号
  switch (code) {
    case 139:
      add(
        '退出码 139（SIGSEGV）：原生层段错误，通常是 GPU 驱动、图形后端或原生插件导致。',
        '尝试切换渲染后端或更新显卡驱动后重试。',
      );
    case 134:
      add(
        '退出码 134（SIGABRT）：进程被主动中止，常见于断言失败或原生库异常。',
        '检查日志中最后的断言信息，并确认第三方原生依赖与当前平台匹配。',
      );
    case 133:
      add('退出码 133（SIGTRAP）：调试陷阱，通常是原生代码触发。', '检查原生插件与插件市场安装的插件是否兼容。');
    case 137:
      add('退出码 137（SIGKILL）：进程被系统强制结束，常见原因是内存不足。', '关闭占用内存较高的程序后重试，或减小项目规模。');
    case 143:
      add('退出码 143（SIGTERM）：进程被外部信号终止。', '确认是否有其他程序或系统策略结束了编辑器进程。');
    case 1:
      add('退出码 1：进程因未捕获的异常或主动错误退出。', '根据下方关键错误信息定位具体代码或配置问题。');
    case null:
      add('未获取到退出码：进程可能被系统直接终止。', '查看日志末尾是否有系统级错误（如 OOM Killed）。');
  }

  // 2. 日志特征
  if (RegExp(r'Segmentation fault|core dumped|SIGSEGV').hasMatch(text)) {
    add('日志中出现段错误（segmentation fault）相关记录。', '优先怀疑图形驱动 / 原生插件；可尝试重启应用或切换渲染后端。');
  }
  if (text.contains('OutOfMemoryError') || text.contains('Out of memory')) {
    add('内存分配失败（OutOfMemoryError）。', '关闭其他占用内存的应用，并避免一次打开过多大文件。');
  }
  if (text.contains('MissingPluginException')) {
    add(
      '插件通道未注册（MissingPluginException），通常是热重载或平台通道初始化异常。',
      '完全退出应用后重新启动；若仍出现，请检查是否为已废弃的插件调用。',
    );
  }
  if (text.contains('PlatformException')) {
    add('平台通道抛出 PlatformException。', '查看关键错误信息中的通道名与错误码，确认对应平台能力是否可用。');
  }
  if (RegExp(
    r'FileSystemException|PathNotFoundException|No such file or directory',
  ).hasMatch(text)) {
    add('文件或目录不存在 / 无权限访问。', '确认项目目录仍然存在且当前用户有读写权限；必要时重新打开项目。');
  }
  if (RegExp(r'SocketException|Connection refused|Connection reset|TLS')
      .hasMatch(text)) {
    add('网络连接异常（后端不可达或连接被重置）。', '检查网络与后端服务地址；离线场景下可忽略与同步相关的错误。');
  }
  if (text.contains('FormatException')) {
    add(
      '数据解析失败（FormatException），通常是配置 / 清单文件格式错误。',
      '检查项目配置（如 .slipe.json、plugin.json、pubspec.yaml）的 JSON / YAML 语法。',
    );
  }
  if (RegExp(r'Could not load library|undefined symbol|\.so(\.[0-9]+)*:')
      .hasMatch(text)) {
    add('原生动态库加载失败。', '确认系统依赖完整（如 GTK / libsecret），并检查安装包是否完整。');
  }
  if (RegExp(r'Impeller|OpenGL|Vulkan|EGL|GL_').hasMatch(text)) {
    add('日志中包含图形渲染相关错误。', '可尝试更新显卡驱动，或使用软件渲染启动以排除 GPU 问题。');
  }
  if (text.contains('A RenderFlex overflowed') ||
      text.contains('Failed assertion')) {
    add('Flutter 断言失败（通常是布局或状态使用不当）。', '这是可复现的界面问题，请连同日志与复现步骤一起反馈。');
  }

  // 3. 结论
  final headline = switch (exitCode) {
    139 => '编辑器因原生崩溃退出（SIGSEGV）',
    134 => '编辑器被中止（SIGABRT）',
    133 => '编辑器触发调试陷阱（SIGTRAP）',
    137 => '编辑器被系统强制结束（SIGKILL）',
    143 => '编辑器被外部终止（SIGTERM）',
    0 => '编辑器已正常退出，但 Hub 未收到预期状态',
    null => '编辑器进程异常结束',
    _ => '编辑器因未处理的错误退出（退出码 $code）',
  };

  if (findings.isEmpty) {
    findings.add('日志中没有匹配到已知的错误特征，退出码为 ${code ?? '未知'}。');
  }
  suggestions.add('如果问题可以复现，请导出错误日志并附上复现步骤反馈。');

  return CrashAnalysis(
    headline: headline,
    findings: findings,
    suggestions: suggestions,
  );
}

/// 生成可导出的完整诊断文本
String buildCrashReportText(EditorCrashReport report, CrashAnalysis analysis) {
  final buffer = StringBuffer()
    ..writeln('SLIPE 异常诊断报告')
    ..writeln('=' * 48)
    ..writeln('时间：${_formatTime(report.endedAt)}')
    ..writeln('系统：${report.osLabel}')
    ..writeln('编辑器版本：${report.editorVersion}')
    ..writeln('Hub 版本：${report.hubVersion}')
    ..writeln('项目：${report.projectName}')
    ..writeln('项目路径：${report.projectPath}')
    ..writeln('退出码：${report.exitLabel}')
    ..writeln('启动时间：${_formatTime(report.startedAt)}')
    ..writeln('运行时长：${_duration(report.duration)}')
    ..writeln()
    ..writeln('— 自动分析 —')
    ..writeln(analysis.headline)
    ..writeln()
    ..writeln('识别到的信号：');
  for (final finding in analysis.findings) {
    buffer.writeln('  · $finding');
  }
  buffer
    ..writeln()
    ..writeln('建议：');
  for (final suggestion in analysis.suggestions) {
    buffer.writeln('  · $suggestion');
  }
  buffer
    ..writeln()
    ..writeln('— 关键错误信息 —')
    ..writeln(report.keyError)
    ..writeln()
    ..writeln('— 日志文件 —')
    ..writeln('Hub 捕获日志：${report.logPath}')
    ..writeln(
      '编辑器日志：${report.editorLogPath.isEmpty ? '（未获取）' : report.editorLogPath}',
    )
    ..writeln()
    ..writeln('— 日志尾部（最近 ${report.logLines.length} 行）—');
  buffer.writeln(report.logLines.join('\n'));
  return buffer.toString();
}

String _formatTime(DateTime time) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}

String _duration(Duration duration) {
  if (duration.inSeconds < 60) return '${duration.inSeconds} 秒';
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds % 60;
  return '$minutes 分 $seconds 秒';
}
