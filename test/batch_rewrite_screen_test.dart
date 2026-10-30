import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daymark/data/jotlock_send.dart';
import 'package:daymark/data/rewrite_prompts.dart';
import 'package:daymark/db/database.dart';
import 'package:daymark/llm/llm_client.dart';
import 'package:daymark/llm/providers.dart';
import 'package:daymark/providers.dart';
import 'package:daymark/ui/batch_rewrite_screen.dart';

class FakeBatchClient implements LlmClient {
  final bool fail;

  FakeBatchClient({this.fail = false});

  @override
  Future<List<String>> listModels() async => ['fake'];

  @override
  Future<String> complete({
    required List<ChatMessage> messages,
    String? model,
  }) async => '';

  @override
  Stream<String> streamChat({
    required List<ChatMessage> messages,
    String? model,
  }) => fail
      ? Stream.error(const LlmApiException(500))
      : Stream.fromIterable(const ['Tidied text for: ', 'the note']);

  @override
  void close() {}
}

/// Mock for the `daymark/outgoing` platform side; records sent texts.
class FakeOutgoingChannel {
  final List<String> sent = [];

  late final MethodChannel channel = MethodChannel('test/outgoing');

  void install() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'sendNote') {
            sent.add(call.arguments['text'] as String);
            return true;
          }
          return null;
        });
  }
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
  importedAt: 0,
);

Future<(AppDatabase, FakeOutgoingChannel?)> pumpBatch(
  WidgetTester tester, {
  required List<NoteRow> notes,
  FakeBatchClient? client,
  FakeOutgoingChannel? outgoing,
}) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  for (final row in notes) {
    await db.into(db.notes).insert(row);
  }
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      llmClientProvider.overrideWith((ref) => client ?? FakeBatchClient()),
      if (outgoing != null)
        jotlockSenderProvider.overrideWithValue(
          JotlockSender(channel: outgoing.channel),
        ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(key: Key('home'))),
    ),
  );
  tester
      .state<NavigatorState>(find.byType(Navigator))
      .push(
        MaterialPageRoute(
          builder: (_) => BatchRewriteScreen(
            notes: notes,
            prompt: RewritePrompt.defaults.first,
          ),
        ),
      );
  await tester.pumpAndSettle();
  return (db, outgoing);
}

void main() {
  testWidgets('streams each note in order and keep saves a new one', (
    tester,
  ) async {
    final (db, _) = await pumpBatch(
      tester,
      notes: [note('a', 'costco run', 1000), note('b', 'walk the dog', 2000)],
    );

    // First note streams and offers the decision.
    expect(find.textContaining('Tidied text for: the note'), findsOneWidget);
    expect(find.text('Keep'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Keep'));
    await tester.pumpAndSettle();

    // Second note streams right away — the fake stream completes within
    // the settle, so it is already ready to review.
    expect(find.text('Ready to review'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Keep'));
    await tester.pumpAndSettle();

    final rows = await db.select(db.notes).get();
    expect(rows, hasLength(4)); // 2 originals + 2 kept as new
    expect(
      rows.where((r) => r.source == 'daymark_ai').map((r) => r.content),
      everyElement(contains('Tidied text')),
    );
    expect(find.textContaining('2 of 2 decided'), findsOneWidget);
  });

  testWidgets('skip leaves the note untouched and moves on', (tester) async {
    final (db, _) = await pumpBatch(
      tester,
      notes: [note('a', 'costco run', 1000)],
    );

    await tester.tap(find.widgetWithText(OutlinedButton, 'Skip'));
    await tester.pumpAndSettle();

    expect(await db.select(db.notes).get(), hasLength(1));
    expect(find.text('Skipped'), findsOneWidget);
  });

  testWidgets('kept rewrites go to JotLock one share at a time', (
    tester,
  ) async {
    final outgoing = FakeOutgoingChannel()..install();
    final (db, _) = await pumpBatch(
      tester,
      notes: [note('a', 'costco run', 1000)],
      outgoing: outgoing,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Keep'));
    await tester.pumpAndSettle();

    // Session complete: the send bar appears.
    await tester.tap(find.widgetWithText(FilledButton, 'Send to JotLock (1)'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pumpAndSettle();

    expect(outgoing.sent, hasLength(1));
    expect(outgoing.sent.single, contains('Tidied text'));
    expect(find.textContaining('Opened in JotLock'), findsOneWidget);
    // The queue marks the item as sent.
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    // Originals untouched by any of this.
    final rows = await db.select(db.notes).get();
    expect(rows.where((r) => r.source == 'jotlock_json'), hasLength(1));
  });

  testWidgets('errors offer retry or skip and never write', (tester) async {
    final (db, _) = await pumpBatch(
      tester,
      notes: [note('a', 'costco run', 1000), note('b', 'walk the dog', 2000)],
      client: FakeBatchClient(fail: true),
    );

    expect(find.textContaining('Server error (HTTP 500)'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Skip'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Skip'));
    await tester.pumpAndSettle();

    expect(await db.select(db.notes).get(), hasLength(2));
    // Nothing kept, so sending is disabled.
    final sendButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Send to JotLock (0)'),
    );
    expect(sendButton.onPressed, isNull);
  });
}
