import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daymark/db/database.dart';
import 'package:daymark/llm/llm_client.dart';
import 'package:daymark/llm/llm_config.dart';
import 'package:daymark/llm/providers.dart';
import 'package:daymark/providers.dart';
import 'package:daymark/tts/speech.dart';
import 'package:daymark/ui/ask_screen.dart';

class FakeGroundedClient implements LlmClient {
  List<ChatMessage>? lastMessages;
  final String reply;

  FakeGroundedClient({this.reply = 'The tomatoes were planted [n1].'});

  @override
  Future<List<String>> listModels() async => ['fake'];

  @override
  Future<String> complete({required List<ChatMessage> messages,
      String? model}) async =>
      '';

  @override
  Stream<String> streamChat({required List<ChatMessage> messages,
      String? model}) {
    lastMessages = messages;
    return Stream.fromIterable([reply]);
  }

  @override
  void close() {}
}

class FakeSpeech implements SpeechController {
  final speaks = <String>[];

  @override
  Future<void> speak(String text, {double rate = 0.5}) async =>
      speaks.add(text);

  @override
  Future<void> stop() async {}
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

/// Setup mirroring tts_test's proven pattern: in-memory drift db closed
/// via a local teardown, autoplay key pre-written (the settings watch then
/// settles with a row instead of tearing down mid-absence), speech
/// provider overridden so no platform plugin is constructed.
Future<void> pumpAsk(
  WidgetTester tester, {
  required LlmClient client,
  bool autoplay = false,
}) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);

  final speech = FakeSpeech();
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      notesStreamProvider.overrideWith(
        (ref) => Stream.value([
          note('t1', 'planted tomatoes in the garden', 1730000000000),
          note('t2', 'bought milk', 1730000000001),
        ]),
      ),
      llmConfigProvider.overrideWith(
        (ref) => Stream.value(
          const LlmConfig(baseUrl: 'http://fake/v1', model: 'fake'),
        ),
      ),
      llmClientProvider.overrideWith((ref) => client),
      speechProvider.overrideWith((ref) => speech),
    ],
  );
  addTearDown(container.dispose);

  await container
      .read(settingsRepositoryProvider)
      .setString(ttsAutoplayKey, autoplay ? '1' : '0');

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: AskScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('ask screen grounds the question in the imported notes',
      (tester) async {
    final client = FakeGroundedClient();
    await pumpAsk(tester, client: client);

    await tester.enterText(find.byType(TextField), 'when did I plant tomatoes');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    expect(find.textContaining('The tomatoes were planted'), findsOneWidget);

    final messages = client.lastMessages!;
    expect(messages.first.role, 'system');
    expect(messages.first.content, contains('planted tomatoes in the garden'));
    expect(messages.first.content, contains('[n1]'));
    expect(messages.any((m) => m.role == 'user' &&
        m.content == 'when did I plant tomatoes'), isTrue);

    // The Sources row maps the cited id to the real note.
    expect(find.text('Sources'), findsOneWidget);
    expect(find.textContaining('n1 · Oct'), findsOneWidget);

    // Tapping the chip opens the full note screen.
    await tester.tap(find.textContaining('n1 · Oct'));
    await tester.pumpAndSettle();
    expect(find.text('Created'), findsOneWidget);
  });

  testWidgets('a reply without citations shows no Sources row',
      (tester) async {
    final client = FakeGroundedClient(reply: 'I have no idea, sorry.');
    await pumpAsk(tester, client: client);

    await tester.enterText(find.byType(TextField), 'anything at all');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    expect(find.textContaining('I have no idea'), findsOneWidget);
    expect(find.text('Sources'), findsNothing);
  });
}
