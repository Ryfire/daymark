import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/rewrite_prompts.dart';
import '../data/settings_repository.dart';
import '../providers.dart';
import 'llm_client.dart';
import 'llm_config.dart';

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  return SettingsRepository(ref.watch(databaseProvider));
});

/// Quick-rewrite prompts, live-updating as the settings editor changes
/// them. Falls back to the defaults when the key is absent or corrupt.
final rewritePromptsProvider = StreamProvider<List<RewritePrompt>>((ref) {
  final repo = ref.watch(settingsRepositoryProvider);
  return repo.watchString(RewritePrompt.settingsKey).map(
        (raw) => parseRewritePrompts(raw) ??
            List.unmodifiable(RewritePrompt.defaults),
      );
});

/// The configured provider, live-updating as the user edits settings.
/// Null while unconfigured (or if the stored blob is corrupt).
final llmConfigProvider = StreamProvider<LlmConfig?>((ref) {
  final repo = ref.watch(settingsRepositoryProvider);
  return repo
      .watchString(LlmConfig.settingsKey)
      .map((raw) => LlmConfig.fromJsonString(raw));
});

/// Builds a client for a resolved config; null when unconfigured. Shared
/// by [llmClientProvider] and the one-shot fallback below.
LlmClient? clientForConfig(LlmConfig? config) {
  if (config == null) return null;
  return OpenAiCompatClient(
    baseUrl: config.baseUrl,
    apiKey: config.apiKey,
    defaultModel: config.model,
  );
}

/// A client for the current config. Rebuilt whenever the config changes so
/// in-flight state never leaks across provider edits. Null while
/// unconfigured.
final llmClientProvider = Provider<LlmClient?>((ref) {
  final client = clientForConfig(ref.watch(llmConfigProvider).value);
  if (client == null) return null;
  ref.onDispose(client.close);
  return client;
});

/// One-shot client for imperative cold-start flows (the rewrite screens).
/// It reads the config straight from the database: unlike the watched
/// [llmConfigProvider] — whose stream Riverpod pauses when nothing
/// listens, hanging a bare `.future` await before its first emission —
/// this future always completes. Null while unconfigured.
final llmClientFallbackProvider = FutureProvider<LlmClient?>((ref) async {
  final config = LlmConfig.fromJsonString(
    await ref
        .watch(settingsRepositoryProvider)
        .getString(LlmConfig.settingsKey),
  );
  final client = clientForConfig(config);
  if (client != null) ref.onDispose(client.close);
  return client;
});
