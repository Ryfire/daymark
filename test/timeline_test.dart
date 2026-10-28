import 'package:flutter_test/flutter_test.dart';

import 'package:daymark/core/timeline.dart';

void main() {
  group('groupByDay', () {
    test('buckets by local calendar day, newest day first', () {
      final groups = groupByDay<int>(
        [
          make(2026, 10, 28, 9),
          make(2026, 10, 28, 8),
          make(2026, 10, 27, 23),
          make(2026, 10, 26, 12),
        ],
        (ms) => ms,
      );
      expect(groups.length, 3);
      expect(groups[0].day, DateTime(2026, 10, 28));
      expect(groups[0].items, [make(2026, 10, 28, 9), make(2026, 10, 28, 8)]);
      expect(groups[1].day, DateTime(2026, 10, 27));
      expect(groups[2].day, DateTime(2026, 10, 26));
    });
  });

  group('dayHeader', () {
    final now = DateTime(2026, 10, 28, 15);
    test('today and yesterday', () {
      expect(dayHeader(DateTime(2026, 10, 28), now: now), 'Today');
      expect(dayHeader(DateTime(2026, 10, 27), now: now), 'Yesterday');
    });
    test('this year and other years', () {
      expect(dayHeader(DateTime(2026, 3, 2), now: now), 'Mon, Mar 2');
      expect(dayHeader(DateTime(2024, 12, 30), now: now), 'Mon, Dec 30, 2024');
    });
  });

  test('formatTime pads and formatShort includes month/day', () {
    final dt = DateTime(2026, 10, 28, 9, 5);
    expect(formatTime(dt), '09:05');
    expect(formatShort(dt), 'Oct 28 · 09:05');
    expect(formatFull(dt), 'Wed, Oct 28, 2026 · 09:05');
  });
}

int make(int y, int m, int d, int h) =>
    DateTime(y, m, d, h).millisecondsSinceEpoch;
