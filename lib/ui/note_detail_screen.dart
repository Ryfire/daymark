import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/jotlock_compat.dart';
import '../core/timeline.dart';
import '../db/database.dart';
import '../providers.dart';
import 'note_card.dart';

/// Full read-only view of one imported note: complete text with checklist
/// rendering, plus all metadata jotlock preserved in the backup.
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
    final sourceLine = !_batchLoaded
        ? 'JotLock backup'
        : 'JotLock backup'
            '${_batch?.fileName == null ? '' : ' · ${_batch!.fileName}'}';
    final metaEntries = <(String, String)>[
      ('Created', formatFull(created)),
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
      appBar: AppBar(title: const Text('Note')),
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

  String _colorName(int colorIndex) {
    const names = [
      'Red', 'Orange', 'Yellow', 'Green', 'Blue', 'Purple', 'Teal',
    ];
    return colorIndex >= 1 && colorIndex <= names.length
        ? names[colorIndex - 1]
        : 'Color $colorIndex';
  }
}
