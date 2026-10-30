import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/rewrite_prompts.dart';
import '../db/database.dart';
import '../llm/llm_client.dart';
import '../llm/providers.dart';
import '../providers.dart';

enum _ItemStatus { pending, streaming, ready, error, kept, skipped }

class _Item {
  _Item(this.note);

  final NoteRow note;
  String text = '';
  _ItemStatus status = _ItemStatus.pending;
  Object? error;
}

/// Batch quick-rewrite session: streams one prompt over the selected
/// notes sequentially (local LLM endpoints process one request at a
/// time anyway), with a Keep / Skip decision per result. Keep saves the
/// rewrite as a brand-new note in the mirror — a batch never overwrites
/// originals; in-place replace with its per-note undo stays on the
/// single-note rewrite screen. Afterwards, kept rewrites can be sent to
/// JotLock one share at a time: each share opens JotLock's editor
/// pre-filled and the user confirms the save there.
class BatchRewriteScreen extends ConsumerStatefulWidget {
  const BatchRewriteScreen({
    super.key,
    required this.notes,
    required this.prompt,
  });

  final List<NoteRow> notes;
  final RewritePrompt prompt;

  @override
  ConsumerState<BatchRewriteScreen> createState() => _BatchRewriteScreenState();
}

class _BatchRewriteScreenState extends ConsumerState<BatchRewriteScreen> {
  late final List<_Item> _items = [
    for (final note in widget.notes) _Item(note),
  ];
  final Set<int> _sent = {};
  StreamSubscription<String>? _sub;
  bool _sending = false;

  bool get _allDecided => _items.every(
    (item) => switch (item.status) {
      _ItemStatus.pending || _ItemStatus.streaming => false,
      _ => true,
    },
  );

  int get _keptCount =>
      _items.where((item) => item.status == _ItemStatus.kept).length;

  /// Notes with a final decision (kept, skipped or errored) — the note
  /// currently streaming is not yet decided.
  int get _decidedCount => _items
      .where(
        (item) => switch (item.status) {
          _ItemStatus.pending || _ItemStatus.streaming => false,
          _ => true,
        },
      )
      .length;

