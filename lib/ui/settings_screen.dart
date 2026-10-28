import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../llm/llm_client.dart';
import '../llm/llm_config.dart';
import '../llm/providers.dart';
import 'playground_screen.dart';

/// Configure the one and only provider slot: an OpenAI-compatible endpoint.
/// No presets — the user names their own server.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _baseUrlController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _modelController = TextEditingController();

  bool _seeded = false;
  bool _obscureKey = true;
  bool _saving = false;
  bool _testing = false;
  bool _loadingModels = false;
  List<String> _models = const [];
  String? _modelFetchError;

  @override
  void dispose() {
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  LlmConfig? _formConfig() {
    try {
      return LlmConfig(
        baseUrl: LlmConfig.normalizeBaseUrl(_baseUrlController.text),
        apiKey: _apiKeyController.text.trim(),
        model: _modelController.text.trim(),
      );
    } on LlmConfigException {
      return null;
    }
  }

  void _seedFromConfig(LlmConfig config) {
    _baseUrlController.text = config.baseUrl;
    _apiKeyController.text = config.apiKey;
    _modelController.text = config.model;
    _seeded = true;
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    LlmConfig config;
    try {
      config = LlmConfig(
        baseUrl: LlmConfig.normalizeBaseUrl(_baseUrlController.text),
        apiKey: _apiKeyController.text.trim(),
        model: _modelController.text.trim(),
      );
    } on LlmConfigException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    setState(() => _saving = true);
    try {
      await ref
          .read(settingsRepositoryProvider)
          .setString(LlmConfig.settingsKey, config.toJsonString());
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Provider saved: ${config.baseUrl}')),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not save settings')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _loadModels() async {
    final messenger = ScaffoldMessenger.of(context);
    final config = _formConfig();
    if (config == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Enter a valid base URL first')),
      );
      return;
    }
    setState(() {
      _loadingModels = true;
      _modelFetchError = null;
    });
    final client = OpenAiCompatClient(
      baseUrl: config.baseUrl,
      apiKey: config.apiKey,
    );
    try {
      final models = await client.listModels();
      if (!mounted) return;
      setState(() => _models = models);
    } on LlmApiException catch (e) {
      if (!mounted) return;
      setState(() => _modelFetchError = e.message);
    } on LlmNetworkException catch (e) {
      if (!mounted) return;
      setState(() => _modelFetchError = e.message);
    } finally {
      client.close();
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  Future<void> _testConnection() async {
    final messenger = ScaffoldMessenger.of(context);
    final config = _formConfig();
    if (config == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Enter a valid base URL first')),
      );
      return;
    }
    setState(() => _testing = true);
    final client = OpenAiCompatClient(
      baseUrl: config.baseUrl,
      apiKey: config.apiKey,
      defaultModel: config.model,
    );
    try {
      final String reply;
      if (config.hasModel) {
        reply = await client.complete(
          messages: [
            const ChatMessage.user(
                'Reply with exactly the word: ready'),
          ],
        );
      } else {
        final models = await client.listModels();
        reply = models.isEmpty ? 'no models listed' : models.first;
      }
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text('Connected. Server replied: ${_clip(reply)}'),
      ));
    } on LlmApiException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } on LlmNetworkException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Test failed: unexpected response')),
      );
    } finally {
      client.close();
      if (mounted) setState(() => _testing = false);
    }
  }

  String _clip(String s) {
    final t = s.trim().replaceAll('\n', ' ');
    return t.length <= 60 ? t : '${t.substring(0, 60)}…';
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(llmConfigProvider).value;
    if (!_seeded && config != null) _seedFromConfig(config);

    return Scaffold(
      appBar: AppBar(title: const Text('LLM provider')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Any OpenAI-compatible server works: Ollama, LM Studio, '
            'llama.cpp, or a cloud API gateway. Point at its API root '
            '(usually ending in /v1).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _baseUrlController,
            keyboardType: TextInputType.url,
            autofillHints: const [AutofillHints.url],
            decoration: const InputDecoration(
              labelText: 'Base URL',
              hintText: 'http://192.168.1.20:11434/v1',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _apiKeyController,
            obscureText: _obscureKey,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'API key (optional)',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                onPressed: () => setState(() => _obscureKey = !_obscureKey),
                icon: Icon(
                  _obscureKey
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _modelController,
                  decoration: const InputDecoration(
                    labelText: 'Model',
                    hintText: 'e.g. llama3.2:3b',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: _loadingModels
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : OutlinedButton.icon(
                        onPressed: _loadModels,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Fetch'),
                      ),
              ),
            ],
          ),
          if (_modelFetchError != null) ...[
            const SizedBox(height: 8),
            Text(
              _modelFetchError!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          ],
          if (_models.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final model in _models)
                  ActionChip(
                    label: Text(model),
                    onPressed: () =>
                        setState(() => _modelController.text = model),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: const Text('Save provider'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _testing ? null : _testConnection,
            icon: _testing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.network_check),
            label: const Text('Test connection'),
          ),
          const SizedBox(height: 24),
          if (config != null)
            Text(
              'Active: ${config.baseUrl}'
              '${config.hasModel ? ' · ${config.model}' : ' · no model set'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 24),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.science_outlined),
            title: const Text('Provider playground'),
            subtitle: const Text(
                'Ungrounded chat with the raw model, for testing settings'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PlaygroundScreen()),
            ),
          ),
        ],
      ),
    );
  }
}
