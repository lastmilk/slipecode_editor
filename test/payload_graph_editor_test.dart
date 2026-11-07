// 有向图点选连线回归测试。
//
// 复现过的真实 bug：引脚视觉圆探出/越出节点卡片边界时，
// RenderBox.hitTest 的 size.contains 检查让引脚永远收不到点击，
// 移动端「点击起点 → 点击终点」完全失效。WidgetTester.tap 走真实命中测试，
// 若引脚退回界外此测试会立即失败。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipe_editor/models/design_draft.dart';
import 'package:slipe_editor/payloads/loader/loader_payload.dart';
import 'package:slipe_editor/widgets/payload_graph_editor.dart';

DesignDraft _buildDraft() => DesignDraft(
  id: 't',
  name: 't',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  root: RootPayloadInstance(specId: 'flutter_cloud'),
  systems: [
    SystemPayloadInstance(
      specId: 'portal',
      nodeId: 'n1',
      x: 40,
      y: 60,
      blocks: [
        BlockPayloadInstance(
          specId: BlockPayloadRegistry.forSystem('portal').first.id,
          instanceId: 'b1',
        ),
      ],
    ),
    SystemPayloadInstance(
      specId: 'console',
      nodeId: 'n2',
      x: 420,
      y: 220,
      blocks: [
        BlockPayloadInstance(
          specId: BlockPayloadRegistry.forSystem('console').first.id,
          instanceId: 'b2',
        ),
      ],
    ),
  ],
);

/// 按引脚圆点颜色找引脚（输出=orange，选中=deepOrange，输入=blueAccent）
Finder _pinByColor(Color color) => find.byWidgetPredicate(
  (w) =>
      w is AnimatedContainer &&
      w.decoration is BoxDecoration &&
      (w.decoration as BoxDecoration).color == color,
);

void main() {
  testWidgets('点击起点高亮，再点击终点完成连接', (tester) async {
    final draft = _buildDraft();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PayloadGraphEditor(draft: draft, onChanged: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 初始：2 个输出引脚、4 个输入引脚（2 System + 2 Block）
    expect(_pinByColor(Colors.orange), findsNWidgets(2));
    expect(_pinByColor(Colors.blueAccent), findsNWidgets(4));
    expect(draft.edges, isEmpty);

    // 1. 点击 n1 的输出引脚 → 选中起点：出现提示 + 变深橙色
    await tester.tap(_pinByColor(Colors.orange).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('已选中起点'), findsOneWidget);
    expect(_pinByColor(Colors.deepOrange), findsOneWidget);

    // 2. 点击 n2 一侧的输入引脚（取全局 x 较大者，避开 n1 自身）→ 完成连接
    final inputs = _pinByColor(Colors.blueAccent);
    Finder? target;
    for (var i = 0; i < 4; i++) {
      final f = inputs.at(i);
      if (tester.getCenter(f).dx > 300) {
        target = f;
        break;
      }
    }
    expect(target, isNotNull);
    await tester.tap(target!);
    await tester.pumpAndSettle();

    expect(draft.edges, hasLength(1));
    expect(draft.edges.single.fromNodeId, 'n1');
    expect(draft.edges.single.fromBlockId, 'b1');
    expect(draft.edges.single.toNodeId, 'n2');

    // 3. 起点状态已复位（没有残留的深橙引脚）
    expect(_pinByColor(Colors.deepOrange), findsNothing);
  });

  testWidgets('选中起点后点击画布空白可取消', (tester) async {
    final draft = _buildDraft();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PayloadGraphEditor(draft: draft, onChanged: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(_pinByColor(Colors.orange).first);
    await tester.pumpAndSettle();
    expect(_pinByColor(Colors.deepOrange), findsOneWidget);

    // 点击画布中部空白处（避开底部抽屉把手区域）→ 取消选中，无连线
    await tester.tapAt(const Offset(700, 250));
    await tester.pumpAndSettle();
    expect(_pinByColor(Colors.deepOrange), findsNothing);
    expect(draft.edges, isEmpty);
  });
}
