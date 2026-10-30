import 'package:flutter_test/flutter_test.dart';

import 'package:daymark/core/dedupe.dart';
import 'package:daymark/db/database.dart';

NoteRow note(String id, String content) => NoteRow(
  id: id,
  content: content,
  createdAt: 0,
  pinned: false,
  colorIndex: 0,
  reminderAt: 0,
  reminderSilent: false,
  repeatDays: 0,
  done: false,
  editedAt: 0,
  source: 'jotlock_json',
  batchId: 'b',
  importedAt: 0,
);

void main() {
  group('normalizeForCompare', () {
    test('strips case, punctuation and collapsed whitespace', () {
      expect(
        normalizeForCompare('  Milk, 2% -- don\'t forget!!  '),
        'milk 2 don t forget',
      );
    });

    test('strips checklist markers', () {
      expect(normalizeForCompare('[x] Buy milk'), 'buy milk');
      expect(normalizeForCompare('[ ] call mom'), 'call mom');
    });

    test('blank text normalizes to empty', () {
      expect(normalizeForCompare('   '), '');
    });
  });

  group('similarity', () {
    test('identical text is 1.0', () {
      expect(similarity('sitter thu 6-10pm', 'sitter THU 6-10pm!'), 1.0);
    });

    test('disjoint text is 0.0', () {
      expect(similarity('buy milk', 'walk dog'), 0.0);
    });

    test('blank text never matches', () {
      expect(similarity('', 'buy milk'), 0.0);
    });
  });

  group('findDuplicateGroups', () {
    test('groups exact duplicates ignoring case and punctuation', () {
      final groups = findDuplicateGroups([
        note('a', 'Milk!'),
        note('b', 'milk'),
        note('c', 'buy milk'),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.map((n) => n.id), ['a', 'b']);
    });

    test('groups near-duplicates above the threshold', () {
      final groups = findDuplicateGroups([
        note('a', 'buy milk bread eggs saturday morning'),
        note('b', 'buy milk bread eggs saturday'),
      ]);
      expect(groups, hasLength(1));
    });

    test('keeps near-misses below the threshold apart', () {
      // 7 shared of 10 union = 0.70 — similar but not the same note.
      final groups = findDuplicateGroups([
        note('a', 'sitter thu 6-10pm, dinner money on counter'),
        note('b', 'sitter thursday 6-10pm dinner money on the counter'),
      ]);
      expect(groups, isEmpty);
    });

    test('keeps related-but-below-threshold notes apart', () {
      final groups = findDuplicateGroups([
        note('a', 'buy milk and bread'),
        note('b', 'buy milk and eggs'),
      ]);
      expect(groups, isEmpty);
    });

    test('keeps unrelated notes apart', () {
      final groups = findDuplicateGroups([
        note('a', 'costco run saturday'),
        note('b', 'rent due on the first'),
      ]);
      expect(groups, isEmpty);
    });

    test('checklist-marker differences still group', () {
      final groups = findDuplicateGroups([
        note('a', '[x] Buy milk'),
        note('b', 'Buy milk'),
      ]);
      expect(groups, hasLength(1));
    });

    test('never puts a note in two groups and skips blanks', () {
      final groups = findDuplicateGroups([
        note('a', 'gym 7am'),
        note('b', 'gym 7am!'),
        note('c', '   '),
        note('d', ''),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.map((n) => n.id), ['a', 'b']);
    });

    test('fewer than two comparable notes yields nothing', () {
      expect(findDuplicateGroups([note('a', 'solo note')]), isEmpty);
      expect(findDuplicateGroups(const []), isEmpty);
    });
  });
}
