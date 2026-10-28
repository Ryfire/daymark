import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daymark/data/share_intake.dart';
import 'package:daymark/db/database.dart';

AppDatabase memoryDb() => AppDatabase(NativeDatabase.memory());

const validBackup = '''
[
  {"id": "a", "text": "first", "createdAt": 1000},
  {"id": "b", "text": "second", "createdAt": 2000}
]
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('handleIncomingShare', () {
    late AppDatabase db;

    setUp(() => db = memoryDb());
    tearDown(() => db.close());

    test('imports a stream payload and reports counts', () async {
      final result = await handleIncomingShare(
        share: const IncomingShare(streamUri: 'content://x/backup.json'),
        fetchBytes: (uri) async => Uint8List.fromList(utf8.encode(validBackup)),
        db: db,
      );

      expect(result.handled, isTrue);
      expect(result.message, contains('Imported 2 notes'));
      expect((await db.select(db.notes).get()).length, 2);
    });

    test('re-shared backup dedupes into already-present counts', () async {
      Future<Uint8List?> bytes(String _) async =>
          Uint8List.fromList(utf8.encode(validBackup));
      await handleIncomingShare(
        share: const IncomingShare(streamUri: 'content://x/backup.json'),
        fetchBytes: bytes,
        db: db,
      );
      final result = await handleIncomingShare(
        share: const IncomingShare(streamUri: 'content://x/backup.json'),
        fetchBytes: bytes,
        db: db,
      );

      expect(result.message, contains('2 already present'));
      expect((await db.select(db.notes).get()).length, 2);
    });

    test('junk bytes report as not-a-backup and import nothing', () async {
      final result = await handleIncomingShare(
        share: const IncomingShare(streamUri: 'content://x/x.json'),
        fetchBytes: (uri) async => Uint8List.fromList(utf8.encode('nope')),
        db: db,
      );

      expect(result.message, 'Not a JotLock backup file');
      expect(await db.select(db.notes).get(), isEmpty);
    });

    test('unreadable stream reports the failure', () async {
      final result = await handleIncomingShare(
        share: const IncomingShare(streamUri: 'content://x/gone.json'),
        fetchBytes: (uri) async => null,
        db: db,
      );

      expect(result.message, contains('Could not read'));
      expect(await db.select(db.notes).get(), isEmpty);
    });

    test('a JSON-array EXTRA_TEXT body imports without a stream', () async {
      final result = await handleIncomingShare(
        share: const IncomingShare(text: validBackup),
        fetchBytes: (uri) => Future.value(null),
        db: db,
      );

      expect(result.message, contains('Imported 2 notes'));
    });

    test('non-JSON text shares are declined politely', () async {
      final result = await handleIncomingShare(
        share: const IncomingShare(text: 'JotLock backup (2026-10-28)'),
        fetchBytes: (uri) => Future.value(null),
        db: db,
      );

      expect(result.message, contains('Nothing to import'));
      expect(await db.select(db.notes).get(), isEmpty);
    });
  });

  group('ShareIntake channel', () {
    test('takeIncoming parses a buffered payload and clears it', () async {
      const channel = MethodChannel('daymark/incoming');
      var buffered = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'takeIncoming') {
          // Mirror the native buffer: the payload is consumed by the pull.
          if (!buffered) return null;
          buffered = false;
          return {
            'stream': 'content://x/backup.json',
            'text': 'JotLock backup (2026-10-28)',
            'mimeType': 'application/json',
          };
        }
        return null;
      });
      addTearDown(() =>
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null));

      final intake = ShareIntake(channel: channel);
      final first = await intake.takeIncoming();
      expect(first?.streamUri, 'content://x/backup.json');
      expect(first?.text, 'JotLock backup (2026-10-28)');
      // Buffered payload is cleared after the first pull.
      expect(await intake.takeIncoming(), isNull);
    });

    test('takeIncoming returns null on platform errors', () async {
      const channel = MethodChannel('daymark/incoming-error');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async =>
              throw PlatformException(code: 'boom'));
      addTearDown(() =>
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null));

      expect(await ShareIntake(channel: channel).takeIncoming(), isNull);
    });
  });
}
