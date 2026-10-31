import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daymark/data/jotlock_send.dart';
import 'package:daymark/db/database.dart';
import 'package:daymark/providers.dart';
import 'package:daymark/ui/note_detail_screen.dart';

NoteRow note(
  String id,
  String content,
  int createdAt, {
  String source = 'jotlock_json',
  String batchId = 'b',
  int editedAt = 0,
  String? originalContent,
}) =>
    NoteRow(
      id: id,
      content: content,
      createdAt: createdAt,
      pinned: false,
      colorIndex: 0,
      reminderAt: 0,
      reminderSilent: false,
      repeatDays: 0,
      done: false,
      editedAt: editedAt,
      originalContent: originalContent,
      source: source,
      batchId: batchId,
      importedAt: 1,
    );

/// Mock for the `daymark/outgoing` platform side: records sent notes and
/// shared texts; [sendError] / [shareError] make the calls fail.
class FakeOutgoingChannel {
  final List<String> sent = [];
  final List<String> shared = [];
  Object? sendError;
  Object? shareError;

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
        case 'shareText':
          final error = shareError;
          if (error is PlatformException) throw error;
          shared.add(call.arguments['text'] as String);
          return true;
        default:
          return null;
      }
    });
  }
}

Future<void> pumpDetail(
  WidgetTester tester,
  NoteRow row, {
  FakeOutgoingChannel? outgoing,
}) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
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
      .push(MaterialPageRoute(
        builder: (_) => NoteDetailScreen(note: row),
      ));
  await tester.pumpAndSettle();
}

Future<void> openMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Note options'));
  await tester.pumpAndSettle();
}

void main() {
  const content = 'rewritten sitter note text';

  testWidgets('a saved-as-new note offers share actions from its details',
      (tester) async {
    final outgoing = FakeOutgoingChannel()..install();
    await pumpDetail(
      tester,
      note('n1', content, 1000, source: 'daymark_ai', batchId: 'daymark-ai'),
      outgoing: outgoing,
    );

    await openMenu(tester);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Send to JotLock'), findsOneWidget);
    expect(find.text('Delete note'), findsOneWidget);
    expect(find.text('Revert to original'), findsNothing);

    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    expect(outgoing.shared, [content]);

    await openMenu(tester);
    await tester.tap(find.text('Send to JotLock'));
    await tester.pumpAndSettle();
    expect(outgoing.sent, [content]);
    expect(
      find.text('Opened in JotLock — tap Save to keep it'),
      findsOneWidget,
    );
  });

  testWidgets('an imported note keeps its menu without share actions',
      (tester) async {
    await pumpDetail(tester, note('n1', content, 1000));

    await openMenu(tester);
    expect(find.text('Copy'), findsNothing);
    expect(find.text('Share'), findsNothing);
    expect(find.text('Send to JotLock'), findsNothing);
    expect(find.text('Delete note'), findsOneWidget);
    expect(find.text('Revert to original'), findsNothing);
  });

  testWidgets('a replaced saved-as-new note keeps share actions and gains '
      'Revert', (tester) async {
    await pumpDetail(
      tester,
      note(
        'n1',
        content,
        1000,
        source: 'daymark_ai',
        batchId: 'daymark-ai',
        editedAt: 5000,
        originalContent: 'original text',
      ),
    );

    expect(find.text('Edited'), findsOneWidget);
    await openMenu(tester);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Send to JotLock'), findsOneWidget);
    expect(find.text('Revert to original'), findsOneWidget);
    expect(find.text('Delete note'), findsOneWidget);
  });

  testWidgets('share failure surfaces a snackbar', (tester) async {
    final outgoing = FakeOutgoingChannel()
      ..install()
      ..shareError = PlatformException(code: 'share_failed');
    await pumpDetail(
      tester,
      note('n1', content, 1000, source: 'daymark_ai', batchId: 'daymark-ai'),
      outgoing: outgoing,
    );

    await openMenu(tester);
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();

    expect(find.text('Could not share'), findsOneWidget);
  });
}