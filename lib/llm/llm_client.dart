import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_config.dart';

/// A chat message as sent to the provider. Role is one of
/// 'system', 'user', 'assistant'.
class ChatMessage {
  final String role;
  final String content;

  const ChatMessage({required this.role, required this.content});

  const ChatMessage.system(String content)
      : this(role: 'system', content: content);
  const ChatMessage.user(String content)
      : this(role: 'user', content: content);
  const ChatMessage.assistant(String content)
      : this(role: 'assistant', content: content);

  Map<String, dynamic> toJson() => {'role': role, 'content': content};

  @override
  bool operator ==(Object other) =>
      other is ChatMessage && other.role == role && other.content == content;

  @override
  int get hashCode => Object.hash(role, content);
}

/// Provider-agnostic LLM surface. The only implementation for now speaks
/// OpenAI-compatible HTTP; a local llama.cpp client (on-device, v2) will
/// implement the same interface, at which point call sites should not care
/// which backend is behind it.
abstract class LlmClient {
  /// Model ids advertised by the endpoint (GET /models).
  Future<List<String>> listModels();

  /// Single-shot completion of [messages] (POST /chat/completions).
  Future<String> complete({
    required List<ChatMessage> messages,
    String? model,
  });

  /// Token-delta stream from a streaming completion. Errors surface as
  /// stream errors; the stream completes after the final token.
  Stream<String> streamChat({
    required List<ChatMessage> messages,
    String? model,
  });

  /// Cancels any in-flight request made by this client, ending active
  /// streams early.
  void close();
}

/// Thrown for user-actionable provider failures. [body] carries a truncated
/// response body when the server answered with an error page.
class LlmApiException implements Exception {
  final int statusCode;
  final String body;

  const LlmApiException(this.statusCode, [this.body = '']);

  bool get isAuth => statusCode == 401 || statusCode == 403;

  String get message {
    if (isAuth) return 'Rejected: auth failed (HTTP $statusCode)';
    if (statusCode == 404) return 'Endpoint or model not found (HTTP 404)';
    return 'Server error (HTTP $statusCode)${body.isEmpty ? '' : ': $body'}';
  }

  @override
  String toString() => message;
}

class LlmNetworkException implements Exception {
  final String message;
  const LlmNetworkException(this.message);

  @override
  String toString() => message;
}

/// OpenAI-compatible HTTP client (Ollama, LM Studio, llama.cpp server,
/// OpenAI itself, and most gateways all speak this dialect).
class OpenAiCompatClient implements LlmClient {
  final String baseUrl;
  final String apiKey;
  final String defaultModel;
  final http.Client _http;

  OpenAiCompatClient({
    required this.baseUrl,
    this.apiKey = '',
    this.defaultModel = '',
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  Uri _endpoint(String path) {
    final base = LlmConfig.normalizeBaseUrl(baseUrl);
    return Uri.parse('$base$path');
  }

  Map<String, String> _headers() => {
        'Content-Type': 'application/json',
        if (apiKey.trim().isNotEmpty) 'Authorization': 'Bearer ${apiKey.trim()}',
      };

  @override
  Future<List<String>> listModels() async {
    http.Response response;
    try {
      response = await _http
          .get(_endpoint('/models'), headers: _headers())
          .timeout(const Duration(seconds: 20));
    } catch (e) {
      throw _asNetwork(e, 'Could not reach $baseUrl');
    }
    if (response.statusCode != 200) {
      throw LlmApiException(response.statusCode, _truncate(response.body));
    }
    return decodeModelList(response.body);
  }

  @override
  Future<String> complete({
    required List<ChatMessage> messages,
    String? model,
  }) async {
    http.Response response;
    try {
      response = await _http
          .post(
            _endpoint('/chat/completions'),
            headers: _headers(),
            body: jsonEncode({
              'model': model ?? defaultModel,
              'messages': messages.map((m) => m.toJson()).toList(),
            }),
          )
          .timeout(const Duration(seconds: 300));
    } catch (e) {
      throw _asNetwork(e, 'Could not reach $baseUrl');
    }
    if (response.statusCode != 200) {
      throw LlmApiException(response.statusCode, _truncate(response.body));
    }
    return extractCompletionContent(response.body);
  }

  @override
  Stream<String> streamChat({
    required List<ChatMessage> messages,
    String? model,
  }) async* {
    http.StreamedResponse response;
    try {
      final request = http.Request(
        'POST',
        _endpoint('/chat/completions'),
      )
        ..headers.addAll(_headers())
        ..body = jsonEncode({
          'model': model ?? defaultModel,
          'messages': messages.map((m) => m.toJson()).toList(),
          'stream': true,
        });
      response = await _http
          .send(request)
          .timeout(const Duration(seconds: 60));
    } catch (e) {
      throw _asNetwork(e, 'Could not reach $baseUrl');
    }
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw LlmApiException(response.statusCode, _truncate(body));
    }

    final parser = SseDeltaParser();
    await for (final line in response.stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())) {
      for (final delta in parser.push(line)) {
        yield delta;
      }
    }
  }

