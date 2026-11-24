import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipe_editor/widgets/code_highlighter.dart';

void main() {
  testWidgets('文本未变时复用 TextSpan 缓存', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      Builder(
        builder: (ctx) {
          context = ctx;
          return const SizedBox();
        },
      ),
    );

    final controller = HighlightingController(
      text: 'void main() { print(1); }',
      language: 'dart',
      colors: SyntaxColors.of(isDark: true),
    );
    addTearDown(controller.dispose);
    const style = TextStyle(fontSize: 13);

    final first = controller.buildTextSpan(
      context: context,
      style: style,
      withComposing: false,
    );
    final second = controller.buildTextSpan(
      context: context,
      style: style,
      withComposing: false,
    );
    expect(identical(first, second), isTrue);

    controller.text = 'void main() { print(2); }';
    final third = controller.buildTextSpan(
      context: context,
      style: style,
      withComposing: false,
    );
    expect(identical(first, third), isFalse);
  });

  testWidgets('配色变化后缓存失效', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      Builder(
        builder: (ctx) {
          context = ctx;
          return const SizedBox();
        },
      ),
    );

    final controller = HighlightingController(
      text: 'final value = 1;',
      language: 'dart',
      colors: SyntaxColors.of(isDark: true),
    );
    addTearDown(controller.dispose);
    const style = TextStyle(fontSize: 13);

    final before = controller.buildTextSpan(
      context: context,
      style: style,
      withComposing: false,
    );
    controller.colors = SyntaxColors.of(isDark: false);
    final after = controller.buildTextSpan(
      context: context,
      style: style,
      withComposing: false,
    );

    expect(identical(before, after), isFalse);
  });
}
