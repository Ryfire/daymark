import '../db/database.dart';
import '../llm/llm_config.dart';

/// Typed key-value access over the AppSettings table.
class SettingsRepository {
  final AppDatabase _db;

  SettingsRepository(this._db);

  Future<String?> getString(String key) async {
    final row = await (_db.select(_db.appSettings)
          ..where((s) => s.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> setString(String key, String value) async {
    await _db.into(_db.appSettings).insertOnConflictUpdate(
          AppSettingsCompanion.insert(key: key, value: value),
        );
  }

  /// Typed one-shot read of the provider config. Unlike the watched
  /// stream — which Riverpod pauses when nothing listens — this plain
  /// database read always completes, making it safe for imperative
  /// cold-start flows such as the rewrite screens.
  Future<LlmConfig?> getLlmConfig() async =>
      LlmConfig.fromJsonString(await getString(LlmConfig.settingsKey));

  /// Live-updating string value; emits null when the key is absent.
  Stream<String?> watchString(String key) {
    return (_db.select(_db.appSettings)
          ..where((s) => s.key.equals(key)))
        .watchSingleOrNull()
        .map((row) => row?.value);
  }

  Future<void> remove(String key) async {
    await (_db.delete(_db.appSettings)..where((s) => s.key.equals(key))).go();
  }
}
