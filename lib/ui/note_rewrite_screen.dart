import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/rewrite_prompts.dart';
import '../db/database.dart';
import '../llm/llm_client.dart';
import '../llm/providers.dart';
import '../providers.dart';
import 'note_card.dart';

/// Streams one quick-rewrite result for a single note: original on top,
/// the rewritten version below, then Copy / Replace / Save as new /
/// Discard. Replace is reversible — the previous text is stored on the
/// note, so a revert is possible long after leaving this screen.
class NoteRewriteScreen extends ConsumerStatefulWidget {
  const NoteRewriteScreen({
    super.key,
    required this.note,
    required this.prompt,
  });

  final NoteRow note;
  final RewritePrompt prompt;

  @override
  ConsumerState<NoteRewriteScreen> createState() =>
      _NoteRewriteScreenState();
}

class _NoteRewriteScreenState extends ConsumerState<NoteRewriteScreen> {
  final _buffer = StringBuffer();
  String _text = '';
  bool _streaming = false;
  Object? _error;
  StreamSubscription<String>? _subscription;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  bool get _hasResult =>
      !_streaming && _error == null && _text.trim().isNotEmpty;

  void _start() {
    final client = ref.read(llmClientProvider);
    if (client == null) {
      setState(() {
        _streaming = false;
        _error = 'No LLM provider configured';
      });
      return;
    }
    setState(() {
      _streaming = true;
      _error = null;
      _text = '';
    });
    _buffer.clear();
    _subscription = client.streamChat(messages: [
      ChatMessage.user(
          '${widget.prompt.prompt}\n\nNOTE:\n${widget.note.content}'),
    ]).listen(
      (delta) {
        _buffer.write(delta);
        setState(() => _text = _buffer.toString());
      },
      onError: (Object error) => setState(() {
        _streaming = false;
        _error = error;
      }),
      onDone: () => setState(() => _streaming = false),
      cancelOnError: false,
    );
  }

  void _stop() {
    _subscription?.cancel();
    setState(() {
      _streaming = false;
      if (_text.trim().isEmpty) _error = 'Stopped';
    });
  }

  Future<void> _copy() async {
    final messenger = ScaffoldMessenger.of(context);
    // Fire-and-forget: the platform-channel reply can stall under
    // fake_async (widget tests) and there is nothing actionable on failure.
    unawaited(Clipboard.setData(ClipboardData(text: _text.trim())));
    messenger.showSnackBar(
      const SnackBar(content: Text('Copied to clipboard')),
    );
  }

  Future<void> _replace() async {
    final scheme = Theme.of(context).colorScheme;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final db = ref.read(databaseProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Replace this note?'),
        content: const Text(
            'The note text is overwritten. The version before this edit is '
            'kept on the note, so you can revert any time.'),
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
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final updated = await replaceNoteContent(
      db,
      widget.note,
      _text.trim(),
    );
    navigator.pop();
    messenger.showSnackBar(
      SnackBar(
        content: const Text('Note replaced'),
        action: SnackBarAction(
          label: 'UNDO',
          onPressed: () => revertNoteEdit(db, updated),
        ),
      ),
    );
  }

  Future<void> _saveAsNew() async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final db = ref.read(databaseProvider);
    await saveNoteAsNew(db, _text.trim());
    navigator.pop();
    messenger.showSnackBar(
      const SnackBar(content: Text('Saved as new note')),
    );
  }

  /// Shares the rewrite to JotLock as a NEW note (append-only): jotlock's
  /// editor opens pre-filled and the user confirms there. Daymark's
  /// database is untouched either way; the note rejoins the mirror on the
  /// next backup import. Never replaces the original in jotlock.
  Future<void> _sendToJotlock() async {
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await ref
        .read(jotlockSenderProvider)
        .sendNote(_text.trim());
    messenger.showSnackBar(
      SnackBar(content: Text(outcome.message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final note = widget.note;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.prompt.label),
        actions: [
          if (_streaming)
            IconButton(
              tooltip: 'Stop',
              onPressed: _stop,
              icon: const Icon(Icons.stop),
            )
          else
            IconButton(
              tooltip: 'Regenerate',
              onPressed: _start,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Original', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ReadOnlyChecklist(text: note.content),
            ),
          ),
          const SizedBox(height: 16),
          Text('Rewritten', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          if (_error != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '⚠ $_error',
                  style: TextStyle(color: scheme.error),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _start,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
              ],
            )
          else
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _text.isEmpty
                    // Static label on purpose: an indefinite spinner here
                    // starves pumpAndSettle in widget tests.
                    ? const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('Rewriting…'),
                      )
                    : ReadOnlyChecklist(text: _text),
              ),
            ),
          if (_hasResult) ...[
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _copy,
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('Copy'),
                ),
                FilledButton.icon(
                  onPressed: _replace,
                  icon: const Icon(Icons.notes_outlined),
                  label: const Text('Replace'),
                ),
                OutlinedButton.icon(
                  onPressed: _saveAsNew,
                  icon: const Icon(Icons.add_circle_outline),
                  label: const Text('Save as new'),
                ),
                OutlinedButton.icon(
                  onPressed: _sendToJotlock,
                  icon: const Icon(Icons.send_outlined),
                  label: const Text('Send to JotLock'),
                ),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Discard'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
