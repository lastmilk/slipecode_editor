import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slipe_editor/providers/editor_provider.dart';

Future<EditorProvider> _providerWithFile(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final dir = Directory.systemTemp.createTempSync('slipe-editor-provider-');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  final file = File('${dir.path}/a.dart')..writeAsStringSync('original');

  final provider = EditorProvider();
  addTearDown(provider.dispose);
  // 真实文件读取需要 runAsync，否则会卡在 fake async 时钟里
  final opened = await tester.runAsync(() => provider.openFile(file.path));
  expect(opened, isNotNull);
  return provider;
}

void main() {
  testWidgets('连续更新内容时通知被节流', (tester) async {
    await tester.pumpWidget(const SizedBox());
    final provider = await _providerWithFile(tester);

    var notifications = 0;
    provider.addListener(() => notifications++);

    for (var i = 0; i < 10; i++) {
      provider.updateActiveContent('content-$i');
    }

    // 内容立即生效，但只有第一次触发同步通知
    expect(provider.activeFile!.content, 'content-9');
    expect(notifications, 1);

    // 尾随通知在节流窗口结束后补发一次
    await tester.pump(const Duration(milliseconds: 130));
    expect(notifications, 2);
  });

  testWidgets('单次更新立即通知', (tester) async {
    await tester.pumpWidget(const SizedBox());
    final provider = await _providerWithFile(tester);

    var notifications = 0;
    provider.addListener(() => notifications++);

    provider.updateActiveContent('changed');
    expect(provider.activeFile!.content, 'changed');
    expect(notifications, 1);

    await tester.pump(const Duration(milliseconds: 130));
    expect(notifications, 1);
  });
}
