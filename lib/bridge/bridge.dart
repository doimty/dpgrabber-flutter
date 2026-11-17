/// Platform bridges for DPGrabber Flutter (PORTING_CONTRACT §1.7, §12 Q-13).
///
/// Dart side only. The native counterparts live in `android/` (Kotlin
/// foreground service) and `ios/Runner/` (Swift silent-audio keep-alive).
/// Nothing here touches `lib/core/` semantics; the bridges only *host* the
/// core [ListenEngine] (keep it alive in the background) and *wire* its
/// callbacks (grab success -> local notification, credentials -> secure
/// storage).
///
/// Keep-alive decision (Q-13): hand-written `MethodChannel` + native
/// service, NOT `flutter_foreground_task`. Rationale, see `keep_alive.dart`:
/// the engine lives in the main isolate with its [ApiClient], config and
/// callbacks; a foreground-task plugin would force the engine into a
/// background isolate (re-architecting session/config/callback flow) for
/// no benefit — the native service's only job is to hold the process
/// alive and show the persistent notification, which a thin channel does.
library;

export 'app_bridges.dart';
export 'keep_alive.dart';
export 'local_notifications.dart';
export 'secure_credential_store.dart';
export 'windows_tray.dart';
