/// Keep-alive bridge: start/stop the platform background hold so the
/// [ListenEngine] keeps polling while the app is backgrounded.
///
/// Q-13 DECISION — hand-written `MethodChannel` + native service, NOT
/// `flutter_foreground_task` (or any foreground-task plugin):
///
/// 1. The engine lives in the main isolate. It owns an [ApiClient] with an
///    in-memory session, an [AppConfig], and Dart callbacks (`onGrab`,
///    `onOutcome`, `onSession`, log/speak). A foreground-task plugin runs
///    its callback in a *separate background isolate*: the engine, its
///    session and its callbacks would have to be rebuilt there, with
///    config/session serialised across isolates and results sent back.
///    That is a re-architecture of the core for zero functional gain.
/// 2. The native side does not need to *run* the engine. On Android the
///    foreground service only holds the process alive and shows the
///    persistent notification; polling still happens in the main isolate.
///    On iOS the silent-audio loop only holds the process alive; polling
///    still happens in the main isolate. A thin channel is exactly enough.
/// 3. Fewer moving parts: no plugin version churn, no plugin-owned
///    notification channel fighting the one in `ListenService`, no
///    plugin-owned Dart entrypoint to keep in sync with the core.
/// 4. Honest limits stay visible: Android can still kill the service
///    under extreme pressure (START_STICKY restarts it); iOS can still
///    suspend/terminate the app (audio mode is a hint, not a guarantee).
///    A plugin would not change either fact.
///
/// Native counterparts:
/// - Android: `ListenService` (foreground, `dataSync`) + `MainActivity`
///   channel handler. Methods: `start`, `stop`, `isRunning`,
///   `updateNotification` (native-side throttled to 2 s, as the reference).
/// - iOS: `KeepAlivePlugin` + `AudioKeepAlive` (8 kHz mono silent loop).
///   Methods: `start`, `stop`, `isRunning`. `updateNotification` is a
///   no-op there (no persistent notification on iOS).
/// - Windows/other: unsupported — the app stays alive via the tray
///   ([WindowsTray]); [start] returns false without calling the channel.
///
/// All methods are best-effort and never throw: a missing plugin or a
/// platform error degrades to `false` / no-op, and the UI can show the
/// engine as foreground-only. Tests inject a mock [MethodChannel].
library;

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

class KeepAlive {
  static const String channelName = 'com.doimty.dpgrabber/keep_alive';

  static const MethodChannel defaultChannel =
      MethodChannel(channelName);

  final MethodChannel channel;

  /// Test-only override: forces [isSupported] true on a host platform
  /// (e.g. Linux in `flutter test`) so the mock channel is exercised.
  /// Production code must not pass this.
  final bool forceSupported;

  KeepAlive({MethodChannel? channel, this.forceSupported = false})
      : channel = channel ?? defaultChannel;

  bool get isSupported =>
      forceSupported || Platform.isAndroid || Platform.isIOS;

  /// Start the platform keep-alive. Returns true only when the native
  /// side confirms it is running.
  Future<bool> start() async {
    if (!isSupported) return false;
    try {
      return await channel.invokeMethod<bool>('start') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Stop the platform keep-alive. Returns true when the native side
  /// confirms it stopped (or was already stopped).
  Future<bool> stop() async {
    if (!isSupported) return false;
    try {
      return await channel.invokeMethod<bool>('stop') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Whether the native keep-alive is currently running.
  Future<bool> get isRunning async {
    if (!isSupported) return false;
    try {
      return await channel.invokeMethod<bool>('isRunning') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Push a status line to the Android persistent notification.
  /// No-op on iOS / unsupported platforms. Best-effort, never throws;
  /// the native side throttles updates to one per 2 s (reference
  /// `ListenService.updateNotification`).
  Future<void> updateStatus(String text) async {
    if (!isSupported || text.isEmpty) return;
    try {
      await channel.invokeMethod<void>(
        'updateNotification',
        {'text': text},
      );
    } on MissingPluginException {
      // No native side registered (e.g. plain `flutter test` host).
    } on PlatformException {
      // Notification update must never break the listen loop.
    }
  }
}
