import 'dart:convert';

/// Thrown when a file is not a jotlock backup at all (bad JSON or not an
/// array) — distinct from per-entry malformed counting.
class BackupFormatException implements Exception {
  final String message;
  const BackupFormatException(this.message);
  @override
  String toString() => message;
}

/// One note as it appears in a JotLock JSON backup (Settings → Export
/// notes (JSON)). Field semantics mirror jotlock's `Note.fromMap`.
class JotlockNote {
  final String id;
  final String text;
  final DateTime createdAt;

  final bool pinned;

  /// Index into jotlock's fixed priority palette (`0` = no color).
  final int colorIndex;

  /// Epoch millis of the one-shot reminder, or 0 when none is set.
  final int reminderAt;
  final bool reminderSilent;

  /// Recurrence interval in days: 0 = one-shot, 1 = daily, 7 = weekly,
  /// N = every N days.
  final int repeatDays;

  /// Marked-done flag, independent of checklist item state.
  final bool done;

  const JotlockNote({
    required this.id,
    required this.text,
    required this.createdAt,
    this.pinned = false,
    this.colorIndex = 0,
    this.reminderAt = 0,
    this.reminderSilent = false,
    this.repeatDays = 0,
    this.done = false,
  });

  bool get hasReminder => reminderAt > 0;
  bool get isRecurring => repeatDays > 0;
  DateTime get reminderTime => DateTime.fromMillisecondsSinceEpoch(reminderAt);
}

/// Result of parsing a backup: the valid notes plus how many entries were
/// skipped as malformed.
class BackupParseResult {
  final List<JotlockNote> notes;
  final int malformed;
  const BackupParseResult({required this.notes, required this.malformed});
}

/// Parses the JSON content of a jotlock backup file: an array of note maps
/// written by the capture app. Missing optional fields fall back to their
/// jotlock defaults, unknown fields are ignored, and entries that are not
/// objects — or whose `id` is missing/empty (needed for dedupe) — count as
/// malformed rather than failing the whole import.
BackupParseResult parseJotlockBackup(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (e) {
    throw BackupFormatException('Not valid JSON: ${e.message}');
  }
  if (decoded is! List) {
    throw const BackupFormatException('Expected a JSON array of notes');
  }
  var malformed = 0;
  final notes = <JotlockNote>[];
  for (final entry in decoded) {
    try {
      if (entry is! Map) {
        malformed++;
        continue;
      }
      final id = entry['id'];
      if (id is! String || id.isEmpty) {
        malformed++;
        continue;
      }
      notes.add(JotlockNote(
        id: id,
        text: (entry['text'] as String?) ?? '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          (entry['createdAt'] as num?)?.toInt() ?? 0,
        ),
        pinned: (entry['pinned'] as bool?) ?? false,
        colorIndex: (entry['color'] as num?)?.toInt() ?? 0,
        reminderAt: (entry['reminderAt'] as num?)?.toInt() ?? 0,
        reminderSilent: (entry['reminderSilent'] as bool?) ?? false,
        repeatDays: (entry['repeatDays'] as num?)?.toInt() ?? 0,
        done: (entry['done'] as bool?) ?? false,
      ));
    } on TypeError {
      // A field of the wrong JSON type — skip the entry, keep the import.
      malformed++;
    }
  }
  return BackupParseResult(notes: notes, malformed: malformed);
}
