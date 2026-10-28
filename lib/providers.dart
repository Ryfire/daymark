import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'db/database.dart';

/// The app-wide drift database. Overridable in tests with an in-memory one.
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

/// All imported notes, newest first, live-updating after every import.
final notesStreamProvider = StreamProvider<List<NoteRow>>((ref) {
  final db = ref.watch(databaseProvider);
  return (db.select(db.notes)
        ..orderBy([(n) => OrderingTerm.desc(n.createdAt)]))
      .watch();
});
