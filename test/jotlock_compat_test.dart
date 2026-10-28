import 'package:flutter_test/flutter_test.dart';

import 'package:daymark/core/jotlock_compat.dart';

void main() {
  test('checklist parsing matches jotlock line syntax', () {
    final items = checklistItems('buy milk\n[ ] a\n  [x] b\n[X] c\nplain');
    expect(items.map((i) => i.lineIndex), [1, 2, 3]);
    expect(items.map((i) => i.checked), [false, true, true]);
    expect(items.map((i) => i.label), ['a', 'b', 'c']);
  });

  test('checklistItemAt returns null for plain lines', () {
    expect(checklistItemAt('hello\n[ ] item', 0), isNull);
    expect(checklistItemAt('hello\n[ ] item', 1)?.label, 'item');
    expect(checklistItemAt('hello', 5), isNull);
  });

  test('checklistProgress counts checked vs total', () {
    expect(checklistProgress('[ ] a\n[x] b\n[x] c'), (2, 3));
    expect(checklistProgress('no checklist here'), (0, 0));
  });

  test('repeatLabel mirrors jotlock', () {
    expect(repeatLabel(0), '');
    expect(repeatLabel(1), 'daily');
    expect(repeatLabel(7), 'weekly');
    expect(repeatLabel(3), 'every 3 days');
  });
}
