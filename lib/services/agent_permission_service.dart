import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/app_settings.dart';
import 'external_mcp_manager.dart';
import 'ai_connector_service.dart';

/// Agent 操作风险等级
enum AgentRiskLevel {
  /// 只读 / 纯信息类
  safe,

  /// 修改项目文件
  write,

  /// 执行命令 / 构建 / 打开外部程序
  execute,

  /// 访问外网（下载、联网搜索、第三方 MCP）
  network,

  /// 高风险：删除、强推、系统级命令等
  critical,
}

extension AgentRiskLevelLabel on AgentRiskLevel {
  String get label => switch (this) {
        AgentRiskLevel.safe => '只读',
        AgentRiskLevel.write => '写入文件',
        AgentRiskLevel.execute => '执行命令',
        AgentRiskLevel.network => '访问网络',
        AgentRiskLevel.critical => '高风险',
      };
}

/// 审批模式
enum AgentApprovalMode {
  /// 每个会改变环境 / 访问网络的操作都询问
  manual,

  /// 自动放行普通操作，高风险与网络访问询问
  auto,

  /// 完全访问，不再询问（仍受硬性安全策略限制）
  full,

  /// 按自定义规则判断
  custom,
}

AgentApprovalMode agentApprovalModeFromId(String id) => switch (id) {
      'manual' => AgentApprovalMode.manual,
      'full' => AgentApprovalMode.full,
      'custom' => AgentApprovalMode.custom,
      _ => AgentApprovalMode.auto,
    };

String agentApprovalModeId(AgentApprovalMode mode) => switch (mode) {
      AgentApprovalMode.manual => 'manual',
      AgentApprovalMode.auto => 'auto',
      AgentApprovalMode.full => 'full',
      AgentApprovalMode.custom => 'custom',
    };

/// 一次审批请求
class AgentPermissionRequest {
  const AgentPermissionRequest({
    required this.tool,
    required this.title,
    required this.detail,
    required this.risk,
    this.command,
    this.allowAlways = true,
  });

  final String tool;

  /// 一句话描述，例如「执行命令」
  final String title;

  /// 具体内容（命令、路径、URL…）
  final String detail;

  final AgentRiskLevel risk;

  /// 若为命令类工具，保存原始命令便于规则匹配
  final String? command;

  /// 是否允许用户选择「本次会话总是允许」
  final bool allowAlways;

  bool get isCritical => risk == AgentRiskLevel.critical;
}

/// 审批回调：返回 true 表示允许执行
typedef AgentPermissionHandler = Future<bool> Function(
  AgentPermissionRequest request,
);

/// 自定义规则
class _AgentRule {
  const _AgentRule(this.action, this.tool, this.pattern);

  /// allow / deny / ask
  final String action;
  final String tool;
  final String? pattern;
}

/// Agent 安全审批服务
///
/// 在 [McpToolbox.execute] 调用真正工具前判定风险，并按用户选择的模式
/// 决定放行 / 询问 / 拒绝。UI 通过 [handler] 弹卡片询问用户。
class AgentPermissionService {
  AgentPermissionService._();

  static final AgentPermissionService instance = AgentPermissionService._();

  /// 审批请求处理器（由 UI 注入）
  AgentPermissionHandler? handler;

  /// 读取当前设置（由 App 初始化时注入）
  AppSettings Function()? settingsReader;

  /// 本次会话「总是允许」的工具
  final Set<String> _alwaysAllowed = {};

  /// 本次会话「拒绝」的工具
  final Set<String> _alwaysDenied = {};

  bool get enabled => handler != null;

  void resetSession() {
    _alwaysAllowed.clear();
    _alwaysDenied.clear();
  }

  void allowAlways(String tool) => _alwaysAllowed.add(tool);

  void denyAlways(String tool) => _alwaysDenied.add(tool);

