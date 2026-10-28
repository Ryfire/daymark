import 'package:flutter_test/flutter_test.dart';

import 'package:daymark/llm/llm_config.dart';

void main() {
  group('normalizeBaseUrl', () {
    test('appends /v1 when the URL has no path', () {
      expect(
        LlmConfig.normalizeBaseUrl('http://192.168.1.20:11434'),
        'http://192.168.1.20:11434/v1',
      );
    });

    test('keeps an explicit /v1 path intact', () {
      expect(
        LlmConfig.normalizeBaseUrl('http://localhost:1237/v1'),
        'http://localhost:1237/v1',
      );
    });

    test('strips trailing slashes', () {
      expect(
        LlmConfig.normalizeBaseUrl('http://localhost:1237/v1/'),
        'http://localhost:1237/v1',
      );
      expect(
        LlmConfig.normalizeBaseUrl('http://localhost:1237///'),
        'http://localhost:1237/v1',
      );
    });

    test('trims whitespace', () {
      expect(
        LlmConfig.normalizeBaseUrl('  https://api.example.com/v1  '),
        'https://api.example.com/v1',
      );
    });

    test('rejects non-http schemes', () {
      expect(
        () => LlmConfig.normalizeBaseUrl('ftp://example.com'),
        throwsA(isA<LlmConfigException>()),
      );
    });

    test('rejects garbage input', () {
      expect(
        () => LlmConfig.normalizeBaseUrl('not a url'),
        throwsA(isA<LlmConfigException>()),
      );
      expect(
        () => LlmConfig.normalizeBaseUrl(''),
        throwsA(isA<LlmConfigException>()),
      );
    });
  });

  group('JSON roundtrip', () {
    test('survives encode/decode', () {
      const config = LlmConfig(
        baseUrl: 'http://192.168.1.20:11434/v1',
        apiKey: 'sk-test',
        model: 'llama3.2:3b',
      );
      final parsed = LlmConfig.fromJsonString(config.toJsonString());
      expect(parsed, config);
    });

    test('absent and corrupt blobs decode to null', () {
      expect(LlmConfig.fromJsonString(null), isNull);
      expect(LlmConfig.fromJsonString(''), isNull);
      expect(LlmConfig.fromJsonString('not json'), isNull);
      expect(LlmConfig.fromJsonString('["array"]'), isNull);
      expect(LlmConfig.fromJsonString('{"apiKey":"no baseUrl"}'), isNull);
    });

    test('missing optional fields default to empty', () {
      final parsed =
          LlmConfig.fromJsonString('{"baseUrl":"http://x/v1"}');
      expect(parsed?.apiKey, '');
      expect(parsed?.model, '');
    });
  });
}
