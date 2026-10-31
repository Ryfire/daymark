import '../llm/llm_client.dart';
import 'timeline.dart';

/// Builds a markdown transcript of an Ask session: one section per turn
/// with its ask-time, under a header stamped with [exportedAt]. System
/// messages and empty placeholders are skipped. [times] runs parallel to
/// [messages]; turns without a time simply omit the clock suffix.
String buildChatTranscript(
  List<ChatMessage> messages,
  List<DateTime?> times, {
  required DateTime exportedAt,
}) {
  final buffer = StringBuffer()
    ..writeln('# Ask session — ${formatFull(exportedAt)}')
    ..writeln();
  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    if (message.role != 'user' && message.role != 'assistant') continue;
    final content = message.content.trim();
    if (content.isEmpty) continue;
    final who = message.role == 'user' ? 'You' : 'Daymark';
    final time = i < times.length ? times[i] : null;
    final stamp = time == null ? '' : ' · ${formatTime(time)}';
    buffer
      ..writeln('## $who$stamp')
      ..writeln(content)
      ..writeln();
  }
  return buffer.toString();
}