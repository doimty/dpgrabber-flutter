/// Voice announcements (PORTING_CONTRACT §1.7).
///
/// The core engine exposes a `speak` callback; this class is the UI
/// side that fulfils it with `flutter_tts` (zh-CN, rate 0.52 — the
/// iOS `AVSpeechSynthesizer` parity values). Speaking is best-effort:
/// any failure is swallowed so it can never break listening (§1.7).
/// The synthesiser is created lazily so constructing this class never
/// touches a platform channel (safe in widget tests).
library;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter_tts/flutter_tts.dart';

class VoiceAnnouncer {
  FlutterTts? _tts;
  Future<void>? _configureFuture;
  bool enabled;

  VoiceAnnouncer({this.enabled = true});

  FlutterTts _ensure() {
    final tts = _tts ??= FlutterTts();
    return tts;
  }

  Future<void> _ensureConfigured(FlutterTts tts) {
    return _configureFuture ??= _configure(tts);
  }

  Future<void> _configure(FlutterTts tts) async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // flutter_tts defaults to deactivating a shared AVAudioSession after
      // speech when its category is duckOthers. Keep session ownership with
      // AudioKeepAlive so a successful announcement cannot drop background
      // audio execution.
      try {
        await tts.autoStopSharedSession(false);
      } catch (_) {
        // TTS remains best-effort if the native plugin lacks this method.
      }
    }
  }

  /// Speak [text], interrupting anything currently speaking (iOS
  /// parity: interrupt before speaking). No-op when disabled or empty.
  /// Never throws.
  Future<void> speak(String text) async {
    if (!enabled || text.isEmpty) return;
    try {
      final tts = _ensure();
      await _ensureConfigured(tts);
      await tts.stop();
      await tts.setLanguage('zh-CN');
      await tts.setSpeechRate(0.52);
      await tts.speak(text);
    } catch (_) {
      // Speaking must never affect the grab flow.
    }
  }

  Future<void> stop() async {
    try {
      await _tts?.stop();
    } catch (_) {}
  }
}
