import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

/// An imported note. Schema mirrors jotlock's native note fields (epoch
/// millis timestamps, index-addressed color) plus provenance columns
/// tracking which import batch supplied the row. Primary key is the
/// jotlock note id, which is what makes re-imported backups merge idempotently.
@DataClassName('NoteRow')
class Notes extends Table {
  TextColumn get id => text()();
  // Not named `text`: a getter with that name shadows drift's `text()`
  // column builder inside the table class and breaks the drift_dev
  // resolver. The jotlock field is mapped onto it at import time.
  TextColumn get content => text()();
  IntColumn get createdAt => integer()();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  IntColumn get colorIndex => integer().withDefault(const Constant(0))();
  IntColumn get reminderAt => integer().withDefault(const Constant(0))();
  BoolColumn get reminderSilent =>
      boolean().withDefault(const Constant(false))();
  IntColumn get repeatDays => integer().withDefault(const Constant(0))();
  BoolColumn get done => boolean().withDefault(const Constant(false))();

  /// Where the row came from ('jotlock_json' for now; more sources later).
  TextColumn get source => text()();
  TextColumn get batchId => text()();
  IntColumn get importedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One import run: what file it came from and what it changed, so the
/// library can show provenance and the UI can report honest counts.
@DataClassName('ImportBatchRow')
class ImportBatches extends Table {
  TextColumn get id => text()();
  TextColumn get fileName => text().nullable()();
  IntColumn get importedAt => integer()();
  IntColumn get added => integer()();
  IntColumn get alreadyPresent => integer()();
  IntColumn get malformed => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Simple key-value store for app configuration. The LLM provider config
/// is stored as a JSON blob under a single key, so new fields can be added
/// without schema churn.
@DataClassName('AppSettingRow')
class AppSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [Notes, ImportBatches, AppSettings])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
      : super(executor ?? driftDatabase(name: 'daymark'));

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(appSettings);
          }
        },
      );
}

/// Convenience getters mirroring jotlock's `Note` helpers, derived from
/// the stored columns.
extension NoteRowTime on NoteRow {
  bool get hasReminder => reminderAt > 0;
  bool get isRecurring => repeatDays > 0;
  DateTime get reminderTime => DateTime.fromMillisecondsSinceEpoch(reminderAt);
  DateTime get createdDateTime =>
      DateTime.fromMillisecondsSinceEpoch(createdAt);
}
