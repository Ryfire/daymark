import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/import_service.dart';
import '../data/jotlock_backup.dart';
import '../data/rewrite_prompts.dart';
import '../data/share_intake.dart';
import '../core/timeline.dart';
import '../db/database.dart';
import '../providers.dart';
import '../llm/providers.dart';
import 'note_card.dart';
import 'note_detail_screen.dart';
import 'note_rewrite_screen.dart';
import 'about_screen.dart';
import 'ask_screen.dart';
import 'batch_rewrite_screen.dart';
import 'duplicates_screen.dart';
import 'settings_screen.dart';

/// Day-grouped timeline of every imported jotlock note, plus the import
/// entry point. The library mirrors jotlock: deletion only, no editing.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  final TextEditingController _searchController = TextEditingController();
  final ShareIntake _intake = ShareIntake();
  bool _searching = false;
  bool _importing = false;
  bool _selecting = false;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _drainIncomingShare();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _drainIncomingShare();
  }

  /// Picks up a share-sheet payload buffered natively (the cold-start
  /// launch intent or a warm onNewIntent) and imports it when it is a
  /// jotlock backup. Errors degrade to a snackbar, never a crash.
  Future<void> _drainIncomingShare() async {
    final share = await _intake.takeIncoming();
    if (share == null || !mounted) return;
    final result = await handleIncomingShare(
      share: share,
      fetchBytes: _intake.readStream,
      db: ref.read(databaseProvider),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.message),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  void _exitSearch() {
    _searchController.clear();
    setState(() => _searching = false);
  }

  void _enterSelect() {
    setState(() {
      _selecting = true;
      _selectedIds.clear();
    });
  }

  void _exitSelect() {
    setState(() {
      _selecting = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelect(String id) {
    setState(() {
      if (!_selectedIds.remove(id)) _selectedIds.add(id);
    });
  }

  /// Prompt picker shared by the single-note long-press and the batch
  /// selection flow: one sheet, one push target per count.
  Future<void> _showRewriteSheet(List<NoteRow> notes) async {
    final prompts =
        ref.read(rewritePromptsProvider).value ??
        List.unmodifiable(RewritePrompt.defaults);
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                notes.length == 1
                    ? 'Quick rewrite'
                    : 'Quick rewrite — ${notes.length} notes',
              ),
            ),
            if (prompts.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No rewrite prompts. Add some in Settings.'),
              )
            else
              for (final prompt in prompts)
                ListTile(
                  title: Text(prompt.label),
                  subtitle: Text(
                    prompt.prompt,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    if (notes.length == 1) {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => NoteRewriteScreen(
                            note: notes.single,
                            prompt: prompt,
                          ),
                        ),
                      );
                    } else {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              BatchRewriteScreen(notes: notes, prompt: prompt),
                        ),
                      );
                    }
                    if (mounted) _exitSelect();
                  },
                ),
          ],
        ),
      ),
    );
  }

  Future<void> _importBackup() async {
    if (_importing) return;
    setState(() => _importing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      final path = files.isEmpty ? null : files.single.path;
      if (path == null) return;
      final raw = await File(path).readAsString();
      final db = ref.read(databaseProvider);
      final report = await importJotlockBackup(
        db,
        raw,
        fileName: files.single.name,
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(describeImportReport(report)),
          duration: const Duration(seconds: 6),
        ),
      );
    } on BackupFormatException {
      messenger.showSnackBar(
        const SnackBar(content: Text('Not a JotLock backup file')),
      );
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Import failed')));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// Asks for confirmation, then removes every imported note. Import
  /// batch rows stay as history; jotlock is untouched.
  Future<void> _confirmDeleteAll(List<NoteRow> notes) async {
    final scheme = Theme.of(context).colorScheme;
    final messenger = ScaffoldMessenger.of(context);
    final db = ref.read(databaseProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete all notes?'),
        content: Text(
          'This permanently removes all ${notes.length} imported notes. '
          'JotLock keeps its own copies.',
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
            child: const Text('Delete all'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await db.delete(db.notes).go();
    messenger.showSnackBar(
      SnackBar(content: Text('Deleted ${notes.length} notes')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final notesAsync = ref.watch(notesStreamProvider);
    final notes = notesAsync.value ?? const <NoteRow>[];
    return Scaffold(
      appBar: AppBar(
        title: _selecting
            ? Text(
                _selectedIds.isEmpty
                    ? 'Select notes'
                    : '${_selectedIds.length} selected',
              )
            : _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search notes',
                  border: InputBorder.none,
                ),
                onChanged: (_) => setState(() {}),
              )
            : switch (notes) {
                const [] => const Text('Daymark'),
                _ => Text('Daymark (${notes.length})'),
              },
        leading: _selecting
            ? IconButton(
                tooltip: 'Stop selecting',
                onPressed: _exitSelect,
                icon: const Icon(Icons.close),
              )
            : null,
        actions: _selecting
            ? const []
            : _searching
            ? [
                IconButton(
                  tooltip: 'Close search',
                  onPressed: _exitSearch,
                  icon: const Icon(Icons.close),
                ),
              ]
            : [
                IconButton(
                  tooltip: 'Ask your notes',
                  onPressed: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => const AskScreen())),
                  icon: const Icon(Icons.chat_bubble_outline),
                ),
                IconButton(
                  tooltip: 'Search',
                  onPressed: () => setState(() => _searching = true),
                  icon: const Icon(Icons.search_outlined),
                ),
                IconButton(
                  tooltip: 'LLM provider',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  ),
                  icon: const Icon(Icons.settings_outlined),
                ),
                PopupMenuButton<String>(
                  tooltip: 'More options',
                  onSelected: (value) {
                    if (value == 'duplicates') {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const DuplicatesScreen(),
                        ),
                      );
                    }
                    if (value == 'select') _enterSelect();
                    if (value == 'deleteAll') {
                      _confirmDeleteAll(notes);
                    }
                    if (value == 'about') {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const AboutScreen()),
                      );
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'duplicates',
                      enabled: notes.isNotEmpty,
                      child: ListTile(
                        leading: const Icon(Icons.copy_all_outlined),
                        title: const Text('Find duplicates'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'select',
                      enabled: notes.isNotEmpty,
                      child: ListTile(
                        leading: const Icon(Icons.checklist),
                        title: const Text('Select notes'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'deleteAll',
                      enabled: notes.isNotEmpty,
                      child: ListTile(
                        leading: Icon(
                          Icons.delete_sweep_outlined,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        title: const Text('Delete all notes'),
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'about',
                      child: ListTile(
                        leading: Icon(Icons.info_outline),
                        title: Text('About'),
                      ),
                    ),
                  ],
                ),
              ],
      ),
      body: notesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) =>
            Center(child: Text('Could not load notes: $error')),
        data: (notes) => _buildBody(notes),
      ),
      bottomNavigationBar: _selecting
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _selectedIds.isEmpty
                            ? null
                            : _startBatchRewrite,
                        icon: const Icon(Icons.auto_fix_high_outlined),
                        label: Text('Rewrite (${_selectedIds.length})'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _exitSelect,
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ),
            )
          : null,
      floatingActionButton: _searching || _selecting
          ? null
          : FloatingActionButton.extended(
              onPressed: _importing ? null : _importBackup,
              icon: _importing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.file_open_outlined),
              label: const Text('Import backup'),
            ),
    );
  }

  /// Pushes the batch rewrite session for the selected notes, in stream
  /// order (newest first); selection mode exits when the screen pops.
  Future<void> _startBatchRewrite() async {
    final notes = ref.read(notesStreamProvider).value ?? const <NoteRow>[];
    final selected = notes
        .where((note) => _selectedIds.contains(note.id))
        .toList();
    if (selected.isEmpty) return;
    await _showRewriteSheet(selected);
    if (mounted) _exitSelect();
  }

  Widget _buildBody(List<NoteRow> notes) {
    if (notes.isEmpty) return _EmptyState(onImport: _importBackup);
    final query = _searching ? _searchController.text.trim() : '';
    final filtered = query.isEmpty
        ? notes
        : notes
              .where(
                (n) => n.content.toLowerCase().contains(query.toLowerCase()),
              )
              .toList();
    if (filtered.isEmpty) return const Center(child: Text('No matching notes'));
    final groups = groupByDay(filtered, (n) => n.createdAt);
    final rows = <_TimelineRow>[];
    for (final group in groups) {
      rows.add(_TimelineRow.header(group.day));
      for (final note in group.items) {
        rows.add(_TimelineRow.note(note));
      }
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        return switch (row) {
          _HeaderRow(:final day) => Padding(
            padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
            child: Text(
              dayHeader(day),
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(color: Theme.of(context).colorScheme.primary),
            ),
          ),
          _NoteRow(:final note) => NoteCard(
            note: note,
            selected: _selectedIds.contains(note.id),
            onToggleSelect: _selecting ? (_) => _toggleSelect(note.id) : null,
            onOpen: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => NoteDetailScreen(note: note)),
            ),
            onLongPress: () => _showRewriteSheet([note]),
          ),
        };
      },
    );
  }
}

/// Flattened list entry for the ListView.builder: a day header or a note.
sealed class _TimelineRow {
  const _TimelineRow();
  factory _TimelineRow.header(DateTime day) = _HeaderRow;
  factory _TimelineRow.note(NoteRow note) = _NoteRow;
}

class _HeaderRow extends _TimelineRow {
  final DateTime day;
  const _HeaderRow(this.day);
}

class _NoteRow extends _TimelineRow {
  final NoteRow note;
  const _NoteRow(this.note);
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onImport});

  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Icon(
                Icons.book_outlined,
                size: 48,
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'No notes yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Export a JSON backup from JotLock\n'
              '(Settings → Export notes (JSON))\n'
              'and import it here to get started.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.outline),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('Import backup'),
            ),
          ],
        ),
      ),
    );
  }
}
