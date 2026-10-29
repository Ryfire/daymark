import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daymark/data/rewrite_prompts.dart';
import 'package:daymark/llm/providers.dart';
import 'package:daymark/ui/playground_screen.dart';
import 'package:daymark/ui/settings_screen.dart';

void main() {
  testWidgets('settings screen renders empty form when unconfigured',
      (tester) async {
    // Plain constant streams avoid the drift teardown-timer problem that
    // live query streams trigger under fake_async.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          llmConfigProvider.overrideWith((ref) => Stream.value(null)),
          rewritePromptsProvider
              .overrideWith((ref) => Stream.value(RewritePrompt.defaults)),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('LLM provider'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Base URL'), findsOneWidget);
    expect(find.text('API key (optional)'), findsOneWidget);
    expect(find.text('Save provider'), findsOneWidget);
    expect(find.text('Test connection'), findsOneWidget);
    expect(find.text('Fetch'), findsOneWidget);
    expect(find.textContaining('Active:'), findsNothing);
  });

  testWidgets('playground shows configure prompt when unconfigured',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          llmConfigProvider.overrideWith((ref) => Stream.value(null)),
        ],
        child: const MaterialApp(home: PlaygroundScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No LLM provider configured'), findsOneWidget);
    expect(find.text('Configure provider'), findsOneWidget);
  });
}
