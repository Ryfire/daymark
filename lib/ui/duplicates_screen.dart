import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/dedupe.dart';
import '../core/timeline.dart';
import '../db/database.dart';
import '../providers.dart';

/// Triage screen for likely duplicate notes: groups exact and
/// near-duplicates for a keep-or-delete pass. Deleting removes Daymark's
/// copy only — JotLock keeps its own, so a re-import can restore
/// anything removed here.
class DuplicatesScreen extends ConsumerWidget {
  const DuplicatesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notesAsync = ref.watch(notesStreamProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Duplicates')),
      body: notesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) =>
            Center(child: Text('Could not load notes: $error')),
        data: (notes) {
          final groups = findDuplicateGroups(notes);
          if (groups.isEmpty) {
            return const _NoDuplicates();
          }
          return SafeArea(
            top: false,
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'These notes look like repeats or near-repeats. '
                      'Delete the copies you don\'t need — JotLock keeps '
                      'its own, and re-importing a backup can bring a '
                      'deleted note back.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                for (final group in groups) _DuplicateGroupCard(group: group),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _NoDuplicates extends StatelessWidget {
  const _NoDuplicates();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle_outline, size: 48, color: scheme.primary),
          const SizedBox(height: 16),
          Text(
            'No duplicates found',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Every note looks unique.',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.outline),
          ),
        ],
      ),
    );
  }
}

class _DuplicateGroupCard extends ConsumerWidget {
  const _DuplicateGroupCard({required this.group});

  final List<NoteRow> group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              '${group.length} notes look alike',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          for (final note in group)
            ListTile(
              title: Text(
                note.content,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                formatShort(
                  DateTime.fromMillisecondsSinceEpoch(note.createdAt),
                ),
              ),
              trailing: IconButton(
                tooltip: 'Delete note',
                icon: Icon(
                  Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
                onPressed: () => _confirmDelete(context, ref, note),
              ),
            ),
        ],
      ),
    );
  }

  /// Same confirmation pattern as the note detail screen; JotLock is
  /// untouched, and a re-import can restore the note.
  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    NoteRow note,
  ) async {
    final scheme = Theme.of(context).colorScheme;
    final messenger = ScaffoldMessenger.of(context);
    final db = ref.read(databaseProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete note?'),
        content: const Text(
          'This permanently removes it from your library. '
          'JotLock keeps its own copy.',
        ),
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
    messenger.showSnackBar(const SnackBar(content: Text('Note deleted')));
  }
}
