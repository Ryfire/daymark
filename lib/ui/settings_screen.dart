import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/rewrite_prompts.dart';
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
    var models = const <String>[];
    String? fetchError;
    try {
      models = await client.listModels();
    } on LlmApiException catch (e) {
      fetchError = e.message;
    } on LlmNetworkException catch (e) {
      fetchError = e.message;
    } catch (_) {
      fetchError = 'Could not fetch models';
    } finally {
      client.close();
      if (mounted) {
        setState(() {
          _loadingModels = false;
          _modelFetchError =
              fetchError ?? (models.isEmpty ? 'No models listed' : null);
        });
      }
    }
    if (fetchError != null || models.isEmpty || !mounted) return;
    // A searchable sheet instead of an inline chip list: it scales to
    // OpenRouter-sized catalogs (300+ ids) and puts the chosen id straight
    // into the Model field on tap — no scrolling back up to confirm.
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _ModelPickerSheet(
        models: models,
        currentModel: _modelController.text.trim(),
      ),
    );
    if (!mounted || selected == null) return;
    setState(() => _modelController.text = selected);
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
            const ChatMessage.user('Reply with exactly the word: ready'),
          ],
        );
      } else {
        final models = await client.listModels();
        reply = models.isEmpty ? 'no models listed' : models.first;
      }
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Connected. Server replied: ${_clip(reply)}')),
      );
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

  Future<void> _savePrompts(List<RewritePrompt> prompts) async {
    await ref
        .read(settingsRepositoryProvider)
        .setString(RewritePrompt.settingsKey, encodeRewritePrompts(prompts));
  }

  /// Add or edit one quick-rewrite prompt; null [existing] creates a new
  /// one. The prompts provider live-updates the list and the sheet.
  Future<void> _editPrompt([RewritePrompt? existing]) async {
    final messenger = ScaffoldMessenger.of(context);
    final labelController = TextEditingController(text: existing?.label ?? '');
    final promptController = TextEditingController(
      text: existing?.prompt ?? '',
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(existing == null ? 'Add prompt' : 'Edit prompt'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: labelController,
              decoration: const InputDecoration(
                labelText: 'Label',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: promptController,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'Prompt',
                hintText: 'What the model should do with the note',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    final label = labelController.text.trim();
    final prompt = promptController.text.trim();
    if (label.isEmpty || prompt.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Label and prompt are required')),
      );
      return;
    }
    final current =
        ref.read(rewritePromptsProvider).value ??
        List<RewritePrompt>.from(RewritePrompt.defaults);
    final next = existing == null
        ? [
            ...current,
            RewritePrompt(id: const Uuid().v4(), label: label, prompt: prompt),
          ]
        : [
            for (final p in current)
              p.id == existing.id
                  ? RewritePrompt(id: existing.id, label: label, prompt: prompt)
                  : p,
          ];
    await _savePrompts(next);
  }

  Future<void> _deletePrompt(RewritePrompt prompt) async {
    final current =
        ref.read(rewritePromptsProvider).value ??
        List<RewritePrompt>.from(RewritePrompt.defaults);
    await _savePrompts(current.where((p) => p.id != prompt.id).toList());
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(llmConfigProvider).value;
    // Seed only while the form is untouched, so an emission racing the
    // user's typing can never clobber it.
    if (!_seeded &&
        config != null &&
        _baseUrlController.text.isEmpty &&
        _apiKeyController.text.isEmpty &&
        _modelController.text.isEmpty) {
      _seedFromConfig(config);
    }
    final prompts = ref.watch(rewritePromptsProvider).value;

    return Scaffold(
      appBar: AppBar(title: const Text('LLM provider')),
      // SafeArea bottom: without it the last items (+ Add prompt) end up
      // under the system navigation bar on phones.
      body: SafeArea(
        top: false,
        child: ListView(
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
                'Ungrounded chat with the raw model, for testing settings',
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PlaygroundScreen()),
              ),
            ),
            const SizedBox(height: 24),
            const Divider(),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Quick rewrite prompts',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                TextButton(
                  onPressed: () => _savePrompts(RewritePrompt.defaults),
                  child: const Text('Restore defaults'),
                ),
              ],
            ),
            Text(
              'Long-press a note to rewrite it with one of these.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (prompts != null && prompts.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No prompts saved.'),
              )
            else
              Column(
                children: [
                  for (final prompt in prompts ?? const <RewritePrompt>[])
                    ListTile(
                      title: Text(prompt.label),
                      subtitle: Text(
                        prompt.prompt,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _editPrompt(prompt),
                      trailing: IconButton(
                        tooltip: 'Delete prompt',
                        onPressed: () => _deletePrompt(prompt),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ),
                ],
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _editPrompt,
              icon: const Icon(Icons.add),
              label: const Text('Add prompt'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Searchable model chooser shown after a successful Fetch. Virtualized
/// (ListView.builder) and sorted, so OpenRouter-sized lists (300+ ids)
/// scroll smoothly; returns the chosen id, or null when dismissed.
class _ModelPickerSheet extends StatefulWidget {
  const _ModelPickerSheet({
    required this.models,
    required this.currentModel,
  });

  final List<String> models;
  final String currentModel;

  @override
  State<_ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<_ModelPickerSheet> {
  final _searchController = TextEditingController();
  late final List<String> _sorted = [...widget.models]
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // Shrink for the keyboard and status bar so the list is never hidden
    // behind either; floor for very short windows.
    final height = math.max(
      240.0,
      math.min(
        media.size.height * 0.85,
        media.size.height - media.viewInsets.bottom - media.padding.top,
      ),
    );
    final query = _query.trim().toLowerCase();
    final filtered = query.isEmpty
        ? _sorted
        : _sorted
            .where((model) => model.toLowerCase().contains(query))
            .toList();
    return Padding(
      padding: EdgeInsets.only(
        top: media.padding.top,
        bottom: media.viewInsets.bottom,
      ),
      child: SizedBox(
        height: height,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Search models',
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  border: const OutlineInputBorder(),
                  suffixIcon: query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        ),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(child: Text('No models match'))
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final model = filtered[index];
                        return ListTile(
                          title: Text(model),
                          trailing: model == widget.currentModel
                              ? const Icon(Icons.check)
                              : null,
                          onTap: () => Navigator.of(context).pop(model),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
