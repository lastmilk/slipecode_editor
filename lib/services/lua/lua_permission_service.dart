import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/plugin.dart';
import '../app_globals.dart';

const editorModifySafetyDeclaration =
    '允许插件修改编辑器可能导致不可预知的崩溃及隐私泄露，请确保你信任本插件，'
    'SLIPE不对本插件造成的损失负任何责任';

enum LuaPermissionStatus { none, granted, denied }

class LuaPermissionRequest {
  const LuaPermissionRequest({required this.plugin, required this.reason});

  final InstalledPlugin plugin;
  final String reason;
}

/// editor.modify 的用户授权由 Dart 持有，Lua 无法自行写入或绕过。
class LuaPermissionService extends ChangeNotifier {
  LuaPermissionService._();

  static final LuaPermissionService instance = LuaPermissionService._();

  final Map<String, bool> _decisions = {};
  final Map<String, Future<bool>> _pending = {};
  Future<void>? _loading;

  /// 测试可替换对话框；生产始终使用宿主安全声明。
  Future<bool> Function(LuaPermissionRequest request)? dialogHandler;

  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return;
      raw.forEach((key, value) {
        if (value is bool) _decisions[key] = value;
      });
    } catch (e) {
      debugPrint('读取 Lua 插件授权失败：$e');
    }
  }

  String _key(InstalledPlugin plugin) {
    final lua = plugin.luaManifest;
    if (lua == null || plugin.contentHash.isEmpty) return '';
    return '${lua.id}|${lua.api}|editor.modify|${plugin.contentHash}';
  }

  LuaPermissionStatus status(InstalledPlugin plugin) {
    final decision = _decisions[_key(plugin)];
    if (decision == null) return LuaPermissionStatus.none;
    return decision ? LuaPermissionStatus.granted : LuaPermissionStatus.denied;
  }

  bool isGranted(InstalledPlugin plugin) =>
      status(plugin) == LuaPermissionStatus.granted;

  /// pluginhook.init 的唯一入口；拒绝默认持久化，重载不会反复打扰用户。
  Future<bool> requestEditorModify(
    InstalledPlugin plugin, {
    String? reason,
    bool askAgain = false,
  }) async {
    await ensureLoaded();
    final lua = plugin.luaManifest;
    if (lua == null || !lua.requestsEditorModify) return false;
    final key = _key(plugin);
    if (key.isEmpty) return false;
    final existing = _decisions[key];
    if (existing != null && !askAgain) return existing;
    final pending = _pending[key];
    if (pending != null) return pending;

    final future = _ask(
      LuaPermissionRequest(
        plugin: plugin,
        reason: reason ?? lua.editorModifyReason() ?? '',
      ),
    );
    _pending[key] = future;
    try {
      final allowed = await future;
      _decisions[key] = allowed;
      await _save();
      notifyListeners();
      return allowed;
    } finally {
      _pending.remove(key);
    }
  }

  Future<bool> _ask(LuaPermissionRequest request) async {
    final handler = dialogHandler;
    if (handler != null) return handler(request);
    await WidgetsBinding.instance.endOfFrame;
    final navigator = appNavigatorKey.currentState;
    if (navigator == null) return false;
    final lua = request.plugin.luaManifest!;
    final context = navigator.context;
    if (!context.mounted) return false;
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.warning_amber, color: Colors.orange),
            title: Text('是否允许 ${lua.name} 修改当前编辑器？'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('插件：${lua.name} ${lua.version}\n发布者：${lua.publisher}'),
                  if (request.reason.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text('声明用途：${request.reason}'),
                  ],
                  const SizedBox(height: 16),
                  const Text(
                    editorModifySafetyDeclaration,
                    style: TextStyle(height: 1.5, color: Colors.orange),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('拒绝'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('允许修改'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> revoke(String pluginId) async {
    await ensureLoaded();
    _decisions.removeWhere((key, _) => key.startsWith('$pluginId|'));
    await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.$pid.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(_decisions),
      flush: true,
    );
    await temporary.rename(file.path);
  }

  Future<File> _file() async {
    final support = await getApplicationSupportDirectory();
    return File(p.join(support.path, 'lua_grants.json'));
  }
}
