import 'package:flutter_test/flutter_test.dart';

import 'package:daymark/data/jotlock_backup.dart';

void main() {
  group('parseJotlockBackup', () {
    test('parses a minimal note with jotlock defaults', () {
      final result = parseJotlockBackup(
        '[{"id":"a","text":"hello","createdAt":1737500000000}]',
      );
      expect(result.malformed, 0);
      final note = result.notes.single;
      expect(note.id, 'a');
      expect(note.text, 'hello');
      expect(note.createdAt.millisecondsSinceEpoch, 1737500000000);
      expect(note.pinned, isFalse);
      expect(note.colorIndex, 0);
      expect(note.reminderAt, 0);
      expect(note.reminderSilent, isFalse);
      expect(note.repeatDays, 0);
      expect(note.done, isFalse);
      expect(note.hasReminder, isFalse);
      expect(note.isRecurring, isFalse);
    });

    test('parses every field when present', () {
      final result = parseJotlockBackup('''
        [{
          "id": "b",
          "text": "[ ] milk\\n[x] eggs",
          "createdAt": 1737500000000,
          "pinned": true,
          "color": 3,
          "reminderAt": 1737600000000,
          "reminderSilent": true,
          "repeatDays": 7,
          "done": true
        }]
      ''');
      expect(result.malformed, 0);
      final note = result.notes.single;
      expect(note.pinned, isTrue);
      expect(note.colorIndex, 3);
      expect(note.reminderAt, 1737600000000);
      expect(note.reminderSilent, isTrue);
      expect(note.repeatDays, 7);
      expect(note.done, isTrue);
      expect(note.hasReminder, isTrue);
      expect(note.isRecurring, isTrue);
      expect(note.reminderTime.millisecondsSinceEpoch, 1737600000000);
    });

    test('ignores unknown fields', () {
      final result = parseJotlockBackup(
        '[{"id":"a","text":"x","createdAt":1,"futureField":{"nested":true}}]',
      );
      expect(result.malformed, 0);
      expect(result.notes.single.text, 'x');
    });

    test('counts malformed entries and keeps valid ones', () {
      final result = parseJotlockBackup(
        '[42, null, {"id":"","text":"no id"}, {"text":"no id at all"}, '
        '{"id":"ok","text":"fine","createdAt":5}]',
      );
      expect(result.malformed, 4);
      expect(result.notes.map((n) => n.id), ['ok']);
    });

    test('a wrong-type field skips the entry, not the import', () {
      final result = parseJotlockBackup(
        '[{"id":"bad","text":"x","createdAt":1,"pinned":"yes"}, '
        '{"id":"good","text":"y","createdAt":2}]',
      );
      expect(result.malformed, 1);
      expect(result.notes.single.id, 'good');
    });

    test('throws BackupFormatException on non-array JSON', () {
      expect(
        () => parseJotlockBackup('{"id":"a"}'),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('throws BackupFormatException on invalid JSON', () {
      expect(
        () => parseJotlockBackup('not json at all'),
        throwsA(isA<BackupFormatException>()),
      );
    });
  });
}
