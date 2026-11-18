/// DuoPei API client (PORTING_CONTRACT §0, §1.3, §4, §5, 附录 A).
///
/// Ported from `pc/dpapi.py`. All HTTP calls, response-envelope
/// decoding, and the login flow. Only depends on `crypto.dart`,
/// `models.dart` and `http_transport.dart` (§1.1 dependency rule).
library;

import 'dart:convert';

import 'crypto.dart';
import 'http_transport.dart';
import 'models.dart';

enum BodyType { none, json, form }

/// RFC 3986 unreserved characters, left unescaped in form bodies.
const String _formSafe =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

class ApiClient {
  static const String baseUrl = 'https://api.duopei.feiniaowangluo.com';
  static const String apiHost = 'api.duopei.feiniaowangluo.com';
  static const String userAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 15_1_1 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 '
      'Html5Plus/1.0 (Immersed/20) uni-app';
  static const String apiVersion = '202501071';
  static const String defaultAesKeyHex =
      'faf6bcb4eeaa8aa62154ed3b8c14cf5bce08cdf83086b9188abdca6f2c8bcbb1';
  static const String defaultAesIvHex =
      'd45df726d59d21fac023cdad3dfcea86';
  static const String altAesKeyHex = '81b120ef00216c33b266763abb02e6d1';
  static const String altAesIvHex = 'e6a4cc0507dfe344b042289eeb945dce';

  final String aesKeyHex;
  final String aesIvHex;
  final String aesKeyHexAlt;
  final String aesIvHexAlt;
  final bool verifyTls;
  final HttpTransport transport;

  /// In-memory session mirror only; never persisted, never logged.
  ///
  /// Single source of truth is [AppState.session] (see
  /// `lib/ui/app_state.dart`): AppState syncs this field whenever it
  /// sets its own session — that setter is the ONE sync point, and
  /// nothing else writes this field. [request] deliberately does NOT
  /// read it: every authenticated call must pass its session
  /// explicitly, so a stale mirror can never be silently retried
  /// (that silent retry is what surfaced as 401s with a live-looking
  /// UI). The field is only read for display-ish lookups such as the
  /// current shop id in the engine.
  Session? session;

  ApiClient({
    required this.aesKeyHex,
    required this.aesIvHex,
    this.aesKeyHexAlt = '',
    this.aesIvHexAlt = '',
    this.verifyTls = true,
    HttpTransport? transport,
  }) : transport = transport ?? HttpClientTransport(verifyTls: verifyTls);

