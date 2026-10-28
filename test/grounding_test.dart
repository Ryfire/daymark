import 'package:flutter_test/flutter_test.dart';

import 'package:daymark/db/database.dart';
import 'package:daymark/llm/grounding.dart';

NoteRow note(String id, String content, int createdAt,
        {bool pinned = false}) =>
    NoteRow(
      id: id,
      content: content,
      createdAt: createdAt,
      pinned: pinned,
      colorIndex: 0,
      reminderAt: 0,
      reminderSilent: false,
      repeatDays: 0,
      done: false,
      source: 'jotlock_json',
      batchId: 'batch1',
      importedAt: 1,
    );

void main() {
  group('queryTerms', () {
    test('keeps words of length 3+, lowercased', () {
      expect(
        queryTerms('When did I buy the Milk?'),
        {'when', 'did', 'buy', 'the', 'milk'},
      );
    });
  });

  group('selectContext', () {
    test('empty query returns all notes newest-first with citation ids',
        () {
      final selection = selectContext([
        note('old', 'older note', 1000),
        note('new', 'newer note', 2000),
      ], '');

      expect(selection.isTruncated, isFalse);
      expect(selection.notes.map((n) => n.note.id), ['new', 'old']);
      expect(selection.notes.map((n) => n.citationId), ['n1', 'n2']);
    });

    test('term matches are included, newer non-matching notes are not', () {
      final selection = selectContext([
        note('new', 'unrelated chatter about weather', 5000),
        note('old', 'planted tomatoes in the garden', 1000),
      ], 'tomatoes');

      expect(selection.notes.map((n) => n.note.id), ['old']);
      expect(selection.isTruncated, isTrue);
    });

    test('pinned boost decides inclusion when only one note fits', () {
      final selection = selectContext(
        [
          note('a', 'budget planning stuff', 2000),
          note('b', 'budget planning again', 1000, pinned: true),
        ],
        'budget',
        maxChars: 70,
      );

      expect(selection.notes.map((n) => n.note.id), ['b']);
    });

    test('zero matches falls back to newest-first recency fill', () {
      final selection = selectContext([
        note('a', 'grocery list', 1000),
        note('b', 'meeting notes', 2000),
      ], 'zzzq');

      expect(selection.notes.map((n) => n.note.id), ['b', 'a']);
      expect(selection.isTruncated, isFalse);
    });

    test('char budget truncates by relevance and flags it', () {
      final selection = selectContext(
        [
          note('a', 'x' * 500, 1000),
          note('b', 'needle here', 2000),
          note('c', 'y' * 500, 3000),
        ],
        'needle',
        maxChars: 600,
      );

      expect(selection.isTruncated, isTrue);
      expect(selection.totalNotes, 3);
      expect(selection.notes.map((n) => n.note.id), ['b']);
      expect(selection.usedChars, 'needle here'.length + 48);
    });

    test('the single best note is kept even if it alone exceeds budget',
        () {
      final selection = selectContext(
        [note('big', 'z' * 10000, 1000)],
        '',
        maxChars: 100,
      );

      expect(selection.notes, hasLength(1));
      expect(selection.usedChars, greaterThan(100));
    });
  });

  group('buildGroundedSystemPrompt', () {
    test('includes citation ids, dates, content and rules', () {
      final selection = selectContext([
        note('a', 'bought milk today', 1730000000000),
      ], 'milk');

      final prompt = buildGroundedSystemPrompt(selection);

      expect(prompt, contains('[n1]'));
      expect(prompt, contains('bought milk today'));
      expect(prompt, contains('Answer ONLY from the notes above'));
      expect(prompt, contains('Cite the notes'));
    });

    test('includes reminder metadata for one-shot reminders', () {
      final prompt = buildGroundedSystemPrompt(
        ContextSelection(
          notes: [
            ContextNote(
              citationId: 'n1',
              note: NoteRow(
                id: 'a',
                content: 'take vitamins',
                createdAt: 1730000000000,
                pinned: false,
                colorIndex: 0,
                reminderAt: 1800000000000,
                reminderSilent: false,
                repeatDays: 0,
                done: false,
                source: 'jotlock_json',
                batchId: 'b',
                importedAt: 1,
              ),
            ),
          ],
          totalNotes: 1,
          usedChars: 100,
        ),
      );

      expect(prompt, contains('(reminder:'));
    });
  });
}
