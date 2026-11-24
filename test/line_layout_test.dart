import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipe_editor/widgets/editor/line_layout.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const style = TextStyle(fontSize: 14);

  test('无软换行时行偏移等距', () {
    final layout = computeLineLayout(
      text: 'a\nb\nc',
      style: style,
      maxWidth: 1000,
    );

    expect(layout.lineCount, 3);
    expect(layout.wrapped, isFalse);
    expect(layout.tops.length, 3);
    expect(layout.tops[0], 0);
    for (var i = 1; i < layout.tops.length; i++) {
      expect(
        layout.tops[i] - layout.tops[i - 1],
        closeTo(layout.lineHeight, 0.01),
      );
    }
  });

  test('长行软换行时标记 wrapped', () {
    final layout = computeLineLayout(
      text: 'x' * 120,
      style: style,
      maxWidth: 120,
    );

    expect(layout.lineCount, 1);
    expect(layout.wrapped, isTrue);
    expect(layout.tops.length, 1);
  });

  test('软换行时后续行偏移被放大', () {
    final layout = computeLineLayout(
      text: 'short\n${'x' * 120}\nend',
      style: style,
      maxWidth: 120,
    );

    expect(layout.lineCount, 3);
    expect(layout.wrapped, isTrue);
    expect(layout.tops.length, 3);
    // 第二行是长行，软换行后把第三行推得更远
    expect(
      layout.tops[2] - layout.tops[1],
      greaterThan(layout.lineHeight * 1.5),
    );
  });

  test('空文本按一行处理', () {
    final layout = computeLineLayout(
      text: '',
      style: style,
      maxWidth: 1000,
    );

    expect(layout.lineCount, 1);
    expect(layout.wrapped, isFalse);
    expect(layout.tops, [0.0]);
  });
}
