import 'dart:convert';

import 'package:dpgrabber/core.dart';
import 'package:flutter_test/flutter_test.dart';


void main() {
  AppConfig cfg({
    bool enabled = true,
    String provider = 'bark',
    String key = 'device-key-1',
    String server = 'https://api.day.app',
    String webhook = '',
  }) =>
      AppConfig.defaults().copyWith(
        notifyEnabled: enabled,
        notifyProvider: provider,
        notifyKey: key,
        notifyBarkServer: server,
        notifyWebhook: webhook,
      );

  group('Notifier.send', () {
    test('bark posts device_key/title/body/group and checks code 200',
        () async {
      Uri? seenUrl;
      List<int>? seenBody;
      final n = Notifier(cfg(), post: (url, body, headers, timeout) async {
        seenUrl = url;
        seenBody = body;
        return (200, '{"code":200,"message":"success"}');
      });
      expect(await n.send('t', 'b'), isTrue);
      expect(seenUrl.toString(), 'https://api.day.app/push');
      final payload = jsonDecode(utf8.decode(seenBody!));
      expect(payload['device_key'], 'device-key-1');
      expect(payload['group'], 'DPGrabber');
    });

    test('bark fails on non-200, wrong code, empty key, bad server',
        () async {
      final ok = Notifier(cfg(), post: (_, _, _, _) async =>
          (200, '{"code":200}'));
      expect(await ok.send('t', 'b'), isTrue);
      final badCode = Notifier(cfg(), post: (_, _, _, _) async =>
          (200, '{"code":400}'));
      expect(await badCode.send('t', 'b'), isFalse);
      final badStatus = Notifier(cfg(), post: (_, _, _, _) async =>
          (500, '{"code":200}'));
      expect(await badStatus.send('t', 'b'), isFalse);
      expect(await Notifier(cfg(key: ''), post: (_, _, _, _) async =>
          (200, '{"code":200}')).send('t', 'b'), isFalse);
      expect(
          await Notifier(cfg(server: 'api.day.app'),
                  post: (_, _, _, _) async => (200, '{"code":200}'))
              .send('t', 'b'),
          isFalse);
    });

    test('disabled notifier never posts', () async {
      var called = false;
      final n = Notifier(cfg(enabled: false), post: (_, _, _, _) async {
        called = true;
        return (200, '{"code":200}');
      });
      expect(await n.send('t', 'b'), isFalse);
      expect(called, isFalse);
    });

    test('serverchan uses the .send form endpoint and code 0', () async {
      Uri? seenUrl;
      final n = Notifier(cfg(provider: 'serverchan', key: 'send-key'),
          post: (url, body, headers, timeout) async {
        seenUrl = url;
        expect(headers['Content-Type'],
            'application/x-www-form-urlencoded');
        return (200, '{"code":0,"message":"ok"}');
      });
      expect(await n.send('t', 'b'), isTrue);
      expect(seenUrl.toString(),
          'https://sctapi.ftqq.com/send-key.send');
    });

    test('pushplus posts token/title/content/template', () async {
      Map<String, dynamic>? payload;
      final n = Notifier(cfg(provider: 'pushplus', key: 'pp-token'),
          post: (url, body, headers, timeout) async {
        payload = jsonDecode(utf8.decode(body));
        return (200, '{"code":200}');
      });
      expect(await n.send('t', 'b'), isTrue);
      expect(payload?['token'], 'pp-token');
      expect(payload?['template'], 'txt');
    });

    test('webhook posts {title, body} and accepts any 2xx', () async {
      final n = Notifier(
          cfg(provider: 'webhook', webhook: 'https://example.com/hook'),
          post: (_, _, _, _) async => (201, 'ok'));
      expect(await n.send('t', 'b'), isTrue);
      final bad = Notifier(cfg(provider: 'webhook', webhook: 'not-a-url'),
          post: (_, _, _, _) async => (200, 'ok'));
      expect(await bad.send('t', 'b'), isFalse);
    });

    test('illegal provider falls back to serverchan', () async {
      final n = Notifier(cfg(provider: 'nope', key: 'k'),
          post: (url, _, _, _) async {
        expect(url.host, 'sctapi.ftqq.com');
        return (200, '{"code":0}');
      });
      expect(n.provider, 'serverchan');
      expect(await n.send('t', 'b'), isTrue);
    });

    test('transport exceptions never throw', () async {
      final n = Notifier(cfg(), post: (_, _, _, _) async {
        throw StateError('boom');
      });
      expect(await n.send('t', 'b'), isFalse);
    });

    test('sendGrab builds the §8.2 title/body', () async {
      String? bodyText;
      final n = Notifier(cfg(), post: (url, body, headers, timeout) async {
        bodyText = utf8.decode(body);
        return (200, '{"code":200}');
      });
      expect(
          await n.sendGrab(
            orderNo: '26111401581302023638',
            amount: 30,
            grabbedAt: '2026-11-14T01:58:33',
          ),
          isTrue);
      final payload = jsonDecode(bodyText!);
      expect(payload['title'], '抢单成功 26111401581302023638');
      expect(payload['body'],
          '金额 30.00 元\n订单 26111401581302023638\n时间 2026-11-14T01:58:33');
    });
  });
}
