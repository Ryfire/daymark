import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../llm/llm_client.dart';
import '../llm/providers.dart';
import '../tts/speech.dart';
import 'autoplay_toggle.dart';
import 'chat_bubble.dart';
import 'settings_screen.dart';

/// Ephemeral, ungrounded model chat: the provider smoke-test surface.
/// Nothing is persisted here; grounded, note-backed chat lives in the
/// ask screen.
class PlaygroundScreen extends ConsumerStatefulWidget {
  const PlaygroundScreen({super.key});

  @override
  ConsumerState<PlaygroundScreen> createState() => _PlaygroundScreenState();
}

class _PlaygroundScreenState extends ConsumerState<PlaygroundScreen> {
  final _messages = <ChatMessage>[];
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  StreamSubscription<String>? _subscription;
  bool _streaming = false;

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

  bool get _configured => ref.read(llmClientProvider) != null;

  void _send() {
    if (_streaming) return;
    final client = ref.read(llmClientProvider);
    if (client == null) return;
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _inputController.clear();
    unawaited(_speech.stop());

    setState(() {
      _messages.add(ChatMessage.user(text));
      _messages.add(const ChatMessage.assistant(''));
      _streaming = true;
    });
    _scrollToBottom();

    final history = _messages
        .take(_messages.length - 1)
        .where((m) => m.content.isNotEmpty)
        .toList();
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

  @override
  Widget build(BuildContext context) {
    if (!_configured) {
      return Scaffold(
        appBar: AppBar(title: const Text('Playground')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.send_outlined, size: 48),
              const SizedBox(height: 12),
              const Text('No LLM provider configured'),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _openSettings,
                child: const Text('Configure provider'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Playground'),
        actions: [
          const SpeedButton(),
          const AutoplayToggle(),
          IconButton(
            tooltip: 'Clear chat',
            onPressed: _streaming
                ? null
                : () => setState(_messages.clear),
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? const Center(child: Text('Talk to the configured model'))
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(12),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) => ChatBubble(
                      message: _messages[index],
                      onSpeak: (text) =>
                          unawaited(_speech.speak(
                              text, rate: _currentSpeechRate())),
                    ),
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
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'Message…',
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
                          onPressed: _send,
                          icon: const Icon(Icons.send_outlined),
                        ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
