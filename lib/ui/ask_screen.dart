import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/timeline.dart';
import '../db/database.dart';
import '../llm/grounding.dart';
import '../llm/llm_client.dart';
import '../llm/providers.dart';
import '../providers.dart';
import '../tts/speech.dart';
import 'autoplay_toggle.dart';
import 'chat_bubble.dart';
import 'note_detail_screen.dart';
import 'settings_screen.dart';

/// Grounded chat: every question is answered with the user's imported
/// notes in context, with citation ids ([n1], [n2], ...) pointing back at
/// the note lines in the system prompt. Each completed reply gets a
/// Sources row mapping the cited ids to the real notes, tappable to open.
class AskScreen extends ConsumerStatefulWidget {
  const AskScreen({super.key});

  @override
  ConsumerState<AskScreen> createState() => _AskScreenState();
}

class _AskScreenState extends ConsumerState<AskScreen> {
  final _messages = <ChatMessage>[];
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  StreamSubscription<String>? _subscription;
  bool _streaming = false;
  ContextSelection? _lastSelection;

  /// Selection that grounded each message, parallel to [_messages] (user
  /// messages carry null). Kept in lockstep with every mutation below.
  final _selections = <ContextSelection?>[];

  /// Captured in initState: ref must not be used inside dispose, and a
  /// stable controller reference keeps the stop-on-dispose rule simple.
  late final SpeechController _speech;

  @override
  void initState() {
    super.initState();
    _speech = ref.read(speechProvider);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    unawaited(_speech.stop());
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _sendQuestion(List<NoteRow> notes) {
    if (_streaming) return;
    final client = ref.read(llmClientProvider);
    if (client == null) return;
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _inputController.clear();
    unawaited(_speech.stop());

    final selection = selectContext(notes, text);
    _lastSelection = selection;
    final systemMessage =
        ChatMessage.system(buildGroundedSystemPrompt(selection));

    setState(() {
      _messages.add(ChatMessage.user(text));
      _selections.add(null);
      _messages.add(const ChatMessage.assistant(''));
      _selections.add(selection);
      _streaming = true;
    });
    _scrollToBottom();

    final history = [
      systemMessage,
      ..._messages
          .take(_messages.length - 1)
          .where((m) => m.content.isNotEmpty),
    ];
    final buffer = StringBuffer();
    _subscription = client.streamChat(messages: history).listen(
      (delta) {
        buffer.write(delta);
        setState(() =>
            _messages[_messages.length - 1] =
                ChatMessage.assistant(buffer.toString()));
        _scrollToBottom();
      },
      onError: (Object error) {
        setState(() {
          final errorText = '⚠ $error';
          if (buffer.isEmpty) {
            _messages[_messages.length - 1] =
                ChatMessage.assistant(errorText);
          } else {
            _messages.add(ChatMessage.assistant(errorText));
            _selections.add(null);
          }
          _streaming = false;
        });
        _scrollToBottom();
      },
      onDone: () {
        // Streams deliver error THEN done: an error bubble already
        // replaced the placeholder, so only remove a still-empty one.
        final last = _messages.last;
        if (last.role == 'assistant' && last.content.isEmpty) {
          setState(() {
            _messages.removeLast();
            _selections.removeLast();
            _streaming = false;
          });
        } else {
          setState(() => _streaming = false);
          _speakIfAutoplay(last.content);
        }
      },
    );
  }

  /// Speaks the finished reply only when autoplay is on. Never speaks
  /// partial text or error bubbles.
  Future<void> _speakIfAutoplay(String reply) async {
    if (reply.startsWith('⚠')) return;
    if (ref.read(ttsAutoplayProvider).value != true) return;
    await _speech.speak(reply, rate: _currentSpeechRate());
  }

  double _currentSpeechRate() => ref.read(ttsRateProvider).value ?? 0.5;

  void _stop() {
    _subscription?.cancel();
    _subscription = null;
    unawaited(_speech.stop());
    setState(() => _streaming = false);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    });
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  String _contextLabel(ContextSelection selection) {
    final kChars = (selection.usedChars / 1000).toStringAsFixed(1);
    final base = '${selection.notes.length} of '
        '${selection.totalNotes} notes · ~${kChars}k chars';
    return selection.isTruncated ? '$base (by relevance)' : base;
  }

