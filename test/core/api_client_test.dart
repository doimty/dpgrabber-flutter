import 'dart:convert';

import 'package:dpgrabber/core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

/// Explicit session passed to every authenticated call in these
/// tests (the client no longer falls back to a stored mirror).
const _session = Session(token: 'tok-1', sid: '92');

void main() {
  group('percentEncode', () {
    test('RFC 3986 unreserved set stays literal', () {
      final client = testClient(FakeTransport());
      expect(client.percentEncode('AZaz09-._~'), 'AZaz09-._~');
      expect(client.percentEncode('a b&c=d'), 'a%20b%26c%3Dd');
      expect(client.percentEncode('中文'), '%E4%B8%AD%E6%96%87');
    });
  });

  group('decodeResponse', () {
    test('plain object response passes through', () {
      final client = testClient(FakeTransport());
      final decoded = client.decodeResponse(
          utf8.encode('{"response":{"code":0,"msg":"ok"}}'));
      expect(decoded['code'], 0);
    });
    test('outer object without a response field is the inner dict', () {
      final client = testClient(FakeTransport());
      expect(
          client.decodeResponse(utf8.encode('{"code":0}'))['code'], 0);
    });
    test('encrypted string response decrypts with the primary pair', () {
      final client = testClient(FakeTransport());
      final inner = '{"code":0,"msg":"ok"}';
      final enc = aesEncryptB64(
          utf8.encode(inner),
          ApiClient.defaultAesKeyHex,
          ApiClient.defaultAesIvHex);
      final decoded = client.decodeResponse(utf8.encode(jsonEncode({
        'response': enc,
        'isEncrypted': true,
      })));
      expect(decoded['code'], 0);
    });
    test('falls back to the alternate pair when the primary fails', () {
      final client = testClient(FakeTransport());
      final enc = aesEncryptB64(utf8.encode('{"code":0}'),
          ApiClient.altAesKeyHex, ApiClient.altAesIvHex);
      final decoded = client.decodeResponse(utf8.encode(jsonEncode({
        'response': enc,
        'isEncrypted': false, // plain parse fails -> decrypt
      })));
      expect(decoded['code'], 0);
    });
    test('plain string response parses without decryption', () {
      final client = testClient(FakeTransport());
      final decoded = client.decodeResponse(utf8.encode(jsonEncode({
        'response': '{"code":0,"list":[]}',
        'isEncrypted': false,
      })));
      expect(decoded['code'], 0);
    });
    test('code 401/403 -> auth; code 1 + IP -> ip; no code -> api', () {
      final client = testClient(FakeTransport());
      expect(
          () => client.decodeResponse(
              utf8.encode('{"response":{"code":401,"msg":"x"}}')),
          throwsA(isA<ApiError>()
              .having((e) => e.kind, 'kind', ApiErrorKind.auth)));
      expect(
          () => client.decodeResponse(
              utf8.encode('{"response":{"code":1,"msg":"IP受限"}}')),
          throwsA(isA<ApiError>()
              .having((e) => e.kind, 'kind', ApiErrorKind.ip)));
      expect(
          () => client.decodeResponse(
              utf8.encode('{"response":{"msg":"no code"}}')),
          throwsA(isA<ApiError>()
              .having((e) => e.kind, 'kind', ApiErrorKind.api)));
      expect(
          () => client.decodeResponse(utf8.encode('not json')),
          throwsA(isA<ApiError>()
              .having((e) => e.kind, 'kind', ApiErrorKind.api)));
      expect(
          () => client.decodeResponse(utf8.encode('[]')),
          throwsA(isA<ApiError>()
              .having((e) => e.kind, 'kind', ApiErrorKind.api)));
    });
    test('code 1 without IP is not an ip error', () {
      final client = testClient(FakeTransport());
      expect(
          client.decodeResponse(
              utf8.encode('{"response":{"code":1,"msg":"busy"}}'))['code'],
          1);
    });
  });

  group('request', () {
    test('rejects non-/s/ paths and non-positive timeouts', () async {
      final client = testClient(FakeTransport());
      await expectLater(client.request('GET', '/other/path'),
          throwsA(isA<ApiError>().having((e) => e.kind, 'kind',
              ApiErrorKind.api)));
      await expectLater(
          client.request('GET', '/s/x', timeoutSec: 0),
          throwsA(isA<ApiError>().having((e) => e.kind, 'kind',
              ApiErrorKind.api)));
    });
    test('fixed headers + session headers + extra override', () async {
      final transport = FakeTransport();
      transport.onJson('/s/c/clerk/get', {'code': 0});
      final client = testClient(transport);
      await client.clerkGet(session: _session);
      final req = transport.requests.single;
      expect(req.headers['User-Agent'], ApiClient.userAgent);
      expect(req.headers['api-version'], '202501071');
      expect(req.headers['platform'], 'app');
      expect(req.headers['authorization-token'], 'tok-1');
      expect(req.headers['sid'], '92');
    });
    test('form body is sorted and percent-encoded', () async {
      final transport = FakeTransport();
      transport.onJson('/s/duopei-account/switch-account', {'code': 0});
      final client = testClient(transport);
      await client.request('POST', '/s/duopei-account/switch-account',
          session: _session,
          body: {'b key': 'v&v', 'accountId': '12'},
          bodyType: BodyType.form);
      final req = transport.requests.single;
      expect(req.headers['Content-Type'],
          'application/x-www-form-urlencoded');
      expect(req.bodyText, 'accountId=12&b%20key=v%26v');
    });
    test('HTTP 401/403 -> auth; other 4xx/5xx -> network', () async {
      final transport = FakeTransport();
      transport.on(
          '/s/c/clerk/get',
          (_) => HttpResponse(
              statusCode: 401, bodyBytes: utf8.encode('{}')));
      final client = testClient(transport);
      await expectLater(client.clerkGet(session: _session),
          throwsA(isA<ApiError>().having((e) => e.kind, 'kind',
              ApiErrorKind.auth)));
      transport.handlers.clear();
      transport.on(
          '/s/c/clerk/get',
          (_) => HttpResponse(
              statusCode: 500, bodyBytes: utf8.encode('{}')));
      await expectLater(client.clerkGet(session: _session),
          throwsA(isA<ApiError>().having((e) => e.kind, 'kind',
              ApiErrorKind.network)));
    });
    test('transport exceptions become network errors', () async {
      final transport = FakeTransport();
      transport.on('/s/c/clerk/get',
          (_) => throw const SocketExceptionClosedForTest());
      final client = testClient(transport);
      await expectLater(client.clerkGet(session: _session),
          throwsA(isA<ApiError>().having((e) => e.kind, 'kind',
              ApiErrorKind.network)));
    });
    test('no session fails explicitly; the client mirror is never used',
        () async {
      final transport = FakeTransport();
      transport.onJson('/s/c/clerk/get', {'code': 0});
      final client = testClient(transport);
      // No session at all: the call must fail before touching the
      // transport, not silently retry with a stale mirror.
      await expectLater(client.clerkGet(),
          throwsA(isA<ApiError>()
              .having((e) => e.kind, 'kind', ApiErrorKind.auth)
              .having((e) => e.message, 'message',
                  contains('no session'))));
      expect(transport.requests, isEmpty);
      // Even with the mirror set, a call without an explicit session
      // still fails — the mirror is display-only.
      client.session = _session;
      await expectLater(client.clerkGet(),
          throwsA(isA<ApiError>().having((e) => e.kind, 'kind',
              ApiErrorKind.auth)));
      expect(transport.requests, isEmpty);
      // And the explicit session is what actually goes out.
      await client.clerkGet(session: _session);
      expect(transport.requests.single.headers['authorization-token'],
          'tok-1');
    });
  });

  group('loginAccount', () {
    test('sends MD5-hex password, sid -1, empty token; sid from shopId',
        () async {
      final transport = FakeTransport();
      transport.onJson('/s/duopei-account/login', {
        'code': 0,
        'data': {'token': 'tok-abc', 'shopId': 1391},
      });
      final client = testClient(transport);
      final session = await client.loginAccount('13800000000', 'abc');
      expect(session.token, 'tok-abc');
      expect(session.sid, '1391'); // never hard-coded "50"
      final req = transport.requests.single;
      expect(req.headers['sid'], '-1');
      expect(req.headers['authorization-token'], '');
      expect(req.bodyJson['password'],
          '900150983cd24fb0d6963f7d28e17f72'); // md5('abc')
      expect(req.bodyJson['method'], 'password');
      expect(req.bodyJson['phoneNumber']['mobile'], '13800000000');
      expect(req.bodyJson.containsKey('password_hash'), isFalse);
    });
    test('missing shopId falls back to 50; missing token rejects', () async {
      final transport = FakeTransport();
      transport.onJson('/s/duopei-account/login', {
        'code': 0,
        'data': {'token': 'tok-abc'},
      });
      final client = testClient(transport);
      expect((await client.loginAccount('13800000000', 'abc')).sid, '50');
      transport.handlers.clear();
      transport.onJson('/s/duopei-account/login', {
        'code': 0,
        'data': {},
      });
      await expectLater(client.loginAccount('13800000000', 'abc'),
          throwsA(isA<ApiError>().having((e) => e.kind, 'kind',
              ApiErrorKind.auth)));
    });
    test('empty phone/password rejected without a request', () async {
      final transport = FakeTransport();
      final client = testClient(transport);
      await expectLater(client.loginAccount('', 'abc'),
          throwsA(isA<ApiError>()));
      expect(transport.requests, isEmpty);
    });
  });

  group('sessionForAccount', () {
    Future<void> loginStubs(FakeTransport transport,
        {List<Map<String, dynamic>> shops = const [
          {'shopId': 92, 'accountId': 'a92'},
          {'shopId': 50, 'accountId': 'a50'},
        ]}) async {
      transport.onJson('/s/duopei-account/login', {
        'code': 0,
        'data': {'token': 'base-tok', 'shopId': 92},
      });
      transport.onJson('/s/duopei-account/list-shop-account', {
        'code': 0,
        'data': shops,
      });
    }

    test('preferred shop first; confirmed clerk seat wins', () async {
      final transport = FakeTransport();
      await loginStubs(transport);
      transport.onJson('/s/duopei-account/switch-account',
          {'code': 0, 'data': {'token': 'tok-50'}});
      transport.onJson('/s/balance/getBalance', {'code': 0});
      transport.onJson('/s/c/clerk/get', {
        'code': 0,
        'clerk': {'id': 7, 'name': ' ClerkA '},
      });
      final client = testClient(transport);
      final session = await client.sessionForAccount('13800000000', 'abc',
          preferredShopId: 50);
      expect(session.sid, '50');
      expect(session.token, 'tok-50');
      // switch-account was called with the preferred shop's accountId.
      final switchReq = transport.requests
          .firstWhere((r) => r.url.path.contains('switch-account'));
      expect(switchReq.bodyForm['accountId'], 'a50');
      expect(switchReq.headers['sid'], '92'); // login sid, not "50"
    });

    test('denied shop is skipped; unknown becomes fallback', () async {
      final transport = FakeTransport();
      await loginStubs(transport);
      var switchCount = 0;
      transport.on('/s/duopei-account/switch-account', (_) {
        switchCount++;
        return HttpResponse(
            statusCode: 200,
            bodyBytes: utf8.encode(jsonEncode({
              'response': {
                'code': 0,
                'data': {'token': 'tok-$switchCount'},
              },
              'isEncrypted': false,
            })));
      });
      transport.onJson('/s/balance/getBalance', {'code': 0});
      // clerk/get returns no seat -> denied for shop 92; randomList
      // probe also fails with a permission message for shop 50... but
      // clerk/get itself returns denied, so both shops are denied and
      // the flow must fail with auth.
      transport.onJson('/s/c/clerk/get', {'code': 0, 'data': {}});
      final client = testClient(transport);
      await expectLater(
          client.sessionForAccount('13800000000', 'abc'),
          throwsA(isA<ApiError>().having((e) => e.kind, 'kind',
              ApiErrorKind.auth)));
      expect(switchCount, 2);
    });

    test('inconclusive probe parks a fallback session', () async {
      final transport = FakeTransport();
      await loginStubs(transport,
          shops: [
            {'shopId': 92, 'accountId': 'a92'}
          ]);
      transport.onJson('/s/duopei-account/switch-account',
          {'code': 0, 'data': {'token': 'tok-92'}});
      transport.onJson('/s/balance/getBalance', {'code': 0});
      // clerk/get errors (code 500) -> unknown; randomList succeeds ->
      // confirmed via the business probe.
      var clerkCalls = 0;
      transport.on('/s/c/clerk/get', (_) {
        clerkCalls++;
        return HttpResponse(
            statusCode: 200,
            bodyBytes: utf8.encode(jsonEncode({
              'response': {'code': 500, 'msg': 'oops'},
              'isEncrypted': false,
            })));
      });
      transport.onJson('/s/c/order/randomList',
          {'code': 0, 'list': []});
      final client = testClient(transport);
      final session = await client.sessionForAccount('13800000000', 'abc');
      expect(session.sid, '92');
      expect(clerkCalls, 1);
    });
  });

  group('business calls', () {
    test('randomList: missing list is empty, data.list works', () async {
      final transport = FakeTransport();
      transport.onJson('/s/c/order/randomList', {'code': 0});
      final client = testClient(transport);
      expect(await client.randomList(session: _session), isEmpty);
      transport.handlers.clear();
      transport.onJson('/s/c/order/randomList', {
        'code': 0,
        'data': {
          'list': [fakeOrder()]
        },
      });
      final orders = await client.randomList(session: _session);
      expect(orders, hasLength(1));
      expect(orders.first['id'], '15650502');
    });

    test('clerkStatistics returns the list dict, {} on failure', () async {
      final transport = FakeTransport();
      transport.onJson('/s/c/statistics/statisticsClerkOrder', {
        'code': 0,
        'list': {'orderCount': 8, 'continuedCount': 2},
      });
      final client = testClient(transport);
      final stats = await client.clerkStatistics('2026-11-09', '2026-11-14',
          session: _session);
      expect(stats['orderCount'], 8);
      expect(transport.requests.single.url.queryParameters['startTime'],
          '2026-11-09');
      transport.handlers.clear();
      transport.onJson('/s/c/statistics/statisticsClerkOrder',
          {'code': 1, 'msg': 'bad'});
      expect(
          await client.clerkStatistics('2026-11-09', '2026-11-14',
              session: _session),
          isEmpty);
    });

    test('setOnline / setRandomOrderSwitch send form bodies', () async {
      final transport = FakeTransport();
      transport.onJson('/s/c/clerk/updateStatus', {'code': 0});
      transport.onJson('/s/c/clerk/updateRandomOrderSwitch', {'code': 0});
      final client = testClient(transport);
      await client.setOnline(1, updateAutoOnline: true, session: _session);
      await client.setRandomOrderSwitch(false, session: _session);
      expect(transport.requests[0].bodyForm,
          {'status': '1', 'updateAutoOnline': 'true'});
      expect(transport.requests[1].bodyForm,
          {'randomOrderSwitch': 'false'});
    });

    test('itemSwitchList sends an empty JSON body (Q-09: PC code)',
        () async {
      final transport = FakeTransport();
      transport.onJson('/s/c/clerk/getItemSwitchList',
          {'code': 0, 'itemSwitchList': []});
      final client = testClient(transport);
      await client.itemSwitchList(session: _session);
      final req = transport.requests.single;
      expect(req.headers['Content-Type'], 'application/json');
      expect(req.bodyText, '{}');
    });

    test('setItemSwitch sends switchIds as a JSON array string', () async {
      final transport = FakeTransport();
      transport.onJson('/s/c/clerk/updateItemSwitch', {'code': 0});
      final client = testClient(transport);
      await client.setItemSwitch(465, [465, 2666], session: _session);
      expect(transport.requests.single.bodyForm,
          {'switchId': '465', 'switchIds': '[465,2666]'});
    });

    test('orderTotal reads total; -1 on refusal', () async {
      final transport = FakeTransport();
      transport.onJson('/s/c/order/list',
          {'code': 0, 'total': 8});
      final client = testClient(transport);
      expect(
          await client.orderTotal(
              '2026-11-09 00:00:00', '2026-11-14 23:59:59',
              session: _session),
          8);
      expect(transport.requests.single.url.queryParameters['pageNo'], '1');
      transport.handlers.clear();
      transport.onJson('/s/c/order/list', {'code': 1, 'msg': 'no'});
      expect(
          await client.orderTotal(
              '2026-11-09 00:00:00', '2026-11-14 23:59:59',
              session: _session),
          -1);
    });
  });
}

/// Stand-in for a transport failure (avoids importing dart:io here).
class SocketExceptionClosedForTest implements Exception {
  const SocketExceptionClosedForTest();
  @override
  String toString() => 'SocketException (test stub)';
}
