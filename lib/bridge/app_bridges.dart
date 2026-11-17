/// One-stop wiring for the bridges: builds every bridge object the
/// app needs and exposes the `ListenEngine` hook-ups.
///
/// `main.dart` (owned by the UI sub-agent) should call
/// [AppBridges.initialize] once at startup and keep the result; see
/// the exact snippet in the bridge report. Nothing here starts
/// listening — that stays with the UI/engine wiring.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/credential_store.dart';
import 'keep_alive.dart';
import 'local_notifications.dart';
import 'secure_credential_store.dart';
import 'windows_tray.dart';

class AppBridges {
  final CredentialStore credentialStore;
  final KeepAlive keepAlive;
  final LocalNotifications notifications;
  final WindowsTray tray;

  AppBridges({
    required this.credentialStore,
    required this.keepAlive,
    required this.notifications,
    required this.tray,
  });

  /// Build all bridges. Injectable pieces are for tests; production
  /// callers pass nothing.
  static Future<AppBridges> initialize({
    SecureStorageBackend? storageBackend,
    Directory? configDirectory,
    MethodChannel? keepAliveChannel,
    LocalNotificationBackend? notificationBackend,
    TrayBackend? trayBackend,
  }) async {
    final dir = configDirectory ?? await getApplicationDocumentsDirectory();
    // Plain local file on ALL platforms, exactly like the DPPP PC build
    // (which keeps accounts/ as JSON in the documents dir).
    // flutter_secure_storage (iOS Keychain / Android
    // EncryptedSharedPreferences) is namespaced by the signing identity:
    // Yahel re-signs the unsigned IPA herself, so a re-signed build
    // cannot see Keychain items saved by a differently-signed build and
    // the user silently lands back on the login page. The file store
    // survives re-signing. The UI must keep showing the unencrypted
    // warning while this store is in use (never silently downgrade).
    final store = FileCredentialStore(dir);
    // One-time migration: accounts saved by older builds live in the
    // secure store. If the file store is empty, copy the secure store's
    // active account in once, so nobody has to log in again after the
    // switch. Best-effort: a broken secure store must never block
    // startup (a fresh login just recreates the file entry).
    try {
      if (await store.loadAccount() == null) {
        final legacy = SecureCredentialStore(dir, backend: storageBackend);
        final account = await legacy.loadAccount();
        if (account != null) {
          await store.saveAccount(
            phone: account.phone,
            password: account.password,
          );
        }
      }
    } catch (_) {
      // Secure store unreadable (or empty): start fresh.
    }
    final keepAlive = KeepAlive(channel: keepAliveChannel);
    final notifications =
        LocalNotifications(backend: notificationBackend);
    // Notification init is best-effort: a failure here must never kill
    // startup (see the Windows-settings crash: the plugin throws when a
    // platform's settings are missing). Notifications stay unavailable;
    // listening and grabs still work.
    try {
      await notifications.initialize();
    } catch (_) {
      // Best-effort only; show() already degrades to false.
    }
    final tray = WindowsTray(backend: trayBackend);
    return AppBridges(
      credentialStore: store,
      keepAlive: keepAlive,
      notifications: notifications,
      tray: tray,
    );
  }

  /// `ListenEngine.onGrab`-shaped handler: grab success -> local
  /// notification. Pass as `onGrab:` when constructing the engine.
  void Function(Map<String, dynamic>, String, int) get onGrab =>
      notifications.onGrabHandler;

  /// Start listening support: keep-alive on mobile, tray on Windows.
  /// [onTrayShow]/[onTrayQuit] are only used on Windows.
  Future<void> startBackgroundSupport({
    required void Function() onTrayShow,
    required void Function() onTrayQuit,
  }) async {
    await keepAlive.start();
    await tray.initialize(onShow: onTrayShow, onQuit: onTrayQuit);
  }

  /// Stop listening support.
  Future<void> stopBackgroundSupport() async {
    await keepAlive.stop();
    await tray.dispose();
  }
}