  /// 工具本身的静态风险等级
  static AgentRiskLevel riskOf(String tool, Map<String, dynamic> args) {
    if (tool.startsWith(ExternalMcpManager.toolPrefix) ||
        tool.startsWith(ConnectorService.toolPrefix)) {
      return AgentRiskLevel.network;
    }
    if (_criticalTools.contains(tool)) return AgentRiskLevel.critical;
    if (_executeTools.contains(tool)) {
      final command = _commandOf(tool, args);
      if (command != null && _looksCritical(command)) {
        return AgentRiskLevel.critical;
      }
      return AgentRiskLevel.execute;
    }
    if (_networkTools.contains(tool)) return AgentRiskLevel.network;
    if (_writeTools.contains(tool)) return AgentRiskLevel.write;
    return AgentRiskLevel.safe;
  }

  /// 判定并（必要时）请求审批。
  ///
  /// 返回 null 表示允许执行；返回非空字符串表示拒绝原因。
  Future<String?> check(String tool, Map<String, dynamic> args) async {
    final risk = riskOf(tool, args);
    if (risk == AgentRiskLevel.safe) return null;
    if (_alwaysDenied.contains(tool)) {
      return '用户已拒绝 $tool';
    }
    final settings = settingsReader?.call() ?? AppSettings.defaults;
    final mode = agentApprovalModeFromId(settings.agentApprovalMode);
    if (mode == AgentApprovalMode.full) return null;

    final request = buildRequest(tool, args, risk);

    bool? ruleDecision;
    if (mode == AgentApprovalMode.custom) {
      final rule = _matchRule(settings.agentApprovalRules, request);
      if (rule != null) {
        switch (rule.action) {
          case 'allow':
            ruleDecision = false;
            break;
          case 'deny':
            return '自定义安全规则拒绝执行 $tool';
          default:
            ruleDecision = true;
        }
      }
    }

    final needsAsk = switch (mode) {
      AgentApprovalMode.manual => true,
      AgentApprovalMode.auto =>
        risk == AgentRiskLevel.critical || risk == AgentRiskLevel.network,
      AgentApprovalMode.custom => ruleDecision ?? true,
      AgentApprovalMode.full => false,
    };
    if (!needsAsk) return null;
    if (_alwaysAllowed.contains(tool) && risk != AgentRiskLevel.critical) {
      return null;
    }

    final ask = handler;
    if (ask == null) {
      // 无 UI 环境（后台任务）时，默认拒绝高风险，其余放行
      return risk == AgentRiskLevel.critical ? '当前无可用的审批界面，已阻止高风险操作' : null;
    }
    final allowed = await ask(request);
    return allowed ? null : '用户拒绝了该操作（$tool）';
  }

  AgentPermissionRequest buildRequest(
    String tool,
    Map<String, dynamic> args,
    AgentRiskLevel risk,
  ) {
    final command = _commandOf(tool, args);
    final detail = switch (tool) {
      'run_terminal_command' => command ?? '',
      'terminal_send_input' =>
        '${args['session_id'] ?? ''} ← ${args['input'] ?? ''}',
      'write_file' || 'create_file' || 'replace_in_file' || 'apply_patch' =>
        _pathOf(args),
      'delete_file' ||
      'rename_file' ||
      'create_dart_class' ||
      'git_checkout' =>
        _pathOf(args),
      'download' => (args['url'] ?? '').toString(),
      'run_build' || 'local_build' || 'run_tests' || 'format_file' => '',
      _ => _compactArgs(args),
    };
    return AgentPermissionRequest(
      tool: tool,
      title: _titleOf(tool, risk),
      detail: detail.isEmpty ? tool : detail,
      risk: risk,
      command: command,
      allowAlways: risk != AgentRiskLevel.critical,
    );
  }

  /// 找到第一条命中的自定义规则（按行顺序，先命中先生效）
  _AgentRule? _matchRule(String raw, AgentPermissionRequest request) {
    final detail = '${request.command ?? ''} ${request.detail}';
    for (final line in raw.split('\n')) {
      final text = line.trim();
      if (text.isEmpty || text.startsWith('#')) continue;
      final rule = _parseRule(text);
      if (rule == null) continue;
      if (rule.tool != '*' && rule.tool != request.tool) continue;
      if (rule.pattern != null && !detail.contains(rule.pattern!)) continue;
      return rule;
    }
    return null;
  }

