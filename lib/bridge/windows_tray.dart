/// Windows system tray (tray icon + minimise-to-tray + keep running).
///
/// Windows has no foreground-service / silent-audio concept: the app
/// keeps listening simply by staying alive. Closing the window would
/// kill the process and the listen loop, so the close button is
/// intercepted — the window hides to the tray instead — and the tray
/// menu offers "显示窗口" (show) and "退出" (quit, which really exits).
///
/// Implemented hand-written, with NO tray/window plugin dependency:
/// the native side is `windows/runner/tray_icon.{h,cpp}`
/// (`Shell_NotifyIcon`, the runner's own `IDI_APP_ICON`, a popup menu),
/// driven from Dart over the `com.doimty.dpgrabber/tray` MethodChannel.
///
/// Why no plugin (`tray_manager` / `window_manager`): their 0.6/0.8
/// releases moved to a nativeapi/cnativeapi FFI stack whose Linux
/// build hook requires GTK3/X11 dev packages — on this Linux VM (and
/// any Linux CI without them) merely having them in `pubspec.yaml`
/// breaks `flutter test` for the WHOLE project, including the 160
/// core tests (verified: core tests fail with the cnativeapi hook
/// error while the plugins are listed, and pass the moment they are
/// removed). A hand-written Win32 tray has no such cost and its API
/// surface is stable Win32, not a brand-new FFI layer.
///
/// Channel `com.doimty.dpgrabber/tray`, Dart -> native:
/// `initialize`, `setToolTip` {text}, `showWindow`, `hideWindow`,
/// `quit`, `dispose`. Native -> Dart: `onTrayShow`, `onTrayQuit`.
///
/// Quit flow: native sends `onTrayQuit` -> Dart stops the engine,
/// then calls [WindowsTray.quit] -> native removes the icon and
/// closes the window for real.
///
/// [TrayBackend] is injectable so unit tests can run on Linux without
/// a Windows shell. All methods are best-effort and never throw.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Minimal tray surface, injectable for tests.
abstract class TrayBackend {
  Future<void> initialize({
    required void Function() onShow,
    required void Function() onQuit,
  });
  Future<void> setToolTip(String text);
  Future<void> showWindow();
  Future<void> hideWindow();
  Future<void> quit();
  Future<void> dispose();
}

/// MethodChannel backend: the native side lives in
/// `windows/runner/tray_icon.{h,cpp}`.
class MethodChannelTrayBackend implements TrayBackend {
  static const String channelName = 'com.doimty.dpgrabber/tray';

  final MethodChannel channel;
  void Function()? _onShow;
  void Function()? _onQuit;

  MethodChannelTrayBackend({MethodChannel? channel})
      : channel = channel ?? const MethodChannel(channelName);

  /// Best-effort channel call: a missing native side (test host) or a
  /// native failure must never throw into the app. Deliberately silent:
  /// the tray is a convenience, not the listen loop.
  Future<void> _bestEffort(Future<void> Function() run) async {
    try {
      await run();
    } on MissingPluginException {
      // No native side registered (e.g. `flutter test` host).
    } on PlatformException {
      // Tray call failed; the app still works, just without a tray.
    }
  }

  @override
  Future<void> initialize({
    required void Function() onShow,
    required void Function() onQuit,
  }) async {
    _onShow = onShow;
    _onQuit = onQuit;
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onTrayShow':
          _onShow?.call();
        case 'onTrayQuit':
          _onQuit?.call();
      }
      return null;
    });
    await _bestEffort(() async {
      await channel.invokeMethod<bool>('initialize');
    });
  }

  @override
  Future<void> setToolTip(String text) =>
      _bestEffort(() => channel.invokeMethod<void>('setToolTip', {'text': text}));

  @override
  Future<void> showWindow() =>
      _bestEffort(() => channel.invokeMethod<void>('showWindow'));

  @override
  Future<void> hideWindow() =>
      _bestEffort(() => channel.invokeMethod<void>('hideWindow'));

  @override
  Future<void> quit() =>
      _bestEffort(() => channel.invokeMethod<void>('quit'));

  @override
  Future<void> dispose() async {
    await _bestEffort(() => channel.invokeMethod<void>('dispose'));
    channel.setMethodCallHandler(null);
    _onShow = null;
    _onQuit = null;
  }
}

class WindowsTray {
  static const String defaultToolTip = 'DPGrabber 抢单监听中';

  final TrayBackend _backend;

  /// Test-only override: forces [isSupported] true on a host platform
  /// (e.g. Linux in `flutter test`) so the fake backend is exercised.
  /// Production code must not pass this.
  final bool forceSupported;

  bool _initialized = false;
  void Function()? _onShow;
  void Function()? _onQuit;

  WindowsTray({TrayBackend? backend, this.forceSupported = false})
      : _backend = backend ?? MethodChannelTrayBackend();

  bool get isSupported => forceSupported || Platform.isWindows;

  bool get isInitialized => _initialized;

  /// Set up the tray icon, its menu and the close-button intercept.
  /// [onShow] restores the window; [onQuit] is called when the user
  /// picks "退出" — the caller owns stopping the engine and then
  /// calling [quit]. No-op on non-Windows platforms; never throws.
  Future<void> initialize({
    required void Function() onShow,
    required void Function() onQuit,
  }) async {
    if (!isSupported || _initialized) return;
    _onShow = onShow;
    _onQuit = onQuit;
    try {
      await _backend.initialize(
        onShow: () => _onShow?.call(),
        onQuit: () => _onQuit?.call(),
      );
      _initialized = true;
    } catch (_) {
      _initialized = false;
    }
  }

  /// Hide the window to the tray; listening continues in the background.
  Future<void> minimizeToTray() async {
    if (!_initialized) return;
    try {
      await _backend.hideWindow();
      await _backend.setToolTip('$defaultToolTip（后台运行中）');
    } catch (_) {}
  }

  /// Restore the window from the tray.
  Future<void> showWindow() async {
    if (!_initialized) return;
    try {
      await _backend.showWindow();
      await _backend.setToolTip(defaultToolTip);
    } catch (_) {}
  }

  Future<void> setToolTip(String text) async {
    if (!_initialized) return;
    try {
      await _backend.setToolTip(text);
    } catch (_) {}
  }

  /// Really exit: remove the tray icon and close the window. Call
  /// this after stopping the engine, from the `onQuit` callback.
  Future<void> quit() async {
    if (!_initialized) return;
    try {
      await _backend.quit();
    } catch (_) {}
    _initialized = false;
  }

  Future<void> dispose() async {
    if (!_initialized) return;
    try {
      await _backend.dispose();
    } catch (_) {}
    _initialized = false;
  }
}
