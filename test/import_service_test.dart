import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daymark/data/import_service.dart';
import 'package:daymark/db/database.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('fresh import adds all notes and records a batch', () async {
    final raw = jsonEncode([
      {'id': 'a', 'text': 'first', 'createdAt': 1000},
      {
        'id': 'b',
        'text': '[ ] milk',
        'createdAt': 2000,
        'pinned': true,
        'color': 3,
        'reminderAt': 5000,
        'reminderSilent': true,
        'repeatDays': 7,
        'done': true,
      },
    ]);

    final report = await importJotlockBackup(
      db,
      raw,
      fileName: 'jotlock_backup_2026-10-28.json',
    );

    expect(report.added, 2);
    expect(report.alreadyPresent, 0);
    expect(report.malformed, 0);
    expect(report.addedAnything, isTrue);

    final rows = await db.select(db.notes).get();
    expect(rows.length, 2);
    final rowB = rows.firstWhere((r) => r.id == 'b');
    expect(rowB.pinned, isTrue);
    expect(rowB.colorIndex, 3);
    expect(rowB.reminderAt, 5000);
    expect(rowB.reminderSilent, isTrue);
    expect(rowB.repeatDays, 7);
    expect(rowB.done, isTrue);
    expect(rowB.source, 'jotlock_json');
    expect(rowB.batchId, report.batchId);

    final batches = await db.select(db.importBatches).get();
    expect(batches.single.added, 2);
    expect(batches.single.alreadyPresent, 0);
    expect(batches.single.malformed, 0);
    expect(batches.single.fileName, 'jotlock_backup_2026-10-28.json');
  });

  test('re-importing the same backup adds nothing', () async {
    final raw = jsonEncode([
      {'id': 'a', 'text': 'first', 'createdAt': 1000},
      {'id': 'b', 'text': 'second', 'createdAt': 2000},
    ]);
    await importJotlockBackup(db, raw);

    final report = await importJotlockBackup(db, raw);

    expect(report.added, 0);
    expect(report.alreadyPresent, 2);
    expect(report.updated, 0);
    expect(report.addedAnything, isFalse);
    expect((await db.select(db.notes).get()).length, 2);
    expect((await db.select(db.importBatches).get()).length, 2);
  });

  test('re-import refreshes the done flag on existing notes', () async {
    await importJotlockBackup(
      db,
      jsonEncode([
        {'id': 'a', 'text': 'first', 'createdAt': 1000},
        {'id': 'b', 'text': 'second', 'createdAt': 2000, 'done': true},
      ]),
    );

    final report = await importJotlockBackup(
      db,
      jsonEncode([
        {'id': 'a', 'text': 'first', 'createdAt': 1000, 'done': true},
        {'id': 'b', 'text': 'second', 'createdAt': 2000},
      ]),
    );

    expect(report.updated, 2);
    final rows = {for (final row in await db.select(db.notes).get()) row.id: row};
    expect(rows['a']!.done, isTrue);
    expect(rows['b']!.done, isFalse);
    expect(rows['a']!.content, 'first');
    expect(rows['b']!.content, 'second');
  });

  test('a newer backup adds only the new note', () async {
    await importJotlockBackup(
      db,
      jsonEncode([
        {'id': 'a', 'text': 'first', 'createdAt': 1000},
      ]),
    );
    final report = await importJotlockBackup(
      db,
      jsonEncode([
        {'id': 'a', 'text': 'first', 'createdAt': 1000},
        {'id': 'c', 'text': 'new one', 'createdAt': 3000},
      ]),
    );
    expect(report.added, 1);
    expect(report.alreadyPresent, 1);
    final rows = await db.select(db.notes).get();
    expect(rows.map((r) => r.id), containsAll(['a', 'c']));
  });

  test('malformed entries are skipped and counted, valid ones imported',
      () async {
    final report = await importJotlockBackup(
      db,
      jsonEncode([
        'not a map',
        {'id': '', 'text': 'no id'},
        {'id': 'ok', 'text': 'kept', 'createdAt': 7},
      ]),
    );
    expect(report.malformed, 2);
    expect(report.added, 1);
    expect(
      (await db.select(db.notes).get()).single.content,
      'kept',
    );
  });

  test('duplicate ids within one file are inserted once', () async {
    final report = await importJotlockBackup(
      db,
      jsonEncode([
        {'id': 'a', 'text': 'one', 'createdAt': 1},
        {'id': 'a', 'text': 'one again', 'createdAt': 1, 'done': true},
      ]),
    );
    expect(report.added, 1);
    expect(report.alreadyPresent, 1);
    expect(report.updated, 0);
    final rows = await db.select(db.notes).get();
    expect(rows.length, 1);
    expect(rows.single.content, 'one');
    expect(rows.single.done, isFalse);
  });

  test('describeImportReport mentions done refreshes', () {
    const report = ImportReport(
      batchId: 'b',
      added: 0,
      alreadyPresent: 3,
      malformed: 0,
      updated: 1,
    );
    expect(
      describeImportReport(report),
      'Updated 1 · 3 already present',
    );
  });
}
