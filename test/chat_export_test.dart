import 'package:flutter_test/flutter_test.dart';

import 'package:daymark/core/chat_export.dart';
import 'package:daymark/llm/llm_client.dart';

void main() {
  final exportedAt = DateTime(2026, 10, 31, 10, 55);

  test('renders turns with ask times under an export-time header', () {
    final transcript = buildChatTranscript(
      [
        ChatMessage.user('when did I plant tomatoes'),
        ChatMessage.assistant('The tomatoes were planted [n1].'),
      ],
      [DateTime(2026, 10, 31, 9, 30), DateTime(2026, 10, 31, 9, 30)],
      exportedAt: exportedAt,
    );
    expect(
      transcript,
      startsWith('# Ask session — Sat, Oct 31, 2026 · 10:55'),
    );
    expect(
      transcript,
      contains('## You · 09:30\nwhen did I plant tomatoes\n'),
    );
    expect(
      transcript,
      contains('## Daymark · 09:30\nThe tomatoes were planted [n1].\n'),
    );
  });

  test('skips system messages and empty placeholders', () {
    final transcript = buildChatTranscript(
      [
        ChatMessage.system('grounding prompt'),
        ChatMessage.assistant(''),
        ChatMessage.user('hi'),
      ],
      [
        DateTime(2026, 10, 31, 9, 0),
        DateTime(2026, 10, 31, 9, 0),
        DateTime(2026, 10, 31, 9, 0),
      ],
      exportedAt: exportedAt,
    );
    expect(transcript, isNot(contains('grounding prompt')));
    expect(transcript, isNot(contains('## Daymark')));
    expect(transcript, contains('## You · 09:00\nhi\n'));
  });

  test('turns without a time omit the clock suffix', () {
    final transcript = buildChatTranscript(
      [ChatMessage.user('hi')],
      const [],
      exportedAt: exportedAt,
    );
    expect(transcript, contains('## You\nhi\n'));
    expect(transcript, isNot(contains('## You ·')));
  });
}