  @override
  void initState() {
    super.initState();
    _startNext();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// Streams the first note still awaiting a decision; when every note
  /// is decided, simply refreshes so the send bar can appear.
  void _startNext() {
    _sub?.cancel();
    final index = _items.indexWhere(
      (item) => item.status == _ItemStatus.pending,
    );
    if (index == -1) {
      setState(() {});
      return;
    }
    final item = _items[index];
    final client = ref.read(llmClientProvider);
    setState(() {
      item
        ..status = _ItemStatus.streaming
        ..error = null
        ..text = '';
    });
    if (client == null) {
      setState(() {
        item
          ..status = _ItemStatus.error
          ..error = 'No LLM provider configured';
      });
      return;
    }
    final buffer = StringBuffer();
    _sub = client
        .streamChat(
          messages: [
            ChatMessage.user(
              '${widget.prompt.prompt}\n\nNOTE:\n${item.note.content}',
            ),
          ],
        )
        .listen(
          (delta) {
            buffer.write(delta);
            setState(() => item.text = buffer.toString());
          },
          onError: (Object error) {
            if (!mounted) return;
            setState(() {
              item
                ..status = _ItemStatus.error
                ..error = error;
            });
          },
          onDone: () {
            // An errored stream still fires done — never overwrite the real
            // error with the empty-response fallback.
            if (!mounted || item.status == _ItemStatus.error) return;
            setState(() {
              if (item.text.trim().isEmpty) {
                item
                  ..status = _ItemStatus.error
                  ..error = 'Empty response';
              } else {
                item.status = _ItemStatus.ready;
              }
            });
          },
          cancelOnError: true,
        );
  }

  Future<void> _keep(_Item item) async {
    final db = ref.read(databaseProvider);
    await saveNoteAsNew(db, item.text.trim());
    if (!mounted) return;
    setState(() => item.status = _ItemStatus.kept);
    _startNext();
  }

  void _skip(_Item item) {
    setState(() => item.status = _ItemStatus.skipped);
    _startNext();
  }

  void _retry(_Item item) {
    setState(() => item.status = _ItemStatus.pending);
    _startNext();
  }

  Future<void> _sendKept(int itemIndex) async {
    final item = _items[itemIndex];
    final sender = ref.read(jotlockSenderProvider);
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await sender.sendNote(item.text.trim());
    messenger.showSnackBar(SnackBar(content: Text(outcome.message)));
    if (!outcome.sent) return;
    if (!mounted) return;
    setState(() => _sent.add(itemIndex));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_sending ? 'Send to JotLock' : 'Batch rewrite'),
        leading: _sending
            ? BackButton(onPressed: () => setState(() => _sending = false))
            : null,
        actions: [
          if (!_sending)
            IconButton(
              tooltip: 'Leave session (kept notes stay)',
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed: () => Navigator.of(context).pop(),
            ),
        ],
      ),
      bottomNavigationBar: !_sending && _allDecided
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: FilledButton.icon(
                  onPressed: _keptCount == 0
                      ? null
                      : () => setState(() => _sending = true),
                  icon: const Icon(Icons.send_outlined),
                  label: Text('Send to JotLock ($_keptCount)'),
                ),
              ),
            )
          : null,
      body: SafeArea(
        top: false,
        child: _sending ? _buildQueue(scheme) : _buildSession(scheme),
      ),
    );
  }

  Widget _buildSession(ColorScheme scheme) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Prompt: ${widget.prompt.prompt}\n'
              '$_decidedCount of ${_items.length} decided',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        const SizedBox(height: 4),
        for (var i = 0; i < _items.length; i++)
          _ItemCard(
            item: _items[i],
            scheme: scheme,
            onKeep: () => _keep(_items[i]),
            onSkip: () => _skip(_items[i]),
            onRetry: () => _retry(_items[i]),
          ),
      ],
    );
  }

  Widget _buildQueue(ColorScheme scheme) {
    final keptIndexes = <int>[
      for (var i = 0; i < _items.length; i++)
        if (_items[i].status == _ItemStatus.kept) i,
    ];
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Each note opens in JotLock\'s editor pre-filled — '
              'tap Save there to keep it, then send the next here.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        const SizedBox(height: 4),
        for (final index in keptIndexes)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              title: Text(
                _items[index].text.trim(),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                _items[index].note.content,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.outline),
              ),
              trailing: _sent.contains(index)
                  ? Icon(Icons.check_circle, color: scheme.primary)
                  : FilledButton.tonal(
                      onPressed: () => _sendKept(index),
                      child: const Text('Send'),
                    ),
            ),
          ),
      ],
    );
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({
    required this.item,
    required this.scheme,
    required this.onKeep,
    required this.onSkip,
    required this.onRetry,
  });

  final _Item item;
  final ColorScheme scheme;
  final VoidCallback onKeep;
  final VoidCallback onSkip;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [Expanded(child: _statusRow(context))]),
            const SizedBox(height: 8),
            Text(
              item.note.content,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.outline),
            ),
            if (item.text.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(item.text),
              ),
            ],
            if (item.status == _ItemStatus.error) ...[
              const SizedBox(height: 8),
              Text('${item.error}', style: TextStyle(color: scheme.error)),
            ],
            if (item.status == _ItemStatus.ready) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  FilledButton(onPressed: onKeep, child: const Text('Keep')),
                  const SizedBox(width: 8),
                  OutlinedButton(onPressed: onSkip, child: const Text('Skip')),
                ],
              ),
            ],
            if (item.status == _ItemStatus.error) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  FilledButton.tonal(
                    onPressed: onRetry,
                    child: const Text('Retry'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(onPressed: onSkip, child: const Text('Skip')),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statusRow(BuildContext context) {
    final text = Theme.of(context).textTheme.labelMedium
        ?.copyWith(color: scheme.onSurfaceVariant);
    return switch (item.status) {
      _ItemStatus.pending => Text('Queued', style: text),
      _ItemStatus.streaming => Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text('Rewriting…', style: text),
        ],
      ),
      _ItemStatus.ready => Text('Ready to review', style: text),
      _ItemStatus.error => Text('Error', style: text),
      _ItemStatus.kept => Row(
        children: [
          Icon(Icons.check_circle, size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          Text('Kept — saved as a new note', style: text),
        ],
      ),
      _ItemStatus.skipped => Text('Skipped', style: text),
    };
  }
}