  @override
  void close() => _http.close();

  LlmNetworkException _asNetwork(Object e, String context) {
    if (e is LlmApiException) throw e;
    final detail = e is TimeoutException ? 'timed out' : e.toString();
    return LlmNetworkException('$context ($detail)');
  }

  static String _truncate(String body) =>
      body.length <= 400 ? body : '${body.substring(0, 400)}…';
}

/// Incremental parser for the `data:` SSE lines of a streaming
/// chat completion. Feeding it raw lines (with or without the
/// `data: ` prefix) yields assistant deltas; `[DONE]` ends the stream.
class SseDeltaParser {
  static const _done = '[DONE]';
  final StringBuffer _carry = StringBuffer();
  bool _doneSeen = false;

  bool get doneSeen => _doneSeen;

  List<String> push(String rawLine) {
    if (_doneSeen) return const [];
    var line = rawLine.trimRight();
    if (line.isEmpty) return const [];
    if (line.startsWith('data:')) {
      line = line.substring(5).trim();
    } else if (_carry.isEmpty && !line.startsWith('{')) {
      return const [];
    }
    if (line == _done) {
      _doneSeen = true;
      return const [];
    }
    // SSE frames are newline-delimited, but a JSON payload is never split
    // across `data:` lines by the servers we target; carry is defensive only.
    if (line.startsWith('{') && !line.endsWith('}')) {
      _carry.write(line);
      return const [];
    }
    if (_carry.isNotEmpty) {
      _carry.write(line);
      line = _carry.toString();
      _carry.clear();
    }
    try {
      final map = jsonDecode(line);
      if (map is! Map<String, dynamic>) return const [];
      final delta = extractDelta(map);
      return delta.isEmpty ? const [] : [delta];
    } catch (_) {
      return const [];
    }
  }
}

/// Extracts `choices[0].delta.content` from one streamed frame; tolerates
/// missing/absent fields across dialects.
String extractDelta(Map<String, dynamic> frame) {
  final choices = frame['choices'];
  if (choices is! List || choices.isEmpty) return '';
  final first = choices.first;
  if (first is! Map<String, dynamic>) return '';
  final delta = first['delta'];
  if (delta is! Map<String, dynamic>) return '';
  final content = delta['content'];
  return content is String ? content : '';
}

/// Parses the JSON body of a non-streaming completion into the assistant
/// text (`choices[0].message.content`).
String extractCompletionContent(String responseBody) {
  final decoded = jsonDecode(responseBody);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Unexpected completion body');
  }
  final choices = decoded['choices'];
  if (choices is! List || choices.isEmpty) {
    throw const FormatException('Completion has no choices');
  }
  final choice = choices.first;
  if (choice is! Map<String, dynamic>) {
    throw const FormatException('Malformed choice entry');
  }
  final message = choice['message'];
  if (message is! Map<String, dynamic>) {
    throw const FormatException('Choice has no message');
  }
  final content = message['content'];
  if (content is! String) {
    throw const FormatException('Completion has no text content');
  }
  return content;
}

/// Parses a `/models` response body into sorted model ids.
List<String> decodeModelList(String responseBody) {
  final decoded = jsonDecode(responseBody);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Unexpected models body');
  }
  final data = decoded['data'];
  if (data is! List) {
    throw const FormatException('Models body has no data array');
  }
  final ids = <String>[];
  for (final entry in data) {
    if (entry is Map<String, dynamic> && entry['id'] is String) {
      ids.add(entry['id'] as String);
    }
  }
  ids.sort();
  return ids;
}
