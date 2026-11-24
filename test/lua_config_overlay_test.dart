import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slipe_editor/providers/settings_provider.dart';
import 'package:slipe_editor/services/desktop_prefs_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Lua 覆盖应用设置，但 setter 与持久化只修改基础值', () async {
    SharedPreferences.setMockInitialValues({});
    final provider = SettingsProvider();
    await provider.load();
    await provider.setEditorFontSize(13);

    provider.applyLuaOverrides({
      'editor.fontSize': 18,
      'editor.completionEnabled': false,
      'view.themeMode': 'dark',
    });

    expect(provider.settings.editorFontSize, 18);
    expect(provider.settings.completionEnabled, isFalse);
    expect(provider.settings.themeMode, ThemeMode.dark);
    expect(provider.baseSettings.editorFontSize, 13);

    await provider.setEditorFontSize(12);
    await provider.setCompletionEnabled(true);
    expect(provider.settings.editorFontSize, 18);
    expect(provider.settings.completionEnabled, isFalse);
    expect(provider.baseSettings.editorFontSize, 12);
    expect(provider.baseSettings.completionEnabled, isTrue);

    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString('slipe_app_settings')!) as Map;
    expect(saved['editorFontSize'], 12);
    expect(saved['completionEnabled'], isTrue);
    expect(saved['themeMode'], 'system');

    provider.applyLuaOverrides(const {});
    expect(provider.settings.editorFontSize, 12);
    expect(provider.settings.completionEnabled, isTrue);
    expect(provider.settings.themeMode, ThemeMode.system);
  });

  test('桌面偏好 getter 使用覆盖值，setter 保留基础值', () {
    final prefs = DesktopPrefsService.instance;
    prefs.applyLuaOverrides(const {});
    prefs.windowWidth = 1200;
    prefs.soloLayout = false;
    prefs.lspEnabled = true;

    prefs.applyLuaOverrides({
      'view.windowWidth': 1500,
      'view.soloLayout': true,
      'lsp.enabled': false,
    });
    expect(prefs.windowWidth, 1500);
    expect(prefs.soloLayout, isTrue);
    expect(prefs.lspEnabled, isFalse);

    prefs.windowWidth = 1300;
    prefs.soloLayout = true;
    prefs.lspEnabled = false;
    expect(prefs.windowWidth, 1500);
    expect(prefs.soloLayout, isTrue);
    expect(prefs.lspEnabled, isFalse);

    prefs.applyLuaOverrides(const {});
    expect(prefs.windowWidth, 1300);
    expect(prefs.soloLayout, isTrue);
    expect(prefs.lspEnabled, isFalse);
  });
}
