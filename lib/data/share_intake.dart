import 'dart:convert';

import 'package:flutter/services.dart';

import '../db/database.dart';
import 'import_service.dart';
import 'jotlock_backup.dart';

const MethodChannel _channel = MethodChannel('daymark/incoming');

/// A share-sheet payload as reported by the platform: jotlock's export
/// carries the backup as a content URI (`EXTRA_STREAM`) plus a caption
/// (`EXTRA_TEXT`). Either alone is importable.
class IncomingShare {
  final String? streamUri;
  final String? text;
  final String? mimeType;

  const IncomingShare({this.streamUri, this.text, this.mimeType});

  bool get hasPayload =>
      (streamUri != null && streamUri!.isNotEmpty) ||
      (text != null && text!.trim().isNotEmpty);
}

/// Typed access to the native `daymark/incoming` channel.
class ShareIntake {
  final MethodChannel channel;

  ShareIntake({MethodChannel? channel}) : channel = channel ?? _channel;

  /// Pulls and clears the buffered share payload, or null when there is
  /// none. Platform errors degrade to null — a failed poll must never
  /// crash the app.
  Future<IncomingShare?> takeIncoming() async {
    try {
      final map = await channel.invokeMethod('takeIncoming');
      if (map is! Map) return null;
      final share = IncomingShare(
        streamUri: map['stream'] is String ? map['stream'] as String : null,
        text: map['text'] is String ? map['text'] as String : null,
        mimeType: map['mimeType'] is String ? map['mimeType'] as String : null,
      );
      return share.hasPayload ? share : null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Reads the shared content URI through the native ContentResolver.
  Future<Uint8List?> readStream(String uri) async {
    try {
      final bytes = await channel.invokeMethod('readStream', uri);
      return bytes is Uint8List ? bytes : null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

/// Outcome of handling one incoming share; [message] is snackbar-ready.
class ShareIntakeResult {
  final bool handled;
  final String message;

  const ShareIntakeResult(this.handled, this.message);
}

/// Turns a share payload into an import. [fetchBytes] is injected so the
/// logic is testable without the platform channel. Order of preference:
/// stream URI first (the canonical jotlock export shape), then an
/// EXTRA_TEXT body that at least looks like a JSON array.
Future<ShareIntakeResult> handleIncomingShare({
  required IncomingShare share,
  required Future<Uint8List?> Function(String uri) fetchBytes,
  required AppDatabase db,
}) async {
  try {
    String raw;
    if (share.streamUri != null && share.streamUri!.isNotEmpty) {
      final bytes = await fetchBytes(share.streamUri!);
      if (bytes == null) {
        return const ShareIntakeResult(
            true, 'Could not read the shared backup');
      }
      raw = utf8.decode(bytes, allowMalformed: true);
    } else if (share.text != null && share.text!.trim().startsWith('[')) {
      raw = share.text!;
    } else {
      return const ShareIntakeResult(
          true, 'Nothing to import from that share');
    }
    final report = await importJotlockBackup(
      db,
      raw,
      fileName: share.text?.trim().isNotEmpty == true
          ? share.text!.trim()
          : 'shared via share sheet',
    );
    return ShareIntakeResult(true, describeImportReport(report));
  } on BackupFormatException {
    return const ShareIntakeResult(true, 'Not a JotLock backup file');
  } catch (_) {
    return const ShareIntakeResult(true, 'Import failed');
  }
}