  @override
  Widget build(BuildContext context) {
    final notesAsync = ref.watch(notesStreamProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ask your notes'),
        actions: const [SpeedButton(), AutoplayToggle()],
      ),
      body: notesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Could not load notes: $error')),
        data: (notes) {
          if (ref.watch(llmConfigProvider).value == null) {
            return _CenterPrompt(
              icon: Icons.settings_outlined,
              title: 'No LLM provider configured',
              actionLabel: 'Configure provider',
              onAction: _openSettings,
            );
          }
          if (notes.isEmpty) {
            return const _CenterPrompt(
              icon: Icons.book_outlined,
              title: 'No notes yet',
              subtitle:
                  'Import a JotLock backup first, then ask about it here.',
            );
          }
          return _buildChat(notes);
        },
      ),
    );
  }

  Widget _buildChat(List<NoteRow> notes) {
    return Column(
      children: [
        if (_lastSelection != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _contextLabel(_lastSelection!),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
              ),
            ),
          ),
        Expanded(
          child: _messages.isEmpty
              ? const Center(
                  child: Text('Ask anything about your notes'))
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(12),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    final message = _messages[index];
                    final selection =
                        index < _selections.length ? _selections[index] : null;
                    final showSources = message.role == 'assistant' &&
                        message.content.trim().isNotEmpty &&
                        !message.content.startsWith('⚠') &&
                        selection != null;
                    if (!showSources) {
                      return ChatBubble(
                        message: message,
                        onSpeak: (text) =>
                        unawaited(_speech.speak(text, rate: _currentSpeechRate())),
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ChatBubble(
                          message: message,
                          onSpeak: (text) =>
                        unawaited(_speech.speak(text, rate: _currentSpeechRate())),
                        ),
                        _SourcesRow(
                          selection: selection,
                          reply: message.content,
                          onOpenNote: (note) =>
                              Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => NoteDetailScreen(note: note),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendQuestion(notes),
                    decoration: const InputDecoration(
                      hintText: 'Ask about your notes…',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _streaming
                    ? IconButton.filledTonal(
                        tooltip: 'Stop',
                        onPressed: _stop,
                        icon: const Icon(Icons.stop),
                      )
                    : IconButton.filled(
                        tooltip: 'Send',
                        onPressed: () => _sendQuestion(notes),
                        icon: const Icon(Icons.send_outlined),
                      ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Sources row under a grounded reply: maps the `[nX]` ids the model cited
/// to the actual notes, as tappable chips. Ids the model invented that
/// aren't in the selection are silently skipped.
class _SourcesRow extends StatelessWidget {
  const _SourcesRow({
    required this.selection,
    required this.reply,
    required this.onOpenNote,
  });

  final ContextSelection selection;
  final String reply;
  final void Function(NoteRow note) onOpenNote;

  @override
  Widget build(BuildContext context) {
    final cited = RegExp(r'\[(n\d+)\]')
        .allMatches(reply)
        .map((m) => m.group(1)!)
        .toSet();
    final sources = selection.notes
        .where((entry) => cited.contains(entry.citationId))
        .toList();
    if (sources.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            'Sources',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
          for (final entry in sources)
            ActionChip(
              visualDensity: VisualDensity.compact,
              label: Text(
                '${entry.citationId} · ${formatShort(entry.note.createdDateTime)}',
              ),
              onPressed: () => onOpenNote(entry.note),
            ),
        ],
      ),
    );
  }
}

class _CenterPrompt extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _CenterPrompt({
    required this.icon,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (actionLabel != null) ...[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
