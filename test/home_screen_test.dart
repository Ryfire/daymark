import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daymark/db/database.dart';
import 'package:daymark/data/rewrite_prompts.dart';
import 'package:daymark/llm/llm_client.dart';
import 'package:daymark/llm/providers.dart';
import 'package:daymark/main.dart';
import 'package:daymark/providers.dart';

class FakeRewriteClient implements LlmClient {
  List<ChatMessage>? lastMessages;
  final List<String> chunks;

  FakeRewriteClient(
      {this.chunks = const ['Thursday evening — sitter 6–10pm\n',
        '• Dinner money on counter']});

  @override
  Future<List<String>> listModels() async => ['fake'];

  @override
  Future<String> complete({
    required List<ChatMessage> messages,
    String? model,
  }) async =>
      '';

  @override
  Stream<String> streamChat({
    required List<ChatMessage> messages,
    String? model,
  }) {
    lastMessages = messages;
    return Stream.fromIterable(chunks);
  }

  @override
  void close() {}
}

NoteRow note(String id, String content, int createdAt) => NoteRow(
      id: id,
      content: content,
      createdAt: createdAt,
      pinned: false,
      colorIndex: 0,
      reminderAt: 0,
      reminderSilent: false,
      repeatDays: 0,
      done: false,
      editedAt: 0,
      source: 'jotlock_json',
      batchId: 'b',
      importedAt: 1,
    );

/// Seeds the in-memory db, renders the real app shell over a static
/// notes stream (live drift watch leaves a teardown timer that
/// fake_async flags), and hands the db back for assertions.
Future<AppDatabase> pumpHome(
  WidgetTester tester,
  List<NoteRow> notes, {
  FakeRewriteClient? client,
}) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  for (final row in notes) {
    await db.into(db.notes).insert(row);
  }

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      notesStreamProvider
          .overrideWith((ref) => Stream.value(notes)),
      rewritePromptsProvider
          .overrideWith((ref) => Stream.value(RewritePrompt.defaults)),
      if (client != null)
        llmClientProvider.overrideWith((ref) => client),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const DaymarkApp(),
    ),
  );
  await tester.pumpAndSettle();
  return db;
}

void main() {
  testWidgets('empty library shows the import guidance', (tester) async {
    // Plain stream override: the widget test verifies UI only; drift is
    // covered by the import service tests. (A live drift watch stream
    // leaves a zero-duration teardown timer that fake_async flags.)
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notesStreamProvider
              .overrideWith((ref) => Stream.value(const <NoteRow>[])),
        ],
        child: const DaymarkApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No notes yet'), findsOneWidget);
    expect(find.byIcon(Icons.file_open_outlined), findsNWidgets(2));
  });

  testWidgets('delete all notes empties the library after confirmation',
      (tester) async {
    final db = await pumpHome(tester, [
      note('a', 'costco run', 1000),
      note('b', 'sitter thu 6-10pm', 2000),
    ]);

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete all notes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete all'));
    await tester.pumpAndSettle();

    expect(await db.select(db.notes).get(), isEmpty);
    expect(find.textContaining('Deleted 2 notes'), findsOneWidget);
  });

  testWidgets('cancel on the delete-all dialog keeps every note',
      (tester) async {
    final db = await pumpHome(tester, [note('a', 'costco run', 1000)]);

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete all notes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(await db.select(db.notes).get(), hasLength(1));
  });

  testWidgets('delete note removes a single note from the detail screen',
      (tester) async {
    final db = await pumpHome(tester, [
      note('a', 'costco run', 1000),
      note('b', 'sitter thu 6-10pm', 2000),
    ]);

    await tester.tap(find.text('costco run'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Note options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete note'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    final remaining = await db.select(db.notes).get();
    expect(remaining.map((n) => n.id), ['b']);
    expect(find.textContaining('Note deleted'), findsOneWidget);
  });

  testWidgets('cancel on the single-note dialog keeps the note',
      (tester) async {
    final db = await pumpHome(tester, [note('a', 'costco run', 1000)]);

    await tester.tap(find.text('costco run'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Note options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete note'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(await db.select(db.notes).get(), hasLength(1));
  });

  testWidgets('long-press opens the quick rewrite sheet and rewrites',
      (tester) async {
    final db = await pumpHome(
      tester,
      [note('a', 'costco run', 1000)],
      client: FakeRewriteClient(),
    );

    await tester.longPress(find.text('costco run'));
    await tester.pumpAndSettle();

    expect(find.text('Quick rewrite'), findsOneWidget);
    expect(find.text('Improve readability'), findsOneWidget);

    await tester.tap(find.text('Improve readability'));
    await tester.pumpAndSettle();

    expect(find.text('Original'), findsOneWidget);
    expect(find.text('Rewritten'), findsOneWidget);
    expect(find.textContaining('Dinner money on counter'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Discard'));
    await tester.pumpAndSettle();

    final row = await (db.select(db.notes)
          ..where((n) => n.id.equals('a')))
        .getSingle();
    expect(row.content, 'costco run');
    expect(row.editedAt, 0);
  });

  testWidgets('replace from the rewrite flow offers an UNDO snackbar',
      (tester) async {
    final db = await pumpHome(
      tester,
      [note('a', 'costco run', 1000)],
      client: FakeRewriteClient(),
    );

    await tester.longPress(find.text('costco run'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Improve readability'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Replace'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Replace'),
      ),
    );
    await tester.pumpAndSettle();

    final replaced = await (db.select(db.notes)
          ..where((n) => n.id.equals('a')))
        .getSingle();
    expect(replaced.content, contains('Dinner money on counter'));
    expect(replaced.originalContent, 'costco run');

    await tester.tap(find.text('UNDO'));
    await tester.pumpAndSettle();

    final reverted = await (db.select(db.notes)
          ..where((n) => n.id.equals('a')))
        .getSingle();
    expect(reverted.content, 'costco run');
    expect(reverted.editedAt, 0);
    expect(reverted.originalContent, isNull);
  });
}
