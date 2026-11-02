import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daymark/data/settings_repository.dart';
import 'package:daymark/db/database.dart';
import 'package:daymark/llm/llm_config.dart';

void main() {
  late AppDatabase db;
  late SettingsRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = SettingsRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('set then get round-trips', () async {
    await repo.setString('k', 'v1');
    expect(await repo.getString('k'), 'v1');
    await repo.setString('k', 'v2');
    expect(await repo.getString('k'), 'v2');
  });

  test('missing key reads null', () async {
    expect(await repo.getString('absent'), isNull);
  });

  test('getLlmConfig round-trips the stored JSON', () async {
    await repo.setString(
      LlmConfig.settingsKey,
      LlmConfig(baseUrl: 'http://x:1/v1', apiKey: 'k', model: 'm')
          .toJsonString(),
    );
    expect(
      await repo.getLlmConfig(),
      LlmConfig(baseUrl: 'http://x:1/v1', apiKey: 'k', model: 'm'),
    );
  });

  test('getLlmConfig is null when absent or corrupt', () async {
    expect(await repo.getLlmConfig(), isNull);
    await repo.setString(LlmConfig.settingsKey, '{not json');
    expect(await repo.getLlmConfig(), isNull);
  });

  test('watchString emits the stored value', () async {
    await repo.setString('k', 'v1');
    expect(await repo.watchString('k').first, 'v1');
  });

  test('watchString reflects updates live', () async {
    final values = <String?>[];
    final sub = repo.watchString('k').listen(values.add);
    addTearDown(sub.cancel);

    await repo.setString('k', 'v1');
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(values.contains('v1'), isTrue);
  });

  test('remove deletes the key', () async {
    await repo.setString('k', 'v');
    await repo.remove('k');
    expect(await repo.getString('k'), isNull);
  });
}
