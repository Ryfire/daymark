import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daymark/data/settings_repository.dart';
import 'package:daymark/db/database.dart';

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
