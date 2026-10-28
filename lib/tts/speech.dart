import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/settings_repository.dart' show SettingsRepository;
import '../llm/providers.dart' show settingsRepositoryProvider;

/// Text-to-speech surface used by the chat screens. Kept tiny and
/// abstracted so screens can be tested without a speech engine.
///
/// [speak]'s [rate] is in flutter_tts units where 0.5 means the engine's
/// normal speed (the user's device-wide TTS rate is only honored when an
/// app never sets one — since we do set one, our own default of 0.5 is
/// what "normal" means here).
abstract class SpeechController {
  Future<void> speak(String text, {double rate = 0.5});
  Future<void> stop();
}

/// System-engine implementation (the voice installed on the device).
/// A missing plugin (tests, unsupported platform) degrades to no-ops
/// rather than crashing chat.
class SystemSpeech implements SpeechController {
  final FlutterTts _tts = FlutterTts();
  bool _unavailable = false;

  @override
  Future<void> speak(String text, {double rate = 0.5}) async {
    if (_unavailable) return;
    try {
      await _tts.setSpeechRate(rate);
      await _tts.speak(text);
    } on MissingPluginException {
      _unavailable = true;
    } catch (_) {
      // Speech is best-effort; a failed utterance must never break chat.
    }
  }

  @override
  Future<void> stop() async {
    if (_unavailable) return;
    try {
      await _tts.stop();
    } on MissingPluginException {
      _unavailable = true;
    } catch (_) {}
  }
}

final speechProvider = Provider<SpeechController>((ref) {
  final speech = SystemSpeech();
  ref.onDispose(speech.stop);
  return speech;
});

/// Settings key for speak-replies-when-finished. Default is off.
const String ttsAutoplayKey = 'tts.autoplay';

/// Settings key for the speech rate (flutter_tts units; 0.5 = normal).
const String ttsRateKey = 'tts.rate';

final ttsAutoplayProvider = StreamProvider<bool>((ref) {
  final repo = ref.watch(settingsRepositoryProvider);
  return repo.watchString(ttsAutoplayKey).map((value) => value == '1');
});

final ttsRateProvider = StreamProvider<double>((ref) {
  final repo = ref.watch(settingsRepositoryProvider);
  return repo.watchString(ttsRateKey).map((value) {
    final parsed = value == null ? null : double.tryParse(value);
    return parsed == null || parsed < 0.05 || parsed > 4 ? 0.5 : parsed;
  });
});

/// Flips the persisted autoplay preference to [enabled].
Future<void> setTtsAutoplay(SettingsRepository repo, bool enabled) {
  return repo.setString(ttsAutoplayKey, enabled ? '1' : '0');
}

/// Persists the speech rate.
Future<void> setTtsRate(SettingsRepository repo, double rate) {
  return repo.setString(ttsRateKey, rate.toStringAsFixed(2));
}