  _AgentRule? _parseRule(String text) {
    final parts = text.split(RegExp(r'\s+'));
    if (parts.length < 2) return null;
    final action = parts[0].toLowerCase();
    if (!['allow', 'deny', 'ask'].contains(action)) return null;
    final target = parts.sublist(1).join(' ');
    final colon = target.indexOf(':');
    if (colon < 0) return _AgentRule(action, target, null);
    return _AgentRule(
      action,
      target.substring(0, colon).trim(),
      target.substring(colon + 1).trim(),
    );
  }

  static const Set<String> _writeTools = {
    'write_file',
    'replace_in_file',
    'create_file',
    'create_dart_class',
    'rename_file',
    'apply_patch',
    'format_file',
    'lsp_rename',
    'git_commit',
    'git_create_branch',
    'git_stash',
    'video_import_asset',
    'video_add_clip',
    'video_update_clip',
    'video_remove_clip',
    'video_reorder_clips',
    'video_set_project',
  };

  static const Set<String> _executeTools = {
    'run_terminal_command',
    'terminal_send_input',
    'terminal_close',
    'run_build',
    'local_build',
    'run_tests',
    'open_path',
    'video_export',
  };

  static const Set<String> _networkTools = {'download'};

  static const Set<String> _criticalTools = {
    'delete_file',
    'git_checkout',
  };

  static String? _commandOf(String tool, Map<String, dynamic> args) {
    if (tool == 'run_terminal_command') {
      return (args['command'] ?? '').toString();
    }
    return null;
  }

  static String _pathOf(Map<String, dynamic> args) {
    for (final key in ['path', 'from', 'file', 'target']) {
      final value = (args[key] ?? '').toString().trim();
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  static String _compactArgs(Map<String, dynamic> args) {
    final buffer = StringBuffer();
    for (final entry in args.entries.take(4)) {
      final value = entry.value;
      if (value is String && value.length > 120) {
        buffer.write('${entry.key}=${value.substring(0, 120)}… ');
      } else {
        buffer.write('${entry.key}=$value ');
      }
    }
    return buffer.toString().trim();
  }

  static String _titleOf(String tool, AgentRiskLevel risk) {
    if (tool == 'run_terminal_command') return '执行终端命令';
    if (tool == 'terminal_send_input') return '向终端发送输入';
    if (tool == 'terminal_close') return '结束终端会话';
    if (tool == 'delete_file') return '删除文件';
    if (tool == 'git_checkout') return '切换 / 还原 Git 分支';
    if (tool == 'download') return '从网络下载文件';
    if (tool.startsWith(ExternalMcpManager.toolPrefix)) return '调用第三方 MCP 工具';
    if (tool.startsWith(ConnectorService.toolPrefix)) return '调用联网连接器';
    return '${risk.label}：$tool';
  }

  static bool _looksCritical(String command) {
    final lower = command.toLowerCase();
    for (final pattern in _criticalCommandPatterns) {
      if (pattern.hasMatch(lower)) return true;
    }
    return false;
  }

  static final List<RegExp> _criticalCommandPatterns = [
    RegExp(r'\brm\s+(-[a-z]*[rf][a-z]*\s+)+'),
    RegExp(r'\brm\s+-[a-z]*r'),
    RegExp(r'\bsudo\b'),
    RegExp(r'\bdoas\b'),
    RegExp(r'\bgit\s+push\b'),
    RegExp(r'\bgit\s+reset\s+--hard\b'),
    RegExp(r'\bgit\s+clean\s+-[a-z]*f'),
    RegExp(r'\bdd\s+'),
    RegExp(r'\bmkfs'),
    RegExp(r'\b(shutdown|reboot|halt|poweroff)\b'),
    RegExp(r'\bchmod\s+777\b'),
    RegExp(r'\bkill\s+-9\b'),
    RegExp(r'\bcurl\b[^|]*\|\s*(ba)?sh\b'),
    RegExp(r'\bwget\b[^|]*\|\s*(ba)?sh\b'),
    RegExp(r'>\s*/dev/(sd|nvme|disk)'),
    RegExp(r'\bremove-item\b.*-recurse'),
    RegExp(r'\bdel\s+/[sf]'),
    RegExp(r'\bformat\s+[a-z]:'),
    RegExp(r'\bdiskpart\b'),
  ];

  @visibleForTesting
  static bool looksCriticalForTest(String command) => _looksCritical(command);
}
