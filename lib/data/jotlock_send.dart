import 'package:flutter/services.dart';

const MethodChannel _channel = MethodChannel('daymark/outgoing');

/// Outcome of sending one rewritten note to JotLock; [message] is
/// snackbar-ready. JotLock is never modified in place — the share intent
/// opens its editor pre-filled and the user confirms the save there.
class JotlockSendOutcome {
  final bool sent;
  final String message;

  const JotlockSendOutcome(this.sent, this.message);
}

/// Typed access to the native `daymark/outgoing` channel. [channel] is
/// injectable so tests can stub the platform side.
class JotlockSender {
  final MethodChannel channel;

  JotlockSender({MethodChannel? channel}) : channel = channel ?? _channel;

  /// Shares [text] straight to JotLock's editor (ACTION_SEND limited to
  /// jotlock's package — no system chooser). Errors degrade to a failed
  /// outcome; a missing plugin (tests, non-Android) reads as not installed.
  Future<JotlockSendOutcome> sendNote(String text) async {
    try {
      await channel.invokeMethod('sendNote', {'text': text});
      return const JotlockSendOutcome(
        true,
        'Opened in JotLock — tap Save to keep it',
      );
    } on PlatformException catch (e) {
      if (e.code == 'no_jotlock') {
        return const JotlockSendOutcome(false, 'JotLock is not installed');
      }
      return const JotlockSendOutcome(false, 'Could not send to JotLock');
    } on MissingPluginException {
      return const JotlockSendOutcome(false, 'JotLock is not installed');
    }
  }

  /// Installed app version name for the About page, or ''.
  Future<String> getVersionName() async {
    try {
      return await channel.invokeMethod<String>('getVersionName') ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Opens [url] in the system browser; the app itself stays offline.
  /// Native side enforces https/http.
  Future<void> openUrl(String url) async {
    try {
      await channel.invokeMethod('openUrl', {'url': url});
    } catch (_) {
      // Nothing actionable — the About page links are best-effort.
    }
  }
}
