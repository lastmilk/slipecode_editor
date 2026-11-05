import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../payloads/loader/loader_payload.dart';

/// 用户自定义 Payload 的本地仓库。
///
/// 设计约束：Root Payload 只能由官方定义；System / Block Payload 允许用户自建、
/// 编辑、删除，并在设计稿编排器、Loader 构建流程与社区发布中直接使用。
/// 自定义数据持久化在 SharedPreferences，并注入到两个注册表（builtin + custom）。
class CustomPayloadService extends ChangeNotifier {
  CustomPayloadService._();

  static final CustomPayloadService instance = CustomPayloadService._();

  static const _systemKey = 'slipe_custom_system_payloads';
  static const _blockKey = 'slipe_custom_block_payloads';

  final List<SystemPayloadSpec> _systems = [];
  final List<BlockPayloadSpec> _blocks = [];
  bool _loaded = false;

  bool get isLoaded => _loaded;

  List<SystemPayloadSpec> get systemPayloads => List.unmodifiable(_systems);
  List<BlockPayloadSpec> get blockPayloads => List.unmodifiable(_blocks);

  int get totalCount => _systems.length + _blocks.length;

  Future<void> init() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _readSystems(prefs.getString(_systemKey));
    _readBlocks(prefs.getString(_blockKey));
    _syncRegistries();
    _loaded = true;
    notifyListeners();
  }

  SystemPayloadSpec? findSystem(String id) {
    for (final spec in _systems) {
      if (spec.id == id) return spec;
    }
    return null;
  }

  BlockPayloadSpec? findBlock(String id) {
    for (final spec in _blocks) {
      if (spec.id == id) return spec;
    }
    return null;
  }

  Future<void> upsertSystem(SystemPayloadSpec spec) async {
    final index = _systems.indexWhere((s) => s.id == spec.id);
    if (index == -1) {
      _systems.insert(0, spec);
    } else {
      _systems[index] = spec;
    }
    await _afterChange();
  }

  Future<void> upsertBlock(BlockPayloadSpec spec) async {
    final index = _blocks.indexWhere((b) => b.id == spec.id);
    if (index == -1) {
      _blocks.insert(0, spec);
    } else {
      _blocks[index] = spec;
    }
    await _afterChange();
  }

  Future<void> removeSystem(String id) async {
    _systems.removeWhere((s) => s.id == id);
    await _afterChange();
  }

  Future<void> removeBlock(String id) async {
    _blocks.removeWhere((b) => b.id == id);
    await _afterChange();
  }

  /// 从社区下载的 System Payload 导入到本地（自动处理 id 冲突）
  Future<SystemPayloadSpec> importSystem(Map<String, dynamic> map) async {
    final parsed = SystemPayloadSpec.fromMap(map);
    final spec = _cloneSystem(parsed, _uniqueSystemId(parsed.id));
    await upsertSystem(spec);
    return spec;
  }

  /// 从社区下载的 Block Payload 导入到本地（自动处理 id 冲突）
  Future<BlockPayloadSpec> importBlock(Map<String, dynamic> map) async {
    final parsed = BlockPayloadSpec.fromMap(map);
    final spec = _cloneBlock(parsed, _uniqueBlockId(parsed.id));
    await upsertBlock(spec);
    return spec;
  }

  static String newId(String prefix) =>
      'user_${prefix}_${DateTime.now().microsecondsSinceEpoch}';

  // -------------------------------------------------------------------------
  // 内部实现
  // -------------------------------------------------------------------------

  String _uniqueSystemId(String desired) {
    var base = desired.trim();
    if (base.isEmpty || !base.startsWith('user_')) {
      base = newId('sys');
    }
    var id = base;
    var suffix = 1;
    while (SystemPayloadRegistry.isBuiltin(id) ||
        _systems.any((s) => s.id == id)) {
      id = '${base}_$suffix';
      suffix++;
    }
    return id;
  }

  String _uniqueBlockId(String desired) {
    var base = desired.trim();
    if (base.isEmpty || !base.startsWith('user_')) {
      base = newId('blk');
    }
    var id = base;
    var suffix = 1;
    while (BlockPayloadRegistry.isBuiltin(id) ||
        _blocks.any((b) => b.id == id)) {
      id = '${base}_$suffix';
      suffix++;
    }
    return id;
  }

  SystemPayloadSpec _cloneSystem(SystemPayloadSpec s, String id) =>
      SystemPayloadSpec(
        id: id,
        name: s.name,
        description: s.description,
        icon: s.icon,
        defaultFolder: s.defaultFolder,
        libraryOptions: s.libraryOptions,
        defaultLibrary: s.defaultLibrary,
        extraParams: s.extraParams,
      );

  BlockPayloadSpec _cloneBlock(BlockPayloadSpec b, String id) => BlockPayloadSpec(
        id: id,
        name: b.name,
        description: b.description,
        icon: b.icon,
        applicableSystems: b.applicableSystems,
        params: b.params,
        markdownTemplate: b.markdownTemplate,
      );

  void _readSystems(String? raw) {
    _systems.clear();
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final item in decoded) {
        if (item is Map) {
          _systems.add(
            SystemPayloadSpec.fromMap(item.cast<String, dynamic>()),
          );
        }
      }
    } catch (_) {
      // 忽略损坏的本地数据，避免阻断应用启动
      _systems.clear();
    }
  }

  void _readBlocks(String? raw) {
    _blocks.clear();
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final item in decoded) {
        if (item is Map) {
          _blocks.add(
            BlockPayloadSpec.fromMap(item.cast<String, dynamic>()),
          );
        }
      }
    } catch (_) {
      _blocks.clear();
    }
  }

  void _syncRegistries() {
    SystemPayloadRegistry.setCustom(_systems);
    BlockPayloadRegistry.setCustom(_blocks);
  }

  Future<void> _afterChange() async {
    _syncRegistries();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _systemKey,
      jsonEncode(_systems.map((s) => s.toMap()).toList()),
    );
    await prefs.setString(
      _blockKey,
      jsonEncode(_blocks.map((b) => b.toMap()).toList()),
    );
    notifyListeners();
  }
}
