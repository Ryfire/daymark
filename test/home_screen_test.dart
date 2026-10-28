import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daymark/db/database.dart';
import 'package:daymark/main.dart';
import 'package:daymark/providers.dart';

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
}
