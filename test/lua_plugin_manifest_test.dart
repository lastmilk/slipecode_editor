import 'package:flutter_test/flutter_test.dart';
import 'package:slipe_editor/models/lua_plugin.dart';

void main() {
  const valid = '''
<?xml version="1.0" encoding="UTF-8"?>
<plugin id="example.aop" name="AOP" version="1.2.3" publisher="SLIPE" api="1">
  <entry>main.lua</entry>
  <config>config.lua</config>
  <capabilities>
    <capability name="editor.modify" reason="增强补全" />
    <capability name="events" />
  </capabilities>
</plugin>
''';

  test('解析 metadata.xml 与高风险能力', () {
    final manifest = LuaPluginManifest.fromXml(valid);
    expect(manifest.id, 'example.aop');
    expect(manifest.entry, 'main.lua');
    expect(manifest.config, 'config.lua');
    expect(manifest.requestsEditorModify, isTrue);
    expect(manifest.editorModifyReason(), '增强补全');
    expect(
      LuaPluginManifest.fromJson(manifest.toJson()).toJson(),
      manifest.toJson(),
    );
  });

  test('缺少 id 或 entry 时拒绝', () {
    expect(
      () => LuaPluginManifest.fromXml(
        '<plugin name="x" version="1.0.0" api="1"><entry>main.lua</entry></plugin>',
      ),
      throwsA(isA<LuaPluginFormatException>()),
    );
    expect(
      () => LuaPluginManifest.fromXml(
        '<plugin id="x" name="x" version="1.0.0" api="1" />',
      ),
      throwsA(isA<LuaPluginFormatException>()),
    );
  });

  test('未知能力、重复能力和无理由的 editor.modify 会失败', () {
    expect(
      () => LuaPluginManifest.fromXml(
        '<plugin id="x" name="x" version="1.0.0" api="1"><entry>main.lua</entry>'
        '<capabilities><capability name="native.exec" /></capabilities></plugin>',
      ),
      throwsA(isA<LuaPluginFormatException>()),
    );
    expect(
      () => LuaPluginManifest.fromXml(
        '<plugin id="x" name="x" version="1.0.0" api="1"><entry>main.lua</entry>'
        '<capabilities><capability name="events" /><capability name="events" />'
        '</capabilities></plugin>',
      ),
      throwsA(isA<LuaPluginFormatException>()),
    );
    expect(
      () => LuaPluginManifest.fromXml(
        '<plugin id="x" name="x" version="1.0.0" api="1"><entry>main.lua</entry>'
        '<capabilities><capability name="editor.modify" /></capabilities></plugin>',
      ),
      throwsA(isA<LuaPluginFormatException>()),
    );
  });

  test('入口不能是绝对路径、路径穿越或非 Lua 文件', () {
    for (final entry in ['/tmp/a.lua', '../a.lua', 'lib/../a.lua', 'main.js']) {
      expect(
        () => LuaPluginManifest.fromXml(
          '<plugin id="x" name="x" version="1.0.0" api="1">'
          '<entry>$entry</entry></plugin>',
        ),
        throwsA(isA<LuaPluginFormatException>()),
        reason: entry,
      );
    }
  });

  test('API major 不兼容时拒绝', () {
    expect(
      () => LuaPluginManifest.fromXml(
        '<plugin id="x" name="x" version="1.0.0" api="2"><entry>main.lua</entry></plugin>',
      ),
      throwsA(isA<LuaPluginFormatException>()),
    );
  });
}
