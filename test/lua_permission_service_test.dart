import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipe_editor/models/lua_plugin.dart';
import 'package:slipe_editor/models/plugin.dart';
import 'package:slipe_editor/services/lua/lua_permission_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('拒绝、重新授权、内容变化与撤销都按内容 hash 隔离', () async {
    final support = Directory.systemTemp.createTempSync('slipe-lua-grants-');
    addTearDown(() {
      LuaPermissionService.instance.dialogHandler = null;
      if (support.existsSync()) support.deleteSync(recursive: true);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => support.path,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          ),
    );

    final service = LuaPermissionService.instance;
    await service.ensureLoaded();
    final plugin = _plugin('hash-a');
    expect(service.status(plugin), LuaPermissionStatus.none);
    expect(
      editorModifySafetyDeclaration,
      '允许插件修改编辑器可能导致不可预知的崩溃及隐私泄露，请确保你信任本插件，SLIPE不对本插件造成的损失负任何责任',
    );

    var prompts = 0;
    LuaPermissionRequest? lastRequest;
    service.dialogHandler = (request) async {
      prompts++;
      lastRequest = request;
      return false;
    };
    expect(await service.requestEditorModify(plugin), isFalse);
    expect(service.status(plugin), LuaPermissionStatus.denied);
    expect(lastRequest!.reason, '测试修改授权');
    expect(await service.requestEditorModify(plugin), isFalse);
    expect(prompts, 1);

    service.dialogHandler = (_) async {
      prompts++;
      return true;
    };
    expect(await service.requestEditorModify(plugin, askAgain: true), isTrue);
    expect(service.isGranted(plugin), isTrue);
    expect(prompts, 2);

    final changed = _plugin('hash-b');
    expect(service.status(changed), LuaPermissionStatus.none);
    expect(service.isGranted(changed), isFalse);

    await service.revoke(plugin.manifest.id);
    expect(service.status(plugin), LuaPermissionStatus.none);
    expect(service.status(changed), LuaPermissionStatus.none);
  });
}

InstalledPlugin _plugin(String hash) {
  const lua = LuaPluginManifest(
    id: 'test.permission',
    name: 'Permission Test',
    version: '1.0.0',
    publisher: 'SLIPE',
    api: 1,
    entry: 'main.lua',
    capabilities: [
      LuaPluginCapability(name: 'editor.modify', reason: '测试修改授权'),
    ],
  );
  return InstalledPlugin(
    manifest: PluginManifest(id: lua.id, name: lua.name),
    directory: '/tmp/$hash',
    luaManifest: lua,
    contentHash: hash,
  );
}
