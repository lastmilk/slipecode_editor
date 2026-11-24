import 'package:flutter_test/flutter_test.dart';
import 'package:slipe_editor/services/desktop_prefs_service.dart';

void main() {
  group('normalizeHubExitMode', () {
    test('合法值原样返回', () {
      expect(normalizeHubExitMode('close'), 'close');
      expect(normalizeHubExitMode('ask'), 'ask');
    });

    test('历史值 hide 与非法值统一回落到 close', () {
      expect(normalizeHubExitMode('hide'), 'close');
      expect(normalizeHubExitMode(''), 'close');
      expect(normalizeHubExitMode('unknown'), 'close');
    });
  });

  group('parseAiPanelWidth', () {
    test('读取新字段 aiPanelWidth', () {
      expect(parseAiPanelWidth({'aiPanelWidth': 420}), 420);
    });

    test('兼容旧字段 soloPanelWidth', () {
      expect(parseAiPanelWidth({'soloPanelWidth': 380}), 380);
    });

    test('新字段优先于旧字段', () {
      expect(
        parseAiPanelWidth({'aiPanelWidth': 500, 'soloPanelWidth': 380}),
        500,
      );
    });

    test('支持字符串数值', () {
      const raw = {'aiPanelWidth': '350'};
      expect(parseAiPanelWidth(raw), 350.0);
    });

    test('下界夹取到 280', () {
      expect(parseAiPanelWidth({'aiPanelWidth': 100}), 280);
    });

    test('上界夹取到 720', () {
      expect(parseAiPanelWidth({'aiPanelWidth': 9999}), 720);
    });

    test('缺省时使用 fallback', () {
      expect(parseAiPanelWidth({}, fallback: 360), 360);
      expect(parseAiPanelWidth({'aiPanelWidth': 'not-a-number'}), 360);
    });
  });
}
