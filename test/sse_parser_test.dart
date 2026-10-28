import 'package:flutter_test/flutter_test.dart';

import 'package:daymark/llm/llm_client.dart';

void main() {
  group('SseDeltaParser', () {
    test('extracts content deltas from data lines', () {
      final parser = SseDeltaParser();
      expect(parser.push('data: {"choices":[{"delta":{"content":"He"}}]}'),
          ['He']);
      expect(parser.push('data: {"choices":[{"delta":{"content":"llo"}}]}'),
          ['llo']);
    });

    test('recognizes [DONE] and stops emitting afterwards', () {
      final parser = SseDeltaParser();
      expect(parser.push('data: {"choices":[{"delta":{"content":"x"}}]}'),
          ['x']);
      expect(parser.push('data: [DONE]'), isEmpty);
      expect(parser.doneSeen, isTrue);
      expect(parser.push('data: {"choices":[{"delta":{"content":"y"}}]}'),
          isEmpty);
    });

    test('ignores blank lines and non-data chatter', () {
      final parser = SseDeltaParser();
      expect(parser.push(''), isEmpty);
      expect(parser.push(': keep-alive comment'), isEmpty);
      expect(parser.push('event: ping'), isEmpty);
    });

    test('tolerates frames without content (role-only first frame)', () {
      final parser = SseDeltaParser();
      expect(
        parser.push('data: {"choices":[{"delta":{"role":"assistant"}}]}'),
        isEmpty,
      );
    });

    test('tolerates malformed JSON without throwing', () {
      final parser = SseDeltaParser();
      expect(parser.push('data: {broken'), isEmpty);
    });

    test('handles \r\n line endings', () {
      final parser = SseDeltaParser();
      expect(parser.push('data: {"choices":[{"delta":{"content":"a"}}]}\r'),
          ['a']);
    });
  });
}
