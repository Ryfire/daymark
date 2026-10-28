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

class ScriptedClient implements LlmClient {
  final List<ChatMessage>? lastMessages;
  ScriptedClient({this.lastMessages});

  @override
  Future<List<String>> listModels() async => ['fake'];

  @override
  Future<String> complete(
      {required List<ChatMessage> messages, String? model}) async =>
      '';

  @override
  Stream<String> streamChat(
      {required List<ChatMessage> messages, String? model}) {
    return Stream.fromIterable(['Answer one. ', 'Answer two.']);
  }

  @override
  void close() {}
}

class ErrorClient implements LlmClient {
  @override
  Future<List<String>> listModels() async => ['fake'];

  @override
  Future<String> complete(
      {required List<ChatMessage> messages, String? model}) async =>
      '';

  @override
  Stream<String> streamChat(
      {required List<ChatMessage> messages, String? model}) {
    return Stream<String>.error(LlmNetworkException('offline'));
  }

  @override
  void close() {}
}

class FakeSpeech implements SpeechController {
  final speaks = <String>[];
  final rates = <double>[];
  var stops = 0;

  @override
  Future<void> speak(String text, {double rate = 0.5}) async {
    speaks.add(text);
    rates.add(rate);
  }

  @override
  Future<void> stop() async => stops++;
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
      source: 'jotlock_json',
      batchId: 'b',
      importedAt: 1,
    );

Future<ProviderContainer> pumpAsk(
  WidgetTester tester, {
  required LlmClient client,
  required SpeechController speech,
  bool autoplay = false,
}) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      notesStreamProvider.overrideWith(
        (ref) => Stream.value([note('t1', 'planted tomatoes', 1730000000000)]),
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
  return container;
}

void main() {
  testWidgets('autoplay speaks the finished reply when enabled',
      (tester) async {
    final speech = FakeSpeech();
    await pumpAsk(
      tester,
      client: ScriptedClient(),
      speech: speech,
      autoplay: true,
    );

    await tester.enterText(find.byType(TextField), 'anything');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    expect(speech.speaks, ['Answer one. Answer two.']);
    expect(speech.rates, [0.5]);
  });

  testWidgets('speech speed sheet persists a new rate', (tester) async {
    final speech = FakeSpeech();
    final container = await pumpAsk(
      tester,
      client: ScriptedClient(),
      speech: speech,
      autoplay: false,
    );

    await tester.tap(find.byTooltip('Speech speed'));
    await tester.pumpAndSettle();
    expect(find.text('Speech speed'), findsOneWidget);

    await tester.drag(find.byType(Slider), const Offset(400, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final stored = await container
        .read(settingsRepositoryProvider)
        .getString(ttsRateKey);
    expect(stored, '1.00');
  });

  testWidgets('autoplay off means nothing is spoken', (tester) async {
    final speech = FakeSpeech();
    await pumpAsk(
      tester,
      client: ScriptedClient(),
      speech: speech,
      autoplay: false,
    );

    await tester.enterText(find.byType(TextField), 'anything');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    expect(speech.speaks, isEmpty);
  });

  testWidgets('tapping a completed assistant reply speaks it', (tester) async {
    final speech = FakeSpeech();
    await pumpAsk(
      tester,
      client: ScriptedClient(),
      speech: speech,
      autoplay: false,
    );

    await tester.enterText(find.byType(TextField), 'anything');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    speech.speaks.clear();
    await tester.tap(find.byTooltip('Speak'));
    await tester.pumpAndSettle();

    expect(speech.speaks, ['Answer one. Answer two.']);
  });

  testWidgets('tapping a user bubble never speaks', (tester) async {
    final speech = FakeSpeech();
    await pumpAsk(
      tester,
      client: ScriptedClient(),
      speech: speech,
      autoplay: false,
    );

    await tester.enterText(find.byType(TextField), 'anything');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    speech.speaks.clear();
    await tester.tap(find.text('anything'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(speech.speaks, isEmpty);
  });

  testWidgets('error bubbles are never spoken, even tapped', (tester) async {
    final speech = FakeSpeech();
    await pumpAsk(
      tester,
      client: ErrorClient(),
      speech: speech,
      autoplay: true,
    );

    await tester.enterText(find.byType(TextField), 'anything');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    // The error bubble stays visible and offers no speaker button.
    expect(find.textContaining('⚠'), findsOneWidget);
    expect(find.byTooltip('Speak'), findsNothing);
    expect(speech.speaks, isEmpty);
  });
}
