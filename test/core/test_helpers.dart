/// Shared test helpers: a stub [HttpTransport] and envelope builders.
///
/// All test data uses obviously fake numbers (e.g. 13800000000).
library;

import 'dart:convert';

import 'package:dpgrabber/core.dart';

/// A canned response or a thrown error, keyed by method + path prefix.
class FakeTransport implements HttpTransport {
  final Map<String, HttpResponse Function(HttpRequestRecord req)>
      handlers = {};
  final List<HttpRequestRecord> requests = [];

  /// Register a handler for requests whose path starts with [pathPrefix]
  /// (and whose method matches, or any method when [method] is null).
  void on(String pathPrefix,
      HttpResponse Function(HttpRequestRecord req) handler,
      {String? method}) {
    handlers['${method ?? '*'} $pathPrefix'] = handler;
  }

  /// Register a fixed JSON envelope response.
  void onJson(String pathPrefix, Map<String, dynamic> inner,
      {String? method, int status = 200}) {
    on(
      pathPrefix,
      (_) => HttpResponse(
        statusCode: status,
        bodyBytes: utf8.encode(jsonEncode({
          'response': inner,
          'isEncrypted': false,
        })),
      ),
      method: method,
    );
  }

  @override
  Future<HttpResponse> request({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    List<int>? body,
    required Duration timeout,
  }) async {
    final record = HttpRequestRecord(
      method: method,
      url: url,
      headers: headers,
      body: body,
      timeout: timeout,
    );
    requests.add(record);
    HttpResponse Function(HttpRequestRecord req)? handler;
    for (final entry in handlers.entries) {
      final key = entry.key;
      final space = key.indexOf(' ');
      final m = key.substring(0, space);
      final prefix = key.substring(space + 1);
      if ((m == '*' || m == method) && url.path.startsWith(prefix)) {
        handler = entry.value;
      }
    }
    if (handler == null) {
      throw StateError('no fake handler for $method ${url.path}');
    }
    return handler(record);
  }
}

class HttpRequestRecord {
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final List<int>? body;
  final Duration timeout;
  HttpRequestRecord({
    required this.method,
    required this.url,
    required this.headers,
    required this.body,
    required this.timeout,
  });

  String get bodyText => body == null ? '' : utf8.decode(body!);

  Map<String, dynamic> get bodyJson =>
      jsonDecode(bodyText) as Map<String, dynamic>;

  /// Parse an application/x-www-form-urlencoded body.
  Map<String, String> get bodyForm => Uri.splitQueryString(bodyText);
}

/// Build an ApiClient wired to [transport] with the default AES pairs.
ApiClient testClient(FakeTransport transport) => ApiClient(
      aesKeyHex: ApiClient.defaultAesKeyHex,
      aesIvHex: ApiClient.defaultAesIvHex,
      aesKeyHexAlt: ApiClient.altAesKeyHex,
      aesIvHexAlt: ApiClient.altAesIvHex,
      transport: transport,
    );

/// A fake order map. Amount is in cents (3000 = ¥30.00).
Map<String, dynamic> fakeOrder({
  String id = '15650502',
  String no = '26111401581302023638',
  int totalAmount = 3000,
  int? createTime,
  String userWechatId = 'A_sweet_moon',
  String userMemo = '',
  int? status,
  int? clerkId,
}) {
  final map = <String, dynamic>{
    'id': id,
    'no': no,
    'totalAmount': totalAmount,
    'userWechatId': userWechatId,
    'userMemo': userMemo,
  };
  if (createTime != null) map['createTime'] = createTime;
  if (status != null) map['status'] = status;
  if (clerkId != null) map['clerkId'] = clerkId;
  return map;
}

/// Config with tiny windows so engine tests run fast. run/rest off,
/// confirm-wait table emptied (immediate confirm) unless overridden.
AppConfig testConfig({
  Map<String, double>? confirmWaitByShop,
  double randomConfirmWindowSec = 2,
  double randomConfirmFallbackSec = 2,
  double confirmRetryDelaySec = 0.05,
  double pollIntervalSec = 0.05,
  double pollJitterSec = 0,
  double busyCooldownSec = 0.05,
  bool autoStopAfterGrab = true,
  bool runRestEnabled = false,
  double minAmount = 10,
  double maxAmount = 0,
  int memoMode = 0,
  List<String> blacklist = const [],
  List<String> memoExcludeKeywords = const [],
  List<String> memoIncludeKeywords = const [],
  List<int> itemSwitchIds = const [],
  bool itemSwitchKnown = false,
  double seenTtlSec = 60,
  double requestTimeoutSec = 15,
}) =>
    AppConfig.defaults().copyWith(
      confirmWaitByShop: confirmWaitByShop ?? const {},
      randomConfirmWindowSec: randomConfirmWindowSec,
      randomConfirmFallbackSec: randomConfirmFallbackSec,
      confirmRetryDelaySec: confirmRetryDelaySec,
      pollIntervalSec: pollIntervalSec,
      pollJitterSec: pollJitterSec,
      busyCooldownSec: busyCooldownSec,
      autoStopAfterGrab: autoStopAfterGrab,
      runRestEnabled: runRestEnabled,
      minAmount: minAmount,
      maxAmount: maxAmount,
      memoMode: memoMode,
      blacklist: blacklist,
      memoExcludeKeywords: memoExcludeKeywords,
      memoIncludeKeywords: memoIncludeKeywords,
      itemSwitchIds: itemSwitchIds,
      itemSwitchKnown: itemSwitchKnown,
      seenTtlSec: seenTtlSec,
      requestTimeoutSec: requestTimeoutSec,
    );
