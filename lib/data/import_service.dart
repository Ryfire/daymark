import 'package:drift/drift.dart' show Value;
import 'package:uuid/uuid.dart';

import '../db/database.dart';
import 'jotlock_backup.dart';

/// Outcome of one import run — shown in the snackbar and stored as a
/// batch record for provenance.
class ImportReport {
  final String batchId;
  final int added;
  final int alreadyPresent;
  final int malformed;

  /// Existing notes whose done flag was refreshed from the (newer) backup.
  /// Content is never touched on re-import, so Daymark-side rewrites and
  /// reverts survive.
  final int updated;

  const ImportReport({
    required this.batchId,
    required this.added,
    required this.alreadyPresent,
    required this.malformed,
    this.updated = 0,
  });

  bool get addedAnything => added > 0;
}

/// Parses [raw] (a jotlock JSON backup) and merges it into [db]. Notes
/// whose id already exists keep their content — the same merge rule
/// jotlock's own import uses — so re-sharing a newer backup only adds
/// what is new; their done flag, however, is refreshed from the backup.
/// Every run records an [ImportBatches] row, even a no-op one.
Future<ImportReport> importJotlockBackup(
  AppDatabase db,
  String raw, {
  String? fileName,
}) async {
  final parsed = parseJotlockBackup(raw);
  final batchId = const Uuid().v4();
  final now = DateTime.now().millisecondsSinceEpoch;

  final existing = <String, NoteRow?>{
    for (final row in await db.select(db.notes).get()) row.id: row,
  };

  var added = 0;
  var alreadyPresent = 0;
  final donenessRefreshes = <MapEntry<String, bool>>[];
  await db.batch((b) {
    for (final note in parsed.notes) {
      // Map values: the db row, or null once the id was seen in this file —
      // key presence means "already handled", the row itself enables the
      // doneness refresh.
      final known = existing[note.id];
      if (existing.containsKey(note.id)) {
        alreadyPresent++;
        if (known != null && known.done != note.done) {
          donenessRefreshes.add(MapEntry(note.id, note.done));
        }
        continue;
      }
      existing[note.id] = null;
      added++;
      b.insert(
        db.notes,
        NotesCompanion.insert(
          id: note.id,
          content: note.text,
          createdAt: note.createdAt.millisecondsSinceEpoch,
          source: 'jotlock_json',
          batchId: batchId,
          importedAt: now,
          pinned: Value(note.pinned),
          colorIndex: Value(note.colorIndex),
          reminderAt: Value(note.reminderAt),
          reminderSilent: Value(note.reminderSilent),
          repeatDays: Value(note.repeatDays),
          done: Value(note.done),
        ),
      );
    }
  });

  for (final refresh in donenessRefreshes) {
    await (db.update(db.notes)..where((tbl) => tbl.id.equals(refresh.key)))
        .write(NotesCompanion(done: Value(refresh.value)));
  }

  await db.into(db.importBatches).insert(
        ImportBatchesCompanion.insert(
          id: batchId,
          fileName: Value(fileName),
          importedAt: now,
          added: added,
          alreadyPresent: alreadyPresent,
          malformed: parsed.malformed,
        ),
      );

  return ImportReport(
    batchId: batchId,
    added: added,
    alreadyPresent: alreadyPresent,
    malformed: parsed.malformed,
    updated: donenessRefreshes.length,
  );
}

/// Snackbar line for an import report: only non-zero parts, ` · `-joined.
String describeImportReport(ImportReport report) {
  final parts = <String>[
    if (report.added > 0)
      'Imported ${report.added} note${report.added == 1 ? '' : 's'}',
    if (report.updated > 0) 'Updated ${report.updated}',
    if (report.alreadyPresent > 0)
      '${report.alreadyPresent} already present',
    if (report.malformed > 0) '${report.malformed} skipped',
  ];
  return parts.isEmpty ? 'Nothing to import' : parts.join(' · ');
}
