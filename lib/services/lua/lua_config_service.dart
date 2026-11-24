import 'package:flutter/foundation.dart';

class LuaConfigContribution {
  const LuaConfigContribution({
    required this.pluginId,
    required this.source,
    this.values = const {},
    this.keymap = const {},
  });

  final String pluginId;
  final String source;
  final Map<String, Object?> values;
  final Map<String, String?> keymap;
}

class LuaConfigSetting {
  const LuaConfigSetting({
    required this.value,
    required this.pluginId,
    required this.source,
  });

  final Object? value;
  final String pluginId;
  final String source;
}

/// Lua 是内存中的最后覆盖层，不回写 SharedPreferences 或 desktop_prefs.json。
class LuaConfigService extends ChangeNotifier {
  LuaConfigService({bool Function(String pluginId)? hasConfigurationCapability})
    : _hasConfigurationCapability =
          hasConfigurationCapability ?? ((_) => false);

  static const userConfigId = 'user';

  final bool Function(String pluginId) _hasConfigurationCapability;
  final Map<String, LuaConfigSetting> _settings = {};
  final Map<String, String?> _keymap = {};
  int _generation = 0;

  int get generation => _generation;
  Map<String, LuaConfigSetting> get settings => Map.unmodifiable(_settings);
  Map<String, String?> get keymap => Map.unmodifiable(_keymap);

  bool isOverridden(String key) => _settings.containsKey(key);
  String? sourceOf(String key) => _settings[key]?.source;
  Object? valueOf(String key) => _settings[key]?.value;

  void replaceAll(Iterable<LuaConfigContribution> contributions) {
    final settings = <String, LuaConfigSetting>{};
    final keymap = <String, String?>{};
    for (final contribution in contributions) {
      if (contribution.pluginId != userConfigId &&
          !_hasConfigurationCapability(contribution.pluginId)) {
        throw LuaConfigException(
          '插件 ${contribution.pluginId} 未声明 configuration 能力',
        );
      }
      for (final entry in contribution.values.entries) {
        _validate(entry.key, entry.value);
        if (contribution.pluginId != userConfigId &&
            (entry.key == 'view.windowWidth' ||
                entry.key == 'view.windowHeight')) {
          throw const LuaConfigException('第三方插件不能修改启动窗口尺寸');
        }
        settings[entry.key] = LuaConfigSetting(
          value: entry.value,
          pluginId: contribution.pluginId,
          source: contribution.source,
        );
      }
      for (final entry in contribution.keymap.entries) {
        if (entry.key.trim().isEmpty) {
          throw const LuaConfigException('键位覆盖缺少 command id');
        }
        keymap[entry.key] = entry.value;
      }
    }
    _settings
      ..clear()
      ..addAll(settings);
    _keymap
      ..clear()
      ..addAll(keymap);
    _generation++;
    notifyListeners();
  }

  void clear() => replaceAll(const []);

  static void _validate(String key, Object? value) {
    final expected = _types[key];
    if (expected == null) throw LuaConfigException('不允许 Lua 配置项：$key');
    final valid = switch (expected) {
      'double' => value is num && value.isFinite,
      'bool' => value is bool,
      'string' => value is String,
      _ => false,
    };
    if (!valid) throw LuaConfigException('$key 的值类型必须为 $expected');
    if (key == 'editor.fontSize' && (value as num) < 11 ||
        key == 'editor.fontSize' && (value as num) > 22) {
      throw const LuaConfigException('editor.fontSize 必须在 11 到 22 之间');
    }
    if ((key == 'view.aiPanelWidth' && (value as num) < 280) ||
        (key == 'view.aiPanelWidth' && (value as num) > 720) ||
        (key == 'view.windowWidth' && (value as num) < 1024) ||
        (key == 'view.windowHeight' && (value as num) < 680)) {
      throw LuaConfigException('$key 超出允许范围');
    }
    if (key == 'view.themeMode' &&
        !{'system', 'light', 'dark'}.contains(value)) {
      throw const LuaConfigException('view.themeMode 仅支持 system/light/dark');
    }
    if (key == 'view.language' && !{'zh', 'zhHant', 'en'}.contains(value)) {
      throw const LuaConfigException('view.language 仅支持 zh/zhHant/en');
    }
  }

  static const _types = {
    'editor.fontSize': 'double',
    'editor.fontFamily': 'string',
    'editor.completionEnabled': 'bool',
    'view.themeMode': 'string',
    'view.language': 'string',
    'view.soloLayout': 'bool',
    'view.sidebarVisible': 'bool',
    'view.panelVisible': 'bool',
    'view.aiPanelWidth': 'double',
    'view.windowWidth': 'double',
    'view.windowHeight': 'double',
    'lsp.enabled': 'bool',
    'terminal.fontSize': 'double',
  };
}

class LuaConfigException implements Exception {
  const LuaConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}
