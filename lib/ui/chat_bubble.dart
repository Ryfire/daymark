import 'package:flutter/material.dart';

import '../llm/llm_client.dart';

/// One chat message bubble, shared by playground and grounded ask screens.
/// Assistant errors are rendered in the error container when the content
/// starts with the warning marker. [onSpeak] adds a speaker button to
/// completed assistant replies; user messages and error bubbles never
/// speak (a whole-bubble tap is not used because SelectableText owns
/// those gestures for text selection).
class ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final void Function(String text)? onSpeak;

  const ChatBubble({super.key, required this.message, this.onSpeak});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isUser = message.role == 'user';
    final isError = message.content.startsWith('⚠');
    final bubbleColor = isUser
        ? scheme.primaryContainer
        : isError
            ? scheme.errorContainer
            : scheme.surfaceContainerHighest;
    final textColor = isUser
        ? scheme.onPrimaryContainer
        : isError
            ? scheme.onErrorContainer
            : scheme.onSurface;
    final canSpeak = !isUser &&
        !isError &&
        onSpeak != null &&
        message.content.trim().isNotEmpty;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.85,
        ),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: SelectableText(
                message.content,
                style: TextStyle(color: textColor),
              ),
            ),
            if (canSpeak) ...[
              const SizedBox(width: 4),
              SizedBox(
                width: 28,
                height: 28,
                child: IconButton(
                  tooltip: 'Speak',
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  onPressed: () => onSpeak!(message.content),
                  icon: const Icon(Icons.volume_up_outlined),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
