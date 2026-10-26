// SlipCode Editor 基本测试
import 'package:flutter_test/flutter_test.dart';
import 'package:slipecode_editor/main.dart';
import 'package:slipecode_editor/providers/github_provider.dart';

void main() {
  testWidgets('App launches with HomeScreen', (WidgetTester tester) async {
    await tester.pumpWidget(SlipCodeApp(githubProvider: GitHubProvider()));
    await tester.pumpAndSettle();

    // 验证主页关键元素存在
    expect(find.text('创建新项目'), findsOneWidget);
    expect(find.text('打开已有项目'), findsOneWidget);
  });
}
