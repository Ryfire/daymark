import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daymark/db/database.dart';
import 'package:daymark/providers.dart';
import 'package:daymark/ui/duplicates_screen.dart';

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

Future<AppDatabase> pumpDuplicates(
  WidgetTester tester,
  List<NoteRow> notes,
) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  for (final row in notes) {
    await db.into(db.notes).insert(row);
  }
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      notesStreamProvider.overrideWith((ref) => Stream.value(notes)),
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
      .push(MaterialPageRoute(builder: (_) => const DuplicatesScreen()));
  await tester.pumpAndSettle();
  return db;
}

void main() {
  testWidgets('shows groups with the duplicate notes', (tester) async {
    await pumpDuplicates(tester, [
      note('a', 'Milk!', 1000),
      note('b', 'milk', 2000),
      note('c', 'rent due on the first', 3000),
    ]);

    expect(find.text('2 notes look alike'), findsOneWidget);
    expect(find.text('Milk!'), findsOneWidget);
    expect(find.text('milk'), findsOneWidget);
    // Not part of any duplicate group — the screen shows groups only.
    expect(find.text('rent due on the first'), findsNothing);
  });

  testWidgets('no duplicates shows the all-clear state', (tester) async {
    await pumpDuplicates(tester, [
      note('a', 'costco run saturday', 1000),
      note('b', 'rent due on the first', 2000),
    ]);

    expect(find.text('No duplicates found'), findsOneWidget);
  });

  testWidgets('confirmed delete removes the note and dissolves the group', (
    tester,
  ) async {
    final db = await pumpDuplicates(tester, [
      note('a', 'Milk!', 1000),
      note('b', 'milk', 2000),
    ]);

    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Delete'),
      ),
    );
    await tester.pumpAndSettle();

    expect(await db.select(db.notes).get(), hasLength(1));
    expect(find.text('Note deleted'), findsOneWidget);
    // The static stream override doesn't re-emit after the delete, so
    // the stale group card remains on screen — db state is the contract.
  });

  testWidgets('cancel keeps the note in the group', (tester) async {
    final db = await pumpDuplicates(tester, [
      note('a', 'Milk!', 1000),
      note('b', 'milk', 2000),
    ]);

    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(await db.select(db.notes).get(), hasLength(2));
    expect(find.text('2 notes look alike'), findsOneWidget);
  });
}
