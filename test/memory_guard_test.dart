import 'package:flutter_test/flutter_test.dart';
import 'package:slipe_editor/services/memory_guard_service.dart';

void main() {
  group('MemoryThresholds.from', () {
    test('按物理内存百分比换算阈值', () {
      const total = 16 * 1024 * 1024 * 1024; // 16 GiB
      final thresholds = MemoryThresholds.from(
        totalBytes: total,
        warnPercent: 60,
        exitPercent: 80,
      );
      expect(thresholds.warnBytes, total * 60 ~/ 100);
      expect(thresholds.exitBytes, total * 80 ~/ 100);
    });

    test('退出阈值始终高于提醒阈值', () {
      final thresholds = MemoryThresholds.from(
        totalBytes: 1000,
        warnPercent: 60,
        exitPercent: 50, // 低于提醒，应被抬到 warn+1
      );
      expect(thresholds.exitBytes, greaterThan(thresholds.warnBytes));
    });

    test('百分比越界时被夹取', () {
      final low = MemoryThresholds.from(
        totalBytes: 1000,
        warnPercent: -10,
        exitPercent: 5,
      );
      // warn 最低 10%
      expect(low.warnBytes, 100);

      final high = MemoryThresholds.from(
        totalBytes: 1000,
        warnPercent: 99,
        exitPercent: 999,
      );
      // exit 最高 100%，且必须 > warn
      expect(high.exitBytes, 1000);
      expect(high.warnBytes, lessThanOrEqualTo(high.exitBytes));
    });

    test('物理内存为 0 时不产生负值', () {
      final thresholds = MemoryThresholds.from(
        totalBytes: 0,
        warnPercent: 60,
        exitPercent: 80,
      );
      expect(thresholds.warnBytes, 0);
      expect(thresholds.exitBytes, 0);
    });
  });
}