  /// RFC 3986 percent-encoding: only A-Z a-z 0-9 - . _ ~ stay literal.
  String percentEncode(String value) {
    final bytes = utf8.encode(value);
    final out = StringBuffer();
    for (final b in bytes) {
      final ch = String.fromCharCode(b);
      if (_formSafe.contains(ch)) {
        out.write(ch);
      } else {
        out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
  }

  // -- decoding -------------------------------------------------------

  Map<String, dynamic> _decryptResponseText(String payload) {
    final attempts = <(String, String)>[(aesKeyHex, aesIvHex)];
    if (aesKeyHexAlt.isNotEmpty && aesIvHexAlt.isNotEmpty) {
      attempts.add((aesKeyHexAlt, aesIvHexAlt));
    }
    Object? lastError;
    for (final (keyHex, ivHex) in attempts) {
      try {
        final plain = aesDecryptB64(payload, keyHex, ivHex);
        final inner = jsonDecode(utf8.decode(plain));
        if (inner is! Map<String, dynamic>) {
          throw const ApiError(ApiErrorKind.api, 'decrypted response is not a JSON object');
        }
        return inner;
      } on ApiError {
        rethrow;
      } catch (e) {
        lastError = e;
      }
    }
    throw ApiError(ApiErrorKind.api, 'response decryption failed: $lastError');
  }

  /// Outer envelope -> inner dict; enforces the §1.2 code/auth/ip
  /// rules. Merge rule (§5, D-35): a non-encrypted string `response`
  /// is first parsed as plain JSON, and only decrypted when that fails.
  Map<String, dynamic> decodeResponse(List<int> raw) {
    Map<String, dynamic> outer;
    try {
      final decoded = jsonDecode(utf8.decode(raw));
      if (decoded is! Map<String, dynamic>) {
        throw const ApiError(ApiErrorKind.api, 'response must be a JSON object');
      }
      outer = decoded;
    } on ApiError {
      rethrow;
    } catch (e) {
      throw ApiError(ApiErrorKind.api, 'response is not valid JSON: $e');
    }

    final envelope = outer['response'];
    final encrypted = outer['isEncrypted'] == true;
    Map<String, dynamic>? inner;
    if (envelope is Map<String, dynamic>) {
      inner = envelope;
    } else if (envelope is String && envelope.isNotEmpty) {
      if (encrypted) {
        inner = _decryptResponseText(envelope);
      } else {
        Map<String, dynamic>? parsed;
        try {
          final decoded = jsonDecode(envelope);
          if (decoded is Map<String, dynamic>) parsed = decoded;
        } catch (_) {
          parsed = null;
        }
        inner = parsed ?? _decryptResponseText(envelope);
      }
    }
    inner ??= outer;

    final code = parseCode(inner);
    if (code == null) {
      throw const ApiError(ApiErrorKind.api, 'response has no valid business code');
    }
    if (code == 401 || code == 403) {
      throw ApiError(ApiErrorKind.auth, 'login state invalid (code $code)');
    }
    final msg = (inner['msg'] ?? inner['message'] ?? '').toString();
    if (code == 1 && msg.contains('IP')) {
      throw ApiError(ApiErrorKind.ip, 'IP control: $msg');
    }
    return inner;
  }

  // -- transport ------------------------------------------------------

  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Session? session,
    Map<String, dynamic>? body,
    BodyType bodyType = BodyType.none,
    Map<String, String> extraHeaders = const {},
    double timeoutSec = 15,
  }) async {
    if (!path.startsWith('/s/') || timeoutSec <= 0) {
      throw const ApiError(ApiErrorKind.api, 'invalid request path or timeout');
    }
    final url = Uri.parse('$baseUrl$path');
    final headers = <String, String>{
      'User-Agent': userAgent,
      'api-version': apiVersion,
      'platform': 'app',
      'Accept': '*/*',
      'Accept-Language': 'zh-CN,zh-Hans;q=0.9',
    };
    final useSession = session;
    if (useSession == null) {
      // No silent fallback to [this.session]: a call without an
      // explicit session is a bug in the caller, and retrying with a
      // possibly-stale mirror only produces confusing 401s. Callers
      // that are genuinely unauthenticated (the login call) pass an
      // explicit empty-token session instead.
      throw const ApiError(ApiErrorKind.auth, 'no session: login required');
    }
    if (useSession.token.isNotEmpty) {
      headers['authorization-token'] = useSession.token;
      headers['sid'] = useSession.sid;
    }
    headers.addAll(extraHeaders);

    List<int>? data;
    if (body != null && bodyType == BodyType.json) {
      data = utf8.encode(jsonEncode(body));
      headers['Content-Type'] = 'application/json';
    } else if (body != null && bodyType == BodyType.form) {
      final keys = body.keys.toList()..sort();
      final pairs = [
        for (final key in keys)
          '${percentEncode(key.toString())}='
              '${percentEncode(body[key].toString())}',
      ];
      data = utf8.encode(pairs.join('&'));
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
    }

    late final HttpResponse resp;
    try {
      resp = await transport.request(
        method: method,
        url: url,
        headers: headers,
        body: data,
        timeout: Duration(milliseconds: (timeoutSec * 1000).round()),
      );
    } catch (e) {
      throw ApiError(ApiErrorKind.network, 'request failed: $e');
    }
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw ApiError(
          ApiErrorKind.auth, 'login state invalid (HTTP ${resp.statusCode})');
    }
    if (resp.statusCode >= 400) {
      throw ApiError(ApiErrorKind.network, 'HTTP ${resp.statusCode}');
    }
    return decodeResponse(resp.bodyBytes);
  }

  // -- login flow (§4) -------------------------------------------------

  Map<String, dynamic> _loginBody(String phone, String password) => {
        'method': 'password',
        'phoneNumber': {
          'regionCode': 'CN',
          'mobileDial': '86',
          'mobile': phone,
        },
        // PC rule (D-04): MD5-hex, 32-hex passthrough, field always
        // named `password` — never a separate `password_hash` key.
        'password': loginPasswordValue(password),
      };

  /// POST /s/duopei-account/login. Returns the session with
  /// `sid = data.shopId` (missing -> '50'); never a hard-coded sid (§4.3).
  Future<Session> loginAccount(String phone, String password) async {
    final cleanPhone = phone.trim();
    if (cleanPhone.isEmpty || password.trim().isEmpty) {
      throw const ApiError(ApiErrorKind.api, 'phone and password are required');
    }
    // An empty token session forces "no session headers"; the login
    // headers below (sid -1, empty authorization-token) then apply.
    final resp = await request(
      'POST',
      '/s/duopei-account/login',
      session: const Session(token: ''),
      body: _loginBody(cleanPhone, password),
      bodyType: BodyType.json,
      extraHeaders: {'sid': '-1', 'authorization-token': ''},
      timeoutSec: 15,
    );
    if (parseCode(resp) != 0) {
      throw ApiError(
          ApiErrorKind.auth,
          'login rejected: ${(resp['msg'] ?? resp['message'] ?? '').toString()}');
    }
    final data = resp['data'];
    final dataMap = data is Map<String, dynamic> ? data : <String, dynamic>{};
    final token = (dataMap['token'] ?? '').toString();
    if (token.isEmpty) {
      throw const ApiError(ApiErrorKind.auth, 'login response has no token');
    }
    final sid = (dataMap['shopId'] ?? '50').toString();
    return Session(token: token, sid: sid);
  }

  /// Raw clerk/get response captured during the permission probe,
  /// keyed by the candidate session object (identity). A cold start
  /// used to call clerk/get twice — once in the probe
  /// ([_confirmClerkSeat]) and once in AppState's refresh — so the
  /// probe result is reused instead of fetched again. Entries are
  /// consumed (removed) by [takeCachedClerkRaw]; the map is cleared
  /// at the start of every [sessionForAccount] so a stale probe
  /// never survives into the next login.
  final Map<Session, Map<String, dynamic>> _cachedClerkRaw = {};

  /// Take (and remove) the probe's clerk/get response for [session],
  /// or null when the probe did not fetch one for this session.
  Map<String, dynamic>? takeCachedClerkRaw(Session session) =>
      _cachedClerkRaw.remove(session);

  /// Full manual login: login -> list shops -> switch per shop ->
  /// balance check -> clerk-permission probe (§4.1, D-05).
  Future<Session> sessionForAccount(
    String phone,
    String password, {
    int preferredShopId = 0,
    void Function(String note)? onNote,
  }) async {
    _cachedClerkRaw.clear();
    final base = await loginAccount(phone, password);
    final resp = await request(
      'GET',
      '/s/duopei-account/list-shop-account',
      session: base,
      extraHeaders: {'sid': base.sid},
      timeoutSec: 15,
    );
    if (parseCode(resp) != 0) {
      throw const ApiError(ApiErrorKind.api, 'shop list rejected');
    }
    final shopsRaw = resp['data'];
    final shops = <Map<String, dynamic>>[];
    if (shopsRaw is List) {
      for (final s in shopsRaw) {
        if (s is Map<String, dynamic>) shops.add(s);
      }
    }
    final ordered = _orderShops(shops, preferredShopId);
    ApiError? lastError;
    Session? fallback;
    for (final shop in ordered) {
      final accountId = (shop['accountId'] ?? '').toString();
      final sid = (shop['shopId'] ?? '').toString();
      if (accountId.isEmpty || sid.isEmpty) continue;
      Map<String, dynamic> switched;
      try {
        switched = await request(
          'POST',
          '/s/duopei-account/switch-account',
          session: base,
          body: {'accountId': accountId},
          bodyType: BodyType.form,
          extraHeaders: {'sid': base.sid},
          timeoutSec: 15,
        );
      } on ApiError catch (e) {
        if (e.kind == ApiErrorKind.auth ||
            e.kind == ApiErrorKind.ip ||
            e.kind == ApiErrorKind.cancelled) {
          rethrow;
        }
        lastError = e;
        continue;
      }
      if (parseCode(switched) != 0) continue;
      final switchedData = switched['data'];
      final switchedMap =
          switchedData is Map<String, dynamic> ? switchedData : <String, dynamic>{};
      final token = (switchedMap['token'] ?? '').toString();
      if (token.isEmpty) continue;
      final candidate = Session(token: token, sid: sid);
      try {
        final balance = await request(
          'GET',
          '/s/balance/getBalance',
          session: candidate,
          timeoutSec: 15,
        );
        if (parseCode(balance) != 0) continue;
      } on ApiError catch (e) {
        if (e.kind == ApiErrorKind.ip ||
            e.kind == ApiErrorKind.cancelled) {
          rethrow;
        }
        lastError = e;
        continue;
      }
      final (state, note) = await _probeShopPermission(candidate);
      onNote?.call('店铺 $sid：$note');
      if (state == 'confirmed') {
        return candidate;
      }
      if (state == 'denied') continue;
      fallback ??= candidate;
    }
    if (fallback != null) {
      onNote?.call('没有确认到店员权限的店铺，沿用 sid=${fallback.sid}（权限未确认）');
      return fallback;
    }
    throw ApiError(
      ApiErrorKind.auth,
      'no usable shop session: ${lastError?.message ?? 'all shops rejected'}',
    );
  }

  /// Clerk-permission probe (§4.1 step 4): clerk/get first, then a
  /// randomList probe when inconclusive. A 401 'login state invalid'
  /// from a seatless shop during probing is normal, not a login failure.
  Future<(String, String)> _probeShopPermission(Session candidate) async {
    final (state, note) = await _confirmClerkSeat(candidate);
    if (state != 'unknown') return (state, note);
    try {
      await randomList(pageSize: 1, timeoutSec: 10, session: candidate);
    } on ApiError catch (e) {
      if (e.kind == ApiErrorKind.ip || e.kind == ApiErrorKind.cancelled) {
        rethrow;
      }
      final text = e.message;
      if (text.contains('店员') || text.contains('权限')) {
        return ('denied', '业务探测：$text');
      }
      return ('unknown', '$note；业务探测：$text');
    }
    return ('confirmed', '业务探测可下单');
  }

  Future<(String, String)> _confirmClerkSeat(Session candidate) async {
    Map<String, dynamic> decoded;
    try {
      decoded = await clerkGet(session: candidate);
    } on ApiError catch (e) {
      if (e.kind == ApiErrorKind.ip || e.kind == ApiErrorKind.cancelled) {
        rethrow;
      }
      return ('unknown', '店员校验失败：${e.message}');
    }
    final code = parseCode(decoded);
    if (code != null && code != 0) {
      return ('unknown', '店员校验 code=$code ${decoded['msg'] ?? ''}');
    }
    final clerk = extractClerk(decoded);
    if (clerk == null) return ('denied', '无店员席位');
    // Keep the fetched response for AppState's refresh, so the cold
    // start does not call clerk/get a second time for this session.
    _cachedClerkRaw[candidate] = decoded;
    return ('confirmed', '店员 ID ${clerk.id}');
  }

  // -- business calls -------------------------------------------------

  Future<Map<String, dynamic>> clerkGet({Session? session}) =>
      request('GET', '/s/c/clerk/get', session: session, timeoutSec: 15);

  /// GET /s/c/order/randomList. A missing `list` is an empty list, not
  /// an error (PC rule, D-36).
  Future<List<Map<String, dynamic>>> randomList({
    int pageSize = 20,
    double timeoutSec = 15,
    Session? session,
  }) async {
    final resp = await request(
      'GET',
      '/s/c/order/randomList?pageNo=1&pageSize=$pageSize',
      session: session,
      timeoutSec: timeoutSec,
    );
    var orders = resp['list'];
    if (orders == null && resp['data'] is Map<String, dynamic>) {
      orders = (resp['data'] as Map<String, dynamic>)['list'];
    }
    if (orders is! List) return [];
    return [
      for (final o in orders)
        if (o is Map<String, dynamic>) o,
    ];
  }

  Future<Map<String, dynamic>> orderGet(String orderId,
          {Session? session, double timeoutSec = 15}) =>
      request(
        'GET',
        '/s/c/order/get?id=${percentEncode(orderId)}',
        session: session,
        timeoutSec: timeoutSec,
      );

  Future<Map<String, dynamic>> orderConfirm(String orderId,
          {Session? session, double timeoutSec = 10}) =>
      request(
        'POST',
        '/s/c/order/confirm?id=${percentEncode(orderId)}',
        session: session,
        timeoutSec: timeoutSec,
      );

  /// GET /s/c/statistics/statisticsClerkOrder. Only dates
  /// (YYYY-MM-DD) are accepted; code != 0 or no list -> {}.
  Future<Map<String, dynamic>> clerkStatistics(
    String startDate,
    String endDate, {
    Session? session,
  }) async {
    final path = '/s/c/statistics/statisticsClerkOrder'
        '?startTime=${percentEncode(startDate)}'
        '&endTime=${percentEncode(endDate)}';
    final resp = await request('GET', path, session: session, timeoutSec: 25);
    if (parseCode(resp) != 0) return {};
    final list = resp['list'];
    return list is Map<String, dynamic> ? list : {};
  }

  /// POST /s/c/clerk/updateStatus, form: status=1 online / 2 offline.
  Future<Map<String, dynamic>> setOnline(int status,
          {bool updateAutoOnline = false, Session? session}) =>
      request(
        'POST',
        '/s/c/clerk/updateStatus',
        session: session,
        body: {
          'status': status,
          'updateAutoOnline': updateAutoOnline ? 'true' : 'false',
        },
        bodyType: BodyType.form,
        timeoutSec: 15,
      );

  /// POST /s/c/clerk/updateRandomOrderSwitch, form.
  Future<Map<String, dynamic>> setRandomOrderSwitch(bool enabled,
          {Session? session}) =>
      request(
        'POST',
        '/s/c/clerk/updateRandomOrderSwitch',
        session: session,
        body: {'randomOrderSwitch': enabled ? 'true' : 'false'},
        bodyType: BodyType.form,
        timeoutSec: 15,
      );

  /// POST /s/c/clerk/getItemSwitchList with an empty JSON body {}.
  ///
  /// TODO(OPEN-Q09): PC code sends an empty JSON body; HANDOFF §3.3
  /// says an empty form. PC code is followed here; verify against the
  /// real API before release.
  Future<Map<String, dynamic>> itemSwitchList({Session? session}) =>
      request(
        'POST',
        '/s/c/clerk/getItemSwitchList',
        session: session,
        body: <String, dynamic>{},
        bodyType: BodyType.json,
        timeoutSec: 15,
      );

  /// POST /s/c/clerk/updateItemSwitch, form: switchId + switchIds as a
  /// JSON array string (e.g. '[465,2666]'). A comma list is rejected
  /// by the server ("expect '[', but int").
  Future<Map<String, dynamic>> setItemSwitch(int switchId,
          List<int> enabledIds, {Session? session}) =>
      request(
        'POST',
        '/s/c/clerk/updateItemSwitch',
        session: session,
        body: {
          'switchId': switchId,
          'switchIds': jsonEncode(enabledIds),
        },
        bodyType: BodyType.form,
        timeoutSec: 15,
      );

  /// Order count in a datetime range; -1 when the platform refuses.
  /// Datetimes must carry HH:MM:SS.
  ///
  /// TODO(OPEN-Q09): PC code uses `pageNo`; HANDOFF §3.5 writes
  /// `pageNum` (D-30). PC code is followed here; verify against the
  /// real API before release.
  Future<int> orderTotal(String startDt, String endDt,
      {Session? session}) async {
    final path = '/s/c/order/list?pageNo=1&pageSize=1'
        '&startTime=${percentEncode(startDt)}'
        '&endTime=${percentEncode(endDt)}';
    Map<String, dynamic> resp;
    try {
      resp = await request('GET', path, session: session, timeoutSec: 20);
    } on ApiError {
      return -1;
    }
    if (parseCode(resp) != 0) return -1;
    final total = resp['total'];
    if (total is num) return total.toInt();
    if (total is String) return int.tryParse(total.trim()) ?? -1;
    return 0;
  }
}

List<Map<String, dynamic>> _orderShops(
    List<Map<String, dynamic>> shops, int preferredShopId) {
  final candidates = List.of(shops);
  if (preferredShopId > 0) {
    int shopIdOf(Map<String, dynamic> s) {
      final v = s['shopId'];
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v.trim()) ?? -1;
      return -1;
    }

    final head =
        candidates.where((s) => shopIdOf(s) == preferredShopId).toList();
    final tail =
        candidates.where((s) => shopIdOf(s) != preferredShopId).toList();
    return [...head, ...tail];
  }
  return candidates;
}
