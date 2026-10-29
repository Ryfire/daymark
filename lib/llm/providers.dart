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

/// A client for the current config. Rebuilt whenever the config changes so
/// in-flight state never leaks across provider edits. Null while
/// unconfigured.
final llmClientProvider = Provider<LlmClient?>((ref) {
  final config = ref.watch(llmConfigProvider).value;
  if (config == null) return null;
  final client = OpenAiCompatClient(
    baseUrl: config.baseUrl,
    apiKey: config.apiKey,
    defaultModel: config.model,
  );
  ref.onDispose(client.close);
  return client;
});
