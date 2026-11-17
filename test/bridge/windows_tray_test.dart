/// WindowsTray tests (fake backend; runs on Linux via forceSupported).
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:dpgrabber/bridge/windows_tray.dart';

class FakeTrayBackend implements TrayBackend {
  bool initialized = false;
  bool disposed = false;
  bool windowVisible = true;
  String? tooltip;
  void Function()? onShow;
  void Function()? onQuit;

  @override
  Future<void> initialize({
    required void Function() onShow,
    required void Function() onQuit,
  }) async {
    initialized = true;
    this.onShow = onShow;
    this.onQuit = onQuit;
  }

  @override
  Future<void> setToolTip(String text) async {
    tooltip = text;
  }

  @override
  Future<void> showWindow() async {
    windowVisible = true;
  }

  @override
  Future<void> hideWindow() async {
    windowVisible = false;
  }

  @override
  Future<void> quit() async {
    disposed = true;
    initialized = false;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    initialized = false;
  }
}

void main() {
  test('unsupported platform (Linux host) is a no-op', () async {
    final backend = FakeTrayBackend();
    final tray = WindowsTray(backend: backend);
    expect(tray.isSupported, isFalse);
    var shown = false;
    var quit = false;
    await tray.initialize(onShow: () => shown = true, onQuit: () => quit = true);
    expect(tray.isInitialized, isFalse);
    expect(backend.initialized, isFalse);
    await tray.minimizeToTray();
    expect(backend.windowVisible, isTrue);
    expect(shown, isFalse);
    expect(quit, isFalse);
  });

  test('minimize hides to tray, show restores, callbacks fire', () async {
    final backend = FakeTrayBackend();
    final tray = WindowsTray(backend: backend, forceSupported: true);
    var shown = false;
    var quit = false;
    await tray.initialize(onShow: () => shown = true, onQuit: () => quit = true);
    expect(tray.isInitialized, isTrue);
    expect(backend.initialized, isTrue);

    await tray.minimizeToTray();
    expect(backend.windowVisible, isFalse);
    expect(backend.tooltip, contains('后台运行中'));

    await tray.showWindow();
    expect(backend.windowVisible, isTrue);
    expect(backend.tooltip, WindowsTray.defaultToolTip);

    backend.onShow?.call();
    expect(shown, isTrue);
    backend.onQuit?.call();
    expect(quit, isTrue);

    await tray.dispose();
    expect(backend.disposed, isTrue);
    expect(tray.isInitialized, isFalse);
  });

  test('quit marks the tray uninitialized', () async {
    final backend = FakeTrayBackend();
    final tray = WindowsTray(backend: backend, forceSupported: true);
    await tray.initialize(onShow: () {}, onQuit: () {});
    await tray.quit();
    expect(tray.isInitialized, isFalse);
    expect(backend.disposed, isTrue);
  });

  test('initialize is idempotent', () async {
    final backend = FakeTrayBackend();
    final tray = WindowsTray(backend: backend, forceSupported: true);
    await tray.initialize(onShow: () {}, onQuit: () {});
    await tray.initialize(onShow: () {}, onQuit: () {});
    expect(tray.isInitialized, isTrue);
  });
}
