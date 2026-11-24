import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipe_editor/widgets/desktop/desktop_shell.dart';

/// 桌面外壳的命中测试回归：AI 面板是叠加层，绝不能吞掉编辑区与侧栏的点击，
/// 并且 IDE ⇄ SOLO 切换后动画必须收敛（否则会饿死输入）。
Future<void> pumpShell(
  WidgetTester tester, {
  required bool aiPanelOnLeft,
  required List<String> taps,
  bool showActivityBar = true,
  bool sidebarVisible = true,
  bool sidebarOnRight = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: DesktopShell(
          menus: const [],
          projectName: 'demo',
          activityBar: SizedBox(
            width: 48,
            child: TextButton(
              key: const ValueKey('activity'),
              onPressed: () => taps.add('activity'),
              child: const Text('A'),
            ),
          ),
          sidebar: ColoredBox(
            color: const Color(0xFFEEEEEE),
            child: TextButton(
              key: const ValueKey('sidebar'),
              onPressed: () => taps.add('sidebar'),
              child: const Text('S'),
            ),
          ),
          sidebarVisible: sidebarVisible,
          sidebarWidth: 240,
          onSidebarResize: (_) {},
          editor: Center(
            child: TextButton(
              key: const ValueKey('editor'),
              onPressed: () => taps.add('editor'),
              child: const Text('E'),
            ),
          ),
          bottomPanel: null,
          panelVisible: false,
          panelHeight: 200,
          onPanelResize: (_) {},
          statusBar: const SizedBox(height: 22),
          aiPanel: ColoredBox(
            color: const Color(0xFFFAFAFA),
            child: Center(
              child: TextButton(
                key: const ValueKey('ai'),
                onPressed: () => taps.add('ai'),
                child: const Text('I'),
              ),
            ),
          ),
          aiPanelOnLeft: aiPanelOnLeft,
          aiPanelWidth: 320,
          onAiResize: (_) {},
          showActivityBar: showActivityBar,
          sidebarOnRight: sidebarOnRight,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('IDE 布局：编辑区、侧栏、AI 面板都可点击', (tester) async {
    final taps = <String>[];
    await pumpShell(tester, aiPanelOnLeft: false, taps: taps);

    await tester.tap(find.byKey(const ValueKey('editor')));
    await tester.tap(find.byKey(const ValueKey('ai')));
    await tester.tap(find.byKey(const ValueKey('activity')));
    await tester.tap(find.byKey(const ValueKey('sidebar')));

    expect(taps, containsAll(<String>['editor', 'ai', 'activity', 'sidebar']));
  });

  testWidgets('SOLO 布局：AI 在左、文件侧栏镜像到右侧且都可点击', (tester) async {
    final taps = <String>[];
    await pumpShell(
      tester,
      aiPanelOnLeft: true,
      taps: taps,
      sidebarOnRight: true,
    );

    await tester.tap(find.byKey(const ValueKey('editor')));
    await tester.tap(find.byKey(const ValueKey('ai')));
    await tester.tap(find.byKey(const ValueKey('activity')));
    await tester.tap(find.byKey(const ValueKey('sidebar')));

    expect(taps, containsAll(<String>['editor', 'ai', 'activity', 'sidebar']));

    final aiRect = tester.getRect(find.byKey(const ValueKey('ai')));
    final editorRect = tester.getRect(find.byKey(const ValueKey('editor')));
    final activityRect = tester.getRect(find.byKey(const ValueKey('activity')));
    final sidebarRect = tester.getRect(find.byKey(const ValueKey('sidebar')));

    // AI 在编辑区左侧；文件树与活动栏在编辑区右侧
    expect(aiRect.right, lessThanOrEqualTo(editorRect.left));
    expect(sidebarRect.left, greaterThanOrEqualTo(editorRect.right));
    expect(activityRect.left, greaterThanOrEqualTo(sidebarRect.right));
  });

  testWidgets('AI 面板不会覆盖编辑区', (tester) async {
    final taps = <String>[];
    await pumpShell(tester, aiPanelOnLeft: false, taps: taps);

    final aiRect = tester.getRect(find.byKey(const ValueKey('ai')));
    final editorRect = tester.getRect(find.byKey(const ValueKey('editor')));

    expect(aiRect.width, lessThanOrEqualTo(320));
    expect(editorRect.width, greaterThan(0));
    expect(editorRect.right, lessThanOrEqualTo(aiRect.left));
  });

  testWidgets('IDE ⇄ SOLO 切换后动画能收敛', (tester) async {
    final taps = <String>[];
    await pumpShell(tester, aiPanelOnLeft: false, taps: taps);

    await pumpShell(
      tester,
      aiPanelOnLeft: true,
      taps: taps,
      sidebarOnRight: true,
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );

    await pumpShell(tester, aiPanelOnLeft: false, taps: taps);
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
  });
}
