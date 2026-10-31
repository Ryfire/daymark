import 'package:flutter/material.dart';

import '../llm/llm_client.dart';

/// One chat message bubble, shared by playground and grounded ask screens.
/// Assistant errors are rendered in the error container when the content
/// starts with the warning marker. [onSpeak] adds a speaker button to
/// completed assistant replies; user messages and error bubbles never
/// speak (a whole-bubble tap is not used because SelectableText owns
/// those gestures for text selection).
///
/// [onCopy] / [onShare] / [onSendToJotlock] add a dotted-menu button next
/// to completed replies — the same share handoff the note detail screen
/// offers. Screens that don't pass them show no menu button.
class ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final void Function(String text)? onSpeak;
  final void Function(String text)? onCopy;
  final Future<void> Function(String text)? onShare;
  final Future<void> Function(String text)? onSendToJotlock;

  const ChatBubble({
    super.key,
    required this.message,
    this.onSpeak,
    this.onCopy,
    this.onShare,
    this.onSendToJotlock,
  });

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
    final canHandOff = !isUser &&
        !isError &&
        onCopy != null &&
        onShare != null &&
        onSendToJotlock != null &&
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
                // Long-press opens the native selection toolbar with our
                // hand-off items appended. The native Share (when the
                // platform offers one) is dropped in favor of ours, which
                // goes through the same hardened channel as everywhere
                // else in the app.
                contextMenuBuilder: canHandOff
                    ? (context, editableTextState) =>
                        AdaptiveTextSelectionToolbar.buttonItems(
                          anchors: editableTextState.contextMenuAnchors,
                          buttonItems: [
                            // Drop the native Share item (built with a
                            // null label and ContextMenuButtonType.share)
                            // in favor of ours, which goes through the
                            // same hardened channel as everywhere else.
                            ...editableTextState.contextMenuButtonItems.where(
                              (item) => item.type != ContextMenuButtonType.share,
                            ),
                            ContextMenuButtonItem(
                              label: 'Share',
                              onPressed: () {
                                ContextMenuController.removeAny();
                                onShare!(message.content);
                              },
                            ),
                            ContextMenuButtonItem(
                              label: 'Send to JotLock',
                              onPressed: () {
                                ContextMenuController.removeAny();
                                onSendToJotlock!(message.content);
                              },
                            ),
                          ],
                        )
                    : null,
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
            if (canHandOff) ...[
              const SizedBox(width: 4),
              SizedBox(
                width: 28,
                height: 28,
                child: PopupMenuButton<String>(
                  tooltip: 'Reply options',
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  onSelected: (value) {
                    if (value == 'copy') onCopy!(message.content);
                    if (value == 'share') onShare!(message.content);
                    if (value == 'jotlock') onSendToJotlock!(message.content);
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: 'copy',
                      child: ListTile(
                        leading: Icon(Icons.copy_outlined),
                        title: Text('Copy'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'share',
                      child: ListTile(
                        leading: Icon(Icons.share_outlined),
                        title: Text('Share'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'jotlock',
                      child: ListTile(
                        leading: Icon(Icons.send_outlined),
                        title: Text('Send to JotLock'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}