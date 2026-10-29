import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daymark/data/rewrite_prompts.dart';
import 'package:daymark/db/database.dart';
import 'package:daymark/llm/llm_config.dart';
import 'package:daymark/llm/providers.dart';
import 'package:daymark/providers.dart';
import 'package:daymark/ui/settings_screen.dart';

/// Renders the settings screen over a real in-memory db with the
/// defaults pre-written (a live settings watch that starts on an empty
/// key leaves a teardown timer that fake_async flags).
Future<AppDatabase> pumpSettings(WidgetTester tester) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  await db.into(db.appSettings).insert(
        AppSettingsCompanion.insert(
          key: RewritePrompt.settingsKey,
          value: encodeRewritePrompts(RewritePrompt.defaults),
        ),
      );
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      llmConfigProvider.overrideWith((ref) => Stream.value(null as LlmConfig?)),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return db;
}

Future<void> _openPromptDialog(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(OutlinedButton, 'Add prompt'));
  await tester.pumpAndSettle();
}

Future<void> _closePromptDialog(WidgetTester tester) async {
  await tester.tap(
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(FilledButton, 'Save'),
    ),
  );
  await tester.pumpAndSettle();
}

/// The prompt section sits at the bottom of a long ListView; scroll it
/// into view (scrollUntilVisible chokes on the TextField scrollables).
Future<void> _scrollToPrompt(WidgetTester tester, Finder target) async {
  for (var i = 0; i < 10; i++) {
    if (target.evaluate().isNotEmpty) return;
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('add prompt dialog saves a new quick-rewrite prompt',
      (tester) async {
    final db = await pumpSettings(tester);

    await _scrollToPrompt(tester, find.text('Improve readability'));
    expect(find.text('Improve readability'), findsOneWidget);

    await _scrollToPrompt(tester, find.text('Add prompt'));
    await _openPromptDialog(tester);
    await tester.enterText(
      find.widgetWithText(TextField, 'Label'),
      'Expand abbreviations',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'What the model should do with the note'),
      'Expand every abbreviation into a full word.',
    );
    await _closePromptDialog(tester);

    expect(find.text('Expand abbreviations'), findsOneWidget);
    final stored = await (db.select(db.appSettings)
          ..where((s) => s.key.equals(RewritePrompt.settingsKey)))
        .getSingle();
    final saved = parseRewritePrompts(stored.value)!;
    expect(saved, hasLength(5));
    expect(
      saved.any((p) => p.label == 'Expand abbreviations'),
      isTrue,
    );
  });

  testWidgets('editing an existing prompt replaces it in place',
      (tester) async {
    final db = await pumpSettings(tester);

    await _scrollToPrompt(tester, find.text('Improve readability'));
    await tester.tap(find.text('Improve readability'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Label'),
      'Polish',
    );
    await _closePromptDialog(tester);

    expect(find.text('Polish'), findsOneWidget);
    final stored = await (db.select(db.appSettings)
          ..where((s) => s.key.equals(RewritePrompt.settingsKey)))
        .getSingle();
    final saved = parseRewritePrompts(stored.value)!;
    expect(saved, hasLength(4));
    expect(saved.where((p) => p.id == 'improve').single.label, 'Polish');
  });

  testWidgets('deleting a prompt removes it and restore defaults brings '
      'the originals back', (tester) async {
    final db = await pumpSettings(tester);

    await _scrollToPrompt(tester, find.byTooltip('Delete prompt'));
    await tester.tap(find.byTooltip('Delete prompt').first);
    await tester.pumpAndSettle();
    expect(find.text('Improve readability'), findsNothing);

    await tester.tap(find.text('Restore defaults'));
    await tester.pumpAndSettle();
    expect(find.text('Improve readability'), findsOneWidget);

    final stored = await (db.select(db.appSettings)
          ..where((s) => s.key.equals(RewritePrompt.settingsKey)))
        .getSingle();
    expect(parseRewritePrompts(stored.value), hasLength(4));
  });
}
