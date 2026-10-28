import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../llm/providers.dart' show settingsRepositoryProvider;
import '../tts/speech.dart';

/// App-bar toggle for speak-replies-when-finished. Shared by the chat
/// screens so the preference is one and the same everywhere.
class AutoplayToggle extends ConsumerWidget {
  const AutoplayToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final autoplay = ref.watch(ttsAutoplayProvider).value ?? false;
    return IconButton(
      tooltip: autoplay ? 'Autoplay replies: on' : 'Autoplay replies: off',
      onPressed: () =>
          setTtsAutoplay(ref.read(settingsRepositoryProvider), !autoplay),
      icon: Icon(autoplay ? Icons.volume_up : Icons.volume_off),
    );
  }
}

/// App-bar button opening the speech-speed sheet. Shared by chat screens.
class SpeedButton extends ConsumerWidget {
  const SpeedButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      tooltip: 'Speech speed',
      onPressed: () => showModalBottomSheet(
        context: context,
        showDragHandle: true,
        builder: (_) => const _SpeedSheet(),
      ),
      icon: const Icon(Icons.speed),
    );
  }
}

/// Slider over flutter_tts speech rate. 0.5 (100%) is the engine's normal
/// speed; the value persists across launches.
class _SpeedSheet extends ConsumerStatefulWidget {
  const _SpeedSheet();

  @override
  ConsumerState<_SpeedSheet> createState() => _SpeedSheetState();
}

class _SpeedSheetState extends ConsumerState<_SpeedSheet> {
  double? _draft;

  double get _effective => _draft ?? (ref.watch(ttsRateProvider).value ?? 0.5);

  int get _percent => (_effective / 0.5 * 100).round();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Speech speed', style: Theme.of(context).textTheme.titleLarge),
            Slider(
              value: _effective.clamp(0.1, 1.0),
              min: 0.1,
              max: 1.0,
              divisions: 18,
              label: '$_percent%',
              onChanged: (value) => setState(() => _draft = value),
            ),
            Text(
              '$_percent% of normal speed',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => unawaited(ref
                        .read(speechProvider)
                        .speak('This is how replies will sound.',
                            rate: _effective)),
                    icon: const Icon(Icons.play_arrow_outlined),
                    label: const Text('Preview'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () async {
                      await setTtsRate(
                          ref.read(settingsRepositoryProvider), _effective);
                      if (context.mounted) Navigator.pop(context);
                    },
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
