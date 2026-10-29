import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:uuid/uuid.dart';

import '../db/database.dart';

/// A quick-rewrite prompt: the [label] the long-press sheet shows and the
/// [prompt] text sent to the model. The whole list is user-editable and
/// stored as one JSON blob in the settings repository.
class RewritePrompt {
  static const settingsKey = 'rewrite.prompts';

  final String id;
  final String label;
  final String prompt;

  const RewritePrompt({
    required this.id,
    required this.label,
    required this.prompt,
  });

  Map<String, dynamic> toJson() =>
      {'id': id, 'label': label, 'prompt': prompt};

  static RewritePrompt? tryParse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final id = json['id'];
    final label = json['label'];
    final prompt = json['prompt'];
    if (id is! String || label is! String || prompt is! String) return null;
    if (label.trim().isEmpty || prompt.trim().isEmpty) return null;
    return RewritePrompt(id: id, label: label, prompt: prompt);
  }

  static const defaults = [
    RewritePrompt(
      id: 'improve',
      label: 'Improve readability',
      prompt:
          'Improve the readability of this note. Keep every fact, name, '
          'time and number. Preserve [ ] and [x] checklist lines. Output '
          'only the rewritten note.',
    ),
    RewritePrompt(
      id: 'fix-typos',
      label: 'Fix typos & grammar',
      prompt:
          'Fix typos and grammar without changing the structure or the '
          'wording style. Output only the corrected note.',
    ),
    RewritePrompt(
      id: 'to-checklist',
      label: 'Make it a checklist',
      prompt:
          'Turn this note into a checklist: one [ ] or [x] item per line, '
          'no other text. Output only the checklist.',
    ),
    RewritePrompt(
      id: 'summarize',
      label: 'Summarize',
      prompt:
          'Summarize this note in one short sentence. Output only the '
          'summary.',
    ),
  ];
}

String encodeRewritePrompts(List<RewritePrompt> prompts) =>
    jsonEncode([for (final p in prompts) p.toJson()]);

/// Parses the stored blob. Returns null when the key is absent or the
/// blob is corrupt — callers then fall back to the defaults. Malformed
/// entries inside an otherwise valid list are dropped.
List<RewritePrompt>? parseRewritePrompts(String? raw) {
  if (raw == null) return null;
  final List<dynamic> decoded;
  try {
    final result = jsonDecode(raw);
    decoded = result is List ? result : throw const FormatException();
  } catch (_) {
    return null;
  }
  final prompts = <RewritePrompt>[];
  for (final entry in decoded) {
    final prompt = RewritePrompt.tryParse(entry);
    if (prompt != null) prompts.add(prompt);
  }
  return prompts;
}

/// Undo for one quick-rewrite Replace: restores the text stored as
/// [NoteRow.originalContent] and clears both provenance fields.
Future<void> revertNoteEdit(AppDatabase db, NoteRow note) async {
  if (note.originalContent == null) return;
  await (db.update(db.notes)..where((n) => n.id.equals(note.id))).write(
    NotesCompanion(
      content: Value(note.originalContent!),
      editedAt: const Value(0),
      originalContent: const Value(null),
    ),
  );
}

/// Applies a quick-rewrite result in place, keeping the note's metadata
/// and storing the previous text for revert. Returns the updated row.
Future<NoteRow> replaceNoteContent(
  AppDatabase db,
  NoteRow note,
  String newContent,
) async {
  final editedAt = DateTime.now().millisecondsSinceEpoch;
  await (db.update(db.notes)..where((n) => n.id.equals(note.id))).write(
    NotesCompanion(
      content: Value(newContent),
      editedAt: Value(editedAt),
      originalContent: Value(note.content),
    ),
  );
  return NoteRow(
    id: note.id,
    content: newContent,
    createdAt: note.createdAt,
    pinned: note.pinned,
    colorIndex: note.colorIndex,
    reminderAt: note.reminderAt,
    reminderSilent: note.reminderSilent,
    repeatDays: note.repeatDays,
    done: note.done,
    editedAt: editedAt,
    originalContent: note.content,
    source: note.source,
    batchId: note.batchId,
    importedAt: note.importedAt,
  );
}

/// Inserts a rewrite result as a brand-new Daymark-created note.
Future<NoteRow> saveNoteAsNew(AppDatabase db, String content) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final row = NoteRow(
    id: const Uuid().v4(),
    content: content,
    createdAt: now,
    pinned: false,
    colorIndex: 0,
    reminderAt: 0,
    reminderSilent: false,
    repeatDays: 0,
    done: false,
    editedAt: 0,
    source: 'daymark_ai',
    batchId: 'daymark-ai',
    importedAt: now,
  );
  await db.into(db.notes).insert(row);
  return row;
}
