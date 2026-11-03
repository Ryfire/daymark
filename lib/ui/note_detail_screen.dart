import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/jotlock_compat.dart';
import '../core/timeline.dart';
import '../data/rewrite_prompts.dart';
import '../db/database.dart';
import '../providers.dart';
import 'note_card.dart';

/// Full view of one note: complete text with checklist rendering, plus
/// all the metadata preserved from jotlock. The note can be deleted from
/// here; editing stays in jotlock. Notes Daymark itself created
/// (quick-rewrite "Save as new", source 'daymark_ai') also get share
/// actions in the app-bar menu — Copy, system Share and Send to
/// JotLock — so a rewrite saved as new can be handed on straight from
/// its details, without redoing the rewrite flow.
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Note'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Note options',
            onSelected: (value) {
              if (value == 'details') _showDetails(note);
              if (value == 'copy') _copy(note);
              if (value == 'share') _share(note);
              if (value == 'jotlock') _sendToJotlock(note);
              if (value == 'delete') _confirmDelete(note);
              if (value == 'revert') _confirmRevert(note);
            },
            itemBuilder: (context) => [
              // View details first: the full note text is the page body,
              // so the metadata (created, reminder, source, …) lives one
              // tap away in the same three-dot menu used everywhere else.
              PopupMenuItem(
                value: 'details',
                child: ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('View details'),
                ),
              ),
              // Share actions live on this screen for Daymark-created
              // notes: a rewrite saved as new can be handed on (JotLock,
              // system sheet, clipboard) right from its detail view.
              if (note.source == 'daymark_ai') ...[
                PopupMenuItem(
                  value: 'copy',
                  child: ListTile(
                    leading: const Icon(Icons.copy_outlined),
                    title: const Text('Copy'),
                  ),
                ),
                PopupMenuItem(
                  value: 'share',
                  child: ListTile(
                    leading: const Icon(Icons.share_outlined),
                    title: const Text('Share'),
                  ),
                ),
                PopupMenuItem(
                  value: 'jotlock',
                  child: ListTile(
                    leading: const Icon(Icons.send_outlined),
                    title: const Text('Send to JotLock'),
                  ),
                ),
              ],
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
              child: ReadOnlyChecklist(
                text: note.content,
                strikeAll: note.done,
                clampLines: false,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Opens the metadata that used to sit in a permanent second card:
  /// created/edited times, reminder, priority, flags and source. In a
  /// swipe-dismissible bottom sheet so the note text keeps the whole
  /// screen — details are on demand, not always in the way.
  void _showDetails(NoteRow note) {
    final scheme = Theme.of(context).colorScheme;
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
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                'Note details',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
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
    );
  }

  /// Copies the note text to the clipboard — the same handoff the
  /// rewrite screen offers. Fire-and-forget: the platform-channel reply
  /// can stall under fake_async (widget tests) and there is nothing
  /// actionable on failure.
  void _copy(NoteRow note) {
    final messenger = ScaffoldMessenger.of(context);
    unawaited(Clipboard.setData(ClipboardData(text: note.content)));
    messenger.showSnackBar(
      const SnackBar(content: Text('Copied to clipboard')),
    );
  }

  /// Opens the system share sheet with the note as plain text — JotLock,
  /// messages, mail, anywhere. Only a failure is announced; the sheet
  /// itself is the success feedback.
  Future<void> _share(NoteRow note) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await ref.read(jotlockSenderProvider).shareText(note.content);
    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not share')),
      );
    }
  }

  /// Hands the note text to JotLock as a NEW note (append-only):
  /// jotlock's editor opens pre-filled and the user confirms the save
  /// there. Daymark's database is untouched either way — for a note
  /// saved as new this is the step that lands the rewrite in jotlock.
  Future<void> _sendToJotlock(NoteRow note) async {
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await ref
        .read(jotlockSenderProvider)
        .sendNote(note.content);
    messenger.showSnackBar(
      SnackBar(content: Text(outcome.message)),
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
