import 'package:drift/drift.dart' show Value;
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
import 'package:daymark/ui/note_detail_screen.dart';
import 'package:daymark/ui/note_rewrite_screen.dart';

class FakeRewriteClient implements LlmClient {
  List<ChatMessage>? lastMessages;
  final List<String> chunks;
  final bool fail;

  FakeRewriteClient({
    this.chunks = const ['Thursday evening — sitter 6–10pm\n',
      '• Dinner money on counter'],
    this.fail = false,
  });

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
    return fail ? Stream.error(const LlmApiException(500))
        : Stream.fromIterable(chunks);
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

/// Mock for the `daymark/outgoing` platform side: records sent notes and
/// (for the About page) opened URLs; [sendError] makes sendNote fail.
class FakeOutgoingChannel {
  final List<String> sent = [];
  final List<String> opened = [];
  Object? sendError;

  late final MethodChannel channel = MethodChannel('test/outgoing');

  void install() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'sendNote':
          final error = sendError;
          if (error is PlatformException) throw error;
          sent.add(call.arguments['text'] as String);
          return true;
        case 'getVersionName':
          return '0.1.0';
        case 'openUrl':
          opened.add(call.arguments['url'] as String);
          return true;
        default:
          return null;
      }
    });
  }
}

/// In-memory db with the note pre-inserted, then the rewrite screen pushed
/// on top of a placeholder route so pops behave like the real app.
Future<(AppDatabase, FakeRewriteClient)> pumpRewrite(
  WidgetTester tester, {
  FakeRewriteClient? client,
  FakeOutgoingChannel? outgoing,
}) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final fake = client ?? FakeRewriteClient();
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      llmClientProvider.overrideWith((ref) => fake),
      if (outgoing != null)
        jotlockSenderProvider.overrideWithValue(
          JotlockSender(channel: outgoing.channel),
        ),
    ],
  );
  addTearDown(container.dispose);

  final n = note('n1', 'sitter thu 6-10pm - dinner money on counter', 1000);
  await db.into(db.notes).insert(n);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(key: Key('home'))),
    ),
  );
  tester
      .state<NavigatorState>(find.byType(Navigator))
      .push(MaterialPageRoute(
        builder: (_) =>
            NoteRewriteScreen(note: n, prompt: RewritePrompt.defaults.first),
      ));
  await tester.pumpAndSettle();
  return (db, fake);
}

void main() {
  testWidgets('streams the rewrite and replaces the note with revert data',
      (tester) async {
    final (db, client) = await pumpRewrite(tester);

    expect(find.textContaining('Dinner money on counter'), findsOneWidget);
    // One user message carrying prompt + note content.
    expect(client.lastMessages, hasLength(1));
    expect(
      client.lastMessages!.first.content,
      contains('sitter thu 6-10pm'),
    );

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
          ..where((n) => n.id.equals('n1')))
        .getSingle();
    expect(replaced.content, contains('Dinner money on counter'));
    expect(replaced.editedAt, greaterThan(0));
    expect(
      replaced.originalContent,
      'sitter thu 6-10pm - dinner money on counter',
    );

    // The UNDO snackbar restores the original in one tap.
    await tester.tap(find.text('UNDO'));
    await tester.pumpAndSettle();
    final reverted = await (db.select(db.notes)
          ..where((n) => n.id.equals('n1')))
        .getSingle();
    expect(reverted.content, 'sitter thu 6-10pm - dinner money on counter');
    expect(reverted.editedAt, 0);
    expect(reverted.originalContent, isNull);
  });

  testWidgets('save as new keeps the original note untouched',
      (tester) async {
    final (db, _) = await pumpRewrite(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Save as new'));
    await tester.pumpAndSettle();

    final rows = await db.select(db.notes).get();
    expect(rows, hasLength(2));
    expect(
      rows.singleWhere((r) => r.id != 'n1').content,
      contains('Dinner money on counter'),
    );
    final created = rows.singleWhere((r) => r.id != 'n1');
    expect(created.source, 'daymark_ai');
    expect(
      rows.singleWhere((r) => r.id == 'n1').content,
      'sitter thu 6-10pm - dinner money on counter',
    );
  });

  testWidgets('copy puts the rewritten text on the clipboard',
      (tester) async {
    String? clipboardText;
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboardText = call.arguments['text'] as String?;
      }
      return null;
    });

    await pumpRewrite(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Copy'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Copied to clipboard'), findsOneWidget);
    expect(clipboardText, contains('Dinner money on counter'));
  });

  testWidgets('discard leaves the note unchanged', (tester) async {
    final (db, _) = await pumpRewrite(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Discard'));
    await tester.pumpAndSettle();

    final row = await (db.select(db.notes)
          ..where((n) => n.id.equals('n1')))
        .getSingle();
    expect(row.content, 'sitter thu 6-10pm - dinner money on counter');
    expect(row.editedAt, 0);
  });

  testWidgets('send to jotlock hands the rewrite to the platform channel',
      (tester) async {
    final outgoing = FakeOutgoingChannel()..install();
    final (db, _) = await pumpRewrite(tester, outgoing: outgoing);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Send to JotLock'));
    await tester.pumpAndSettle();

    expect(outgoing.sent, hasLength(1));
    expect(outgoing.sent.single, contains('Dinner money on counter'));
    expect(find.textContaining('Opened in JotLock'), findsOneWidget);
    // Append-only: the library itself is untouched by the send.
    expect((await db.select(db.notes).get()), hasLength(1));
  });

  testWidgets('send failure degrades to a snackbar', (tester) async {
    final outgoing = FakeOutgoingChannel()
      ..install()
      ..sendError = PlatformException(
          code: 'no_jotlock', message: 'JotLock is not installed');
    final (db, _) = await pumpRewrite(tester, outgoing: outgoing);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Send to JotLock'));
    await tester.pumpAndSettle();

    expect(find.text('JotLock is not installed'), findsOneWidget);
    expect((await db.select(db.notes).get()), hasLength(1));
  });

  testWidgets('stream errors surface and keep the note untouched',
      (tester) async {
    final (db, _) = await pumpRewrite(
      tester,
      client: FakeRewriteClient(fail: true),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Server error (HTTP 500)'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Copy'), findsNothing);
    expect(find.text('Replace'), findsNothing);
    final row = await (db.select(db.notes)
          ..where((n) => n.id.equals('n1')))
        .getSingle();
    expect(row.content, 'sitter thu 6-10pm - dinner money on counter');
  });

  testWidgets('the note screen shows the Edited line and can revert',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    final edited = note(
      'n1',
      'Thursday evening — sitter 6–10pm',
      1000,
    ).copyWith(editedAt: 5000, originalContent: Value('sitter thu 6-10pm'));
    await db.into(db.notes).insert(edited);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(key: Key('home'))),
      ),
    );
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .push(MaterialPageRoute(
          builder: (_) => NoteDetailScreen(note: edited),
        ));
    await tester.pumpAndSettle();

    expect(find.text('Edited'), findsOneWidget);
    expect(find.text('Created in Daymark'), findsNothing);

    await tester.tap(find.byTooltip('Note options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Revert to original'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Revert'),
      ),
    );
    await tester.pumpAndSettle();

    final reverted = await (db.select(db.notes)
          ..where((n) => n.id.equals('n1')))
        .getSingle();
    expect(reverted.content, 'sitter thu 6-10pm');
    expect(reverted.editedAt, 0);
    expect(reverted.originalContent, isNull);
  });
}
