import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/jotlock_compat.dart';
import '../core/timeline.dart';
import '../data/rewrite_prompts.dart';
import '../db/database.dart';
import '../providers.dart';
import 'note_card.dart';

/// Full view of one imported note: complete text with checklist
/// rendering, plus all metadata jotlock preserved in the backup. The
/// note can be deleted from here; editing stays in jotlock.
class NoteDetailScreen extends ConsumerStatefulWidget {
  const NoteDetailScreen({super.key, required this.note});

  final NoteRow note;

  @override
  ConsumerState<NoteDetailScreen> createState() => _NoteDetailScreenState();
}

class _NoteDetailScreenState extends ConsumerState<NoteDetailScreen> {
  ImportBatchRow? _batch;
  bool _batchLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadBatch();
  }

  Future<void> _loadBatch() async {
    final db = ref.read(databaseProvider);
    final rows = await (db.select(db.importBatches)
          ..where((b) => b.id.equals(widget.note.batchId)))
        .getSingleOrNull();
    if (!mounted) return;
    setState(() {
      _batch = rows;
      _batchLoaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final note = widget.note;
    final created = DateTime.fromMillisecondsSinceEpoch(note.createdAt);
    final sourceLine = note.source == 'daymark_ai'
        ? 'Created in Daymark'
        : !_batchLoaded
            ? 'JotLock backup'
            : 'JotLock backup'
                '${_batch?.fileName == null ? '' : ' · ${_batch!.fileName}'}';
    final metaEntries = <(String, String)>[
      ('Created', formatFull(created)),
      if (note.editedAt > 0)
        (
          'Edited',
          formatFull(DateTime.fromMillisecondsSinceEpoch(note.editedAt))
        ),
      (
        'Reminder',
        note.hasReminder
            ? '${formatShort(note.reminderTime)}'
                '${note.isRecurring ? ' · ${repeatLabel(note.repeatDays)}' : ''}'
                '${note.reminderSilent ? ' · silent' : ''}'
            : '—'
      ),
      ('Priority', note.colorIndex > 0 ? _colorName(note.colorIndex) : '—'),
      ('Pinned', note.pinned ? 'Yes' : 'No'),
      ('Done', note.done ? 'Yes' : 'No'),
      ('Source', sourceLine),
      (
        'Imported',
        formatFull(DateTime.fromMillisecondsSinceEpoch(note.importedAt))
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Note'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Note options',
            onSelected: (value) {
              if (value == 'delete') _confirmDelete(note);
              if (value == 'revert') _confirmRevert(note);
            },
            itemBuilder: (context) => [
              if (note.originalContent != null)
                PopupMenuItem(
                  value: 'revert',
                  child: ListTile(
                    leading: const Icon(Icons.undo),
                    title: const Text('Revert to original'),
                  ),
                ),
              PopupMenuItem(
                value: 'delete',
                child: ListTile(
                  leading: Icon(
                    Icons.delete_outline,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: const Text('Delete note'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: noteCardColor(note.colorIndex, scheme),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ReadOnlyChecklist(text: note.content, strikeAll: note.done),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: [
                  for (final (label, value) in metaEntries)
                    ListTile(
                      dense: true,
                      title: Text(label),
                      trailing: Text(
                        value,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Restores the text stored before the last quick-rewrite Replace and
  /// pops back, since this screen shows a stale note object afterwards.
  Future<void> _confirmRevert(NoteRow note) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final db = ref.read(databaseProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Revert to original?'),
        content: const Text(
            'Discards the edited version and restores the note to the '
            'text it had before the last edit.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Revert'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await revertNoteEdit(db, note);
    navigator.pop();
    messenger.showSnackBar(
      const SnackBar(content: Text('Reverted to original')),
    );
  }

  /// Asks for confirmation, then removes the note from the library and
  /// pops back. JotLock is untouched — daymark only holds imported copies.
  Future<void> _confirmDelete(NoteRow note) async {
    final scheme = Theme.of(context).colorScheme;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final db = ref.read(databaseProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete note?'),
        content: const Text(
            'This permanently removes it from your library. '
            'JotLock keeps its own copy.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await (db.delete(db.notes)..where((n) => n.id.equals(note.id))).go();
    navigator.pop();
    messenger.showSnackBar(
      const SnackBar(content: Text('Note deleted')),
    );
  }

  String _colorName(int colorIndex) {
    const names = [
      'Red', 'Orange', 'Yellow', 'Green', 'Blue', 'Purple', 'Teal',
    ];
    return colorIndex >= 1 && colorIndex <= names.length
        ? names[colorIndex - 1]
        : 'Color $colorIndex';
  }
}
