/// Local notifications for a successful grab (PORTING_CONTRACT §1.7).
///
/// Copy is fixed by the contract / iOS snapshot (`AppViewModel`):
/// title `抢单成功`, body `已抢到一单，金额 X 元，请去查看订单。`
/// (amount with 2 decimals). This is the *local* notification; the
/// remote push channels (Bark / Server酱 / PushPlus / webhook) live in
/// core [Notifier] and are untouched.
///
/// Implemented with `flutter_local_notifications`:
/// - Android: channel `dpgrabber_grab` / `抢单成功`, high importance, so
///   the notification shows as a heads-up banner even while listening.
///   Android 13+ runtime permission (`POST_NOTIFICATIONS`) is requested
///   through [requestPermission].
/// - iOS: `UNUserNotificationCenter` via the plugin; alert + sound, no
///   badge (the grab count is shown in-app).
///
/// - Windows: `WindowsInitializationSettings` (appName / appUserModelId /
///   stable guid) is REQUIRED — without it the plugin throws
///   `Invalid argument(s): Windows settings must be set...` at startup
///   and the app dies before the first frame.
///
/// [LocalNotificationBackend] is injectable so unit tests can run
/// without the platform plugin. [onGrabHandler] is a
/// `ListenEngine.onGrab`-shaped closure: wire it as the engine's
/// `onGrab` and every successful grab posts the notification. It never
/// throws — a notification failure must not break the grab flow.
library;

import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../core/models.dart';

/// Minimal notification surface, injectable for tests.
abstract class LocalNotificationBackend {
  Future<void> initialize();
  Future<bool> requestPermission();
  Future<bool> show({
    required int id,
    required String title,
    required String body,
  });
}

/// `flutter_local_notifications` backend.
class FlutterLocalNotificationsBackend
    implements LocalNotificationBackend {
  static const String grabChannelId = 'dpgrabber_grab';
  static const String grabChannelName = '抢单成功';

  final FlutterLocalNotificationsPlugin _plugin;

  FlutterLocalNotificationsBackend({
    FlutterLocalNotificationsPlugin? plugin,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  @override
  Future<void> initialize() async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestSoundPermission: false,
          requestBadgePermission: false,
        ),
        windows: WindowsInitializationSettings(
          appName: 'DPGrabber',
          appUserModelId: 'com.doimty.dpgrabber',
          // Stable GUID: Windows routes toast activation through it.
          // Do not change it — a new guid would orphan notifications
          // shown by earlier builds.
          guid: '2eecfb1d-433e-4dc6-9f4c-509ee8048c33',
        ),
      ),
    );
  }

  @override
  Future<bool> requestPermission() async {
    var granted = true;
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      granted = await android.requestNotificationsPermission() ?? false;
    }
    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      granted = await ios.requestPermissions(
            alert: true,
            sound: true,
            badge: false,
          ) ??
          false;
    }
    return granted;
  }

  @override
  Future<bool> show({
    required int id,
    required String title,
    required String body,
  }) async {
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            grabChannelId,
            grabChannelName,
            channelDescription: '抢单成功提醒',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
            presentBadge: false,
          ),
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}

class LocalNotifications {
  static const String grabTitle = '抢单成功';

  /// Fixed by the contract / iOS snapshot. Amount always 2 decimals.
  static String grabBody(double amountYuan) =>
      '已抢到一单，金额 ${amountYuan.toStringAsFixed(2)} 元，请去查看订单。';

  /// Notification id for grab alerts. Derived from the order number so
  /// distinct grabs do not overwrite each other.
  static int grabIdFor(String orderNo) =>
      2000 + (orderNo.hashCode.abs() % 10000);

  final LocalNotificationBackend _backend;

  LocalNotifications({LocalNotificationBackend? backend})
      : _backend = backend ?? FlutterLocalNotificationsBackend();

  Future<void> initialize() => _backend.initialize();

  Future<bool> requestPermission() => _backend.requestPermission();

  /// Post the grab-success notification. Returns false when the
  /// platform refused or the backend failed; never throws.
  Future<bool> showGrabSuccess({
    required String orderNo,
    required double amount,
  }) async {
    try {
      return await _backend.show(
        id: grabIdFor(orderNo),
        title: grabTitle,
        body: grabBody(amount),
      );
    } catch (_) {
      return false;
    }
  }

  /// Raw title/body post, for the `AppState.onLocalNotification` seam
  /// (which formats the copy itself). Same contract wording; fixed id
  /// because there is at most one latest grab to show.
  Future<bool> showNotification({
    required String title,
    required String body,
  }) async {
    try {
      return await _backend.show(id: 2001, title: title, body: body);
    } catch (_) {
      return false;
    }
  }

  /// `ListenEngine.onGrab`-shaped handler. Fire-and-forget on purpose:
  /// the engine must never wait on (or fail because of) a notification.
  void Function(Map<String, dynamic>, String, int) get onGrabHandler =>
      (order, orderId, confirmCalls) {
        final parsed = Order(order);
        unawaited(
          showGrabSuccess(
            orderNo: parsed.no.isNotEmpty ? parsed.no : orderId,
            amount: parsed.amountYuan,
          ),
        );
      };
}
