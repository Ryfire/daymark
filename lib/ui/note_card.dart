import 'package:flutter/material.dart';

import '../core/jotlock_compat.dart';
import '../core/timeline.dart';
import '../db/database.dart';

/// Compact card for the timeline. Read-only by design: daymark never
/// edits jotlock's notes, it only renders and analyzes them.
class NoteCard extends StatelessWidget {
  const NoteCard({super.key, required this.note, required this.onOpen});

  final NoteRow note;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = noteCardColor(note.colorIndex, scheme);
    final (checked, total) = checklistProgress(note.content);
    final doneStyle = TextStyle(color: scheme.outline);
    final subtitleParts = <String>[
      formatTime(
        DateTime.fromMillisecondsSinceEpoch(note.createdAt),
      ),
      if (total > 0) '$checked/$total',
      if (note.hasReminder)
        'reminds ${_formatReminder(note.reminderTime)}'
            '${note.isRecurring ? ' · ${repeatLabel(note.repeatDays)}' : ''}',
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: tint,
      child: ListTile(
        leading: note.pinned ? const Icon(Icons.push_pin, size: 20) : null,
        title: checklistItems(note.content).isEmpty
            ? Text(
                note.content,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: note.done
                    ? TextStyle(
                        decoration: TextDecoration.lineThrough,
                        color: scheme.outline,
                      )
                    : null,
              )
            : ReadOnlyChecklist(
                text: note.content,
                maxRows: 8,
                strikeAll: note.done,
              ),
        subtitle: Text(
          subtitleParts.join(' · '),
          style: note.done ? doneStyle : null,
        ),
        onTap: onOpen,
      ),
    );
  }

  /// Compact reminder display: omits the date when it is today.
  String _formatReminder(DateTime dt) {
    final now = DateTime.now();
    final sameDay =
        dt.year == now.year && dt.month == now.month && dt.day == now.day;
    return sameDay ? formatTime(dt) : formatShort(dt);
  }
}

/// Renders a note's lines interleaved: checklist items as checkbox rows,
/// everything else as plain text lines. Read-only — checked state comes
/// from the note text itself. [maxRows] caps the render with a "+N more"
/// hint; pass null to show everything (note detail screen).
class ReadOnlyChecklist extends StatelessWidget {
  const ReadOnlyChecklist({
    super.key,
    required this.text,
    this.maxRows,
    this.strikeAll = false,
  });

  final String text;
  final int? maxRows;
  final bool strikeAll;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lines = text.split('\n');
    final rows = <Widget>[];
    var hidden = 0;
    for (var i = 0; i < lines.length; i++) {
      final item = checklistItemAt(text, i);
      if (maxRows != null && rows.length >= maxRows!) {
        if (item != null) hidden++;
        continue;
      }
      if (item == null) {
        if (lines[i].trim().isEmpty) continue; // blank spacing line
        rows.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              lines[i],
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: strikeAll
                  ? TextStyle(
                      decoration: TextDecoration.lineThrough,
                      color: scheme.outline,
                    )
                  : null,
            ),
          ),
        );
        continue;
      }
      final strike = strikeAll || item.checked;
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              item.checked ? Icons.check_box : Icons.check_box_outline_blank,
              size: 20,
              color: strike ? scheme.outline : scheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                item.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: strike
                    ? TextStyle(
                        decoration: TextDecoration.lineThrough,
                        color: scheme.outline,
                      )
                    : null,
              ),
            ),
          ],
        ),
      );
    }
    if (hidden > 0) {
      rows.add(
        Text(
          '… +$hidden more',
          style: TextStyle(fontSize: 12, color: scheme.outline),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows,
    );
  }
}
