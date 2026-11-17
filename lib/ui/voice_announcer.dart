/// Voice announcements (PORTING_CONTRACT §1.7).
///
/// The core engine exposes a `speak` callback; this class is the UI
/// side that fulfils it with `flutter_tts` (zh-CN, rate 0.52 — the
/// iOS `AVSpeechSynthesizer` parity values). Speaking is best-effort:
/// any failure is swallowed so it can never break listening (§1.7).
/// The synthesiser is created lazily so constructing this class never
/// touches a platform channel (safe in widget tests).
library;

import 'package:flutter_tts/flutter_tts.dart';

class VoiceAnnouncer {
  FlutterTts? _tts;
  bool enabled;

  VoiceAnnouncer({this.enabled = true});

  FlutterTts _ensure() {
    final tts = _tts ??= FlutterTts();
    return tts;
  }

  /// Speak [text], interrupting anything currently speaking (iOS
  /// parity: interrupt before speaking). No-op when disabled or empty.
  /// Never throws.
  Future<void> speak(String text) async {
    if (!enabled || text.isEmpty) return;
    try {
      final tts = _ensure();
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
