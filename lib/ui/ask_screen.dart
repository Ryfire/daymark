import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/chat_export.dart';
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

  /// When each message was added (the ask time), parallel to [_messages].
  final _times = <DateTime>[];

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

  /// Copies a whole reply to the clipboard — the same handoff the note
  /// detail screen offers. Fire-and-forget: the platform-channel reply
  /// can stall under fake_async (widget tests) and there is nothing
  /// actionable on failure.
  void _copyReply(String text) {
    final messenger = ScaffoldMessenger.of(context);
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    messenger.showSnackBar(
      const SnackBar(content: Text('Copied to clipboard')),
    );
  }

  /// Shares a reply through the system share sheet — the same handoff the
  /// note detail screen offers, offered when the reply bubble is held.
  Future<void> _shareReply(String text) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await ref.read(jotlockSenderProvider).shareText(text);
    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not share')),
      );
    }
  }

  /// Hands a reply to JotLock as a NEW note (append-only): jotlock's
  /// editor opens pre-filled and the user confirms the save there.
  Future<void> _sendReplyToJotlock(String text) async {
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await ref.read(jotlockSenderProvider).sendNote(text);
    messenger.showSnackBar(
      SnackBar(content: Text(outcome.message)),
    );
  }

  /// The whole session as a markdown transcript — the payload behind the
  /// Copy chat / Share chat / Export chat actions.
  String get _transcript => buildChatTranscript(
        _messages,
        _times,
        exportedAt: DateTime.now(),
      );

  bool get _hasConversation =>
      _messages.any((m) => m.content.trim().isNotEmpty);

  /// Copies the whole transcript to the clipboard. Fire-and-forget: the
  /// platform-channel reply can stall under fake_async (widget tests).
  void _copyChat() {
    final messenger = ScaffoldMessenger.of(context);
    unawaited(Clipboard.setData(ClipboardData(text: _transcript)));
    messenger.showSnackBar(
      const SnackBar(content: Text('Chat copied to clipboard')),
    );
  }

  /// Opens the system share sheet with the transcript as text. Only a
  /// failure is announced; the sheet itself is the success feedback.
  Future<void> _shareChat() async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await ref.read(jotlockSenderProvider).shareText(_transcript);
    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not share')),
      );
    }
  }

  /// Saves the transcript as a markdown file at a location the user picks
  /// via the system file picker. Silence means the picker was cancelled.
  Future<void> _exportChat() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final stamp = DateTime.now();
      final fileName = 'daymark-ask-'
          '${stamp.year.toString().padLeft(4, '0')}-'
          '${stamp.month.toString().padLeft(2, '0')}-'
          '${stamp.day.toString().padLeft(2, '0')}-'
          '${formatTime(stamp).replaceAll(':', '')}.md';
      final uri = await FilePicker.saveFile(
        fileName: fileName,
        bytes: Uint8List.fromList(utf8.encode(_transcript)),
        mimeType: 'text/markdown',
      );
      if (uri == null) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Chat exported')),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not export chat')),
      );
    }
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
      final now = DateTime.now();
      _messages.add(ChatMessage.user(text));
      _selections.add(null);
      _times.add(now);
      _messages.add(const ChatMessage.assistant(''));
      _selections.add(selection);
      _times.add(now);
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
            _times.add(DateTime.now());
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
            _times.removeLast();
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
        actions: [
          const SpeedButton(),
          const AutoplayToggle(),
          PopupMenuButton<String>(
            tooltip: 'Chat options',
            onSelected: (value) {
              if (value == 'copy') _copyChat();
              if (value == 'share') _shareChat();
              if (value == 'export') _exportChat();
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'copy',
                enabled: _hasConversation,
                child: ListTile(
                  leading: const Icon(Icons.copy_outlined),
                  title: const Text('Copy chat'),
                ),
              ),
              PopupMenuItem(
                value: 'share',
                enabled: _hasConversation,
                child: ListTile(
                  leading: const Icon(Icons.share_outlined),
                  title: const Text('Share chat'),
                ),
              ),
              PopupMenuItem(
                value: 'export',
                enabled: _hasConversation,
                child: ListTile(
                  leading: const Icon(Icons.file_download_outlined),
                  title: const Text('Export chat (.md)'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: notesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Could not load notes: $error')),
        data: (notes) {
          // Cold-start race: the config watch stream is briefly still
          // loading after a restart. Spinner until it lands; the prompt
          // only once it has loaded and really is null.
          final configAsync = ref.watch(llmConfigProvider);
          if (configAsync.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (configAsync.value == null) {
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
                        onCopy: _copyReply,
                        onShare: _shareReply,
                        onSendToJotlock: _sendReplyToJotlock,
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ChatBubble(
                          message: message,
                          onSpeak: (text) =>
                        unawaited(_speech.speak(text, rate: _currentSpeechRate())),
                          onCopy: _copyReply,
                          onShare: _shareReply,
                          onSendToJotlock: _sendReplyToJotlock,
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
