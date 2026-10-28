import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:daymark/llm/llm_client.dart';

/// A tiny OpenAI-compatible server standing in for the provider under test.
class FakeProvider {
  late final HttpServer _server;
  late final String baseUrl;
  String? lastAuthHeader;
  Map<String, dynamic>? lastChatBody;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${_server.port}/v1';
    _server.listen(_handle);
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    lastAuthHeader = request.headers.value('Authorization');
    if (request.uri.path == '/v1/models') {
      _json(request, {
        'data': [
          {'id': 'zeta'},
          {'id': 'alpha'},
          {'id': 'mid'},
          {'id': 42},
        ],
      });
    } else if (request.uri.path == '/v1/chat/completions') {
      final body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      lastChatBody = body;
      if (body['model'] == 'missing-model') {
        _json(request, {'error': {'message': 'model not found'}},
            status: 404);
        return;
      }
      if (body['stream'] == true) {
        request.response.headers
            .set(HttpHeaders.contentTypeHeader, 'text/event-stream');
        request.response.write('data: ${jsonEncode({
              'choices': [
                {'delta': {'content': 'Hel'}}
              ],
            })}\n\n');
        request.response.write('data: ${jsonEncode({
              'choices': [
                {'delta': {'content': 'lo world'}}
              ],
            })}\n\n');
        request.response.write('\n');
        request.response.write('data: [DONE]\n\n');
        await request.response.flush();
        await request.response.close();
      } else {
        _json(request, {
          'choices': [
            {
              'message': {'content': 'Hello world'}
            }
          ],
        });
      }
    } else {
      _json(request, {'error': 'no route'}, status: 404);
    }
  }

  void _json(HttpRequest request, Object body, {int status = 200}) {
    request.response.statusCode = status;
    request.response.headers
        .set(HttpHeaders.contentTypeHeader, 'application/json');
    request.response.write(jsonEncode(body));
    request.response.close();
  }
}

void main() {
  late FakeProvider provider;
  late OpenAiCompatClient client;

  setUp(() async {
    provider = FakeProvider();
    await provider.start();
    client = OpenAiCompatClient(
      baseUrl: provider.baseUrl,
      apiKey: 'test-key',
      defaultModel: 'alpha',
    );
  });

  tearDown(() async {
    client.close();
    await provider.close();
  });

  test('listModels returns sorted ids, skipping non-string entries',
      () async {
    final models = await client.listModels();
    expect(models, ['alpha', 'mid', 'zeta']);
  });

  test('listModels sends bearer auth', () async {
    await client.listModels();
    expect(provider.lastAuthHeader, 'Bearer test-key');
  });

  test('complete posts model + messages and returns content', () async {
    final reply = await client.complete(messages: const [
      ChatMessage.user('hi'),
    ]);
    expect(reply, 'Hello world');
    expect(provider.lastChatBody?['model'], 'alpha');
    expect(provider.lastChatBody?['stream'], isNull);
    final messages = provider.lastChatBody?['messages'] as List;
    expect(messages.single['role'], 'user');
    expect(messages.single['content'], 'hi');
  });

  test('complete can override the model', () async {
    await client.complete(
      messages: const [ChatMessage.user('hi')],
      model: 'override-model',
    );
    expect(provider.lastChatBody?['model'], 'override-model');
  });

  test('streamChat yields deltas in order and stops at [DONE]', () async {
    final deltas = await client
        .streamChat(messages: const [ChatMessage.user('hi')])
        .toList();
    expect(deltas, ['Hel', 'lo world']);
    expect(provider.lastChatBody?['stream'], isTrue);
  });

  test('a 404 from the server surfaces as LlmApiException', () async {
    await expectLater(
      client.complete(
        messages: const [ChatMessage.user('hi')],
        model: 'missing-model',
      ),
      throwsA(isA<LlmApiException>()
          .having((e) => e.statusCode, 'statusCode', 404)
          .having((e) => e.message, 'message', contains('model not found'))),
    );
  });

  test('a dead endpoint surfaces as LlmNetworkException', () async {
    final dead = OpenAiCompatClient(baseUrl: 'http://127.0.0.1:1/v1');
    addTearDown(dead.close);
    await expectLater(
      dead.listModels(),
      throwsA(isA<LlmNetworkException>()),
    );
  });
}
