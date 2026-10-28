import 'dart:convert';

/// One user-configured OpenAI-compatible provider. There are no built-in
/// provider presets: the user names their own endpoint (Ollama, LM Studio,
/// a cloud gateway, llama.cpp server, ...) and Daymark speaks plain
/// OpenAI-compatible HTTP to it.
///
/// [baseUrl] must point at the API root, e.g. `http://192.168.1.20:11434/v1`.
/// If the URL has no path at all, `/v1` is appended as a convenience.
class LlmConfig {
  static const settingsKey = 'llm.default';

  final String baseUrl;
  final String apiKey;
  final String model;

  const LlmConfig({
    required this.baseUrl,
    this.apiKey = '',
    this.model = '',
  });

  bool get hasModel => model.trim().isNotEmpty;

  /// Normalizes the base URL: trims whitespace, strips trailing slashes,
  /// and appends `/v1` when the URL carries no path component.
  static String normalizeBaseUrl(String raw) {
    var url = raw.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    final parsed = Uri.tryParse(url);
    if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
      throw LlmConfigException('Not a valid URL: "$raw"');
    }
    if (parsed.scheme != 'http' && parsed.scheme != 'https') {
      throw LlmConfigException('URL must be http(s): "$raw"');
    }
    if ((parsed.path.isEmpty || parsed.path == '/') &&
        parsed.query.isEmpty &&
        parsed.fragment.isEmpty) {
      url = '$url/v1';
    }
    return url;
  }

  LlmConfig copyWith({String? baseUrl, String? apiKey, String? model}) =>
      LlmConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
      );

  /// Parses a stored config; returns null when absent or corrupt so a bad
  /// write never bricks the settings screen.
  static LlmConfig? fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw);
      if (map is! Map<String, dynamic>) return null;
      final base = map['baseUrl'];
      if (base is! String || base.isEmpty) return null;
      return LlmConfig(
        baseUrl: base,
        apiKey: map['apiKey'] is String ? map['apiKey'] as String : '',
        model: map['model'] is String ? map['model'] as String : '',
      );
    } catch (_) {
      return null;
    }
  }

  String toJsonString() => jsonEncode({
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
      });

  @override
  bool operator ==(Object other) =>
      other is LlmConfig &&
      other.baseUrl == baseUrl &&
      other.apiKey == apiKey &&
      other.model == model;

  @override
  int get hashCode => Object.hash(baseUrl, apiKey, model);
}

class LlmConfigException implements Exception {
  final String message;
  const LlmConfigException(this.message);

  @override
  String toString() => message;
}
