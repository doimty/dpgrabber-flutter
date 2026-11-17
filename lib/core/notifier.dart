/// Push notifications (PORTING_CONTRACT §8, PC `notify.py`).
///
/// Only sent on a successful grab, only when `notify_enabled` is true.
/// `send` never throws and never blocks the grab loop; the caller runs
/// it off the listening path. `notify_provider` selects the channel;
/// an illegal provider falls back to `serverchan` (config validation).
/// The webhook copy in PC's Advanced settings ("non-empty webhook
/// wins over the key") contradicts the code — the code wins (D-51):
/// `notify_webhook` is used only when provider == webhook.
library;

import 'dart:convert';
import 'dart:io';

import 'config.dart';

const Map<String, String> providerNames = {
  'bark': 'Bark',
  'serverchan': 'Server酱',
  'pushplus': 'PushPlus',
  'webhook': '自定义 Webhook',
};

/// `POST url` returning (status, body text). Injectable for tests.
typedef PostFn = Future<(int status, String body)> Function(
  Uri url,
  List<int> body,
  Map<String, String> headers,
  Duration timeout,
);

Future<(int, String)> _defaultPost(
  Uri url,
  List<int> body,
  Map<String, String> headers,
  Duration timeout,
) async {
  final client = HttpClient();
  client.connectionTimeout = timeout;
  try {
    final req = await client.openUrl('POST', url);
    headers.forEach(req.headers.set);
    req.add(body);
    final resp = await req.close().timeout(timeout);
    final text = await resp.transform(utf8.decoder).join().timeout(timeout);
    return (resp.statusCode, text);
  } finally {
    client.close(force: true);
  }
}

class Notifier {
  final AppConfig config;
  final PostFn _post;

  Notifier(this.config, {PostFn? post}) : _post = post ?? _defaultPost;

  bool get enabled => config.notifyEnabled;

  String get provider =>
      notifyProviders.contains(config.notifyProvider)
          ? config.notifyProvider
          : 'serverchan';

  String describe() => providerNames[provider] ?? provider;

  /// Best-effort push. Returns true only when the channel accepted it.
  Future<bool> send(String title, String body) async {
    if (!enabled) return false;
    try {
      switch (provider) {
        case 'bark':
          return await _bark(title, body);
        case 'serverchan':
          return await _serverchan(title, body);
        case 'pushplus':
          return await _pushplus(title, body);
        default:
          return await _webhook(title, body);
      }
    } catch (_) {
      return false;
    }
  }

  /// The grab-success push (§8.1/§8.2): title `抢单成功 <no>`, body
  /// `金额 <amount> 元\n订单 <no>\n时间 <grabbed_at>`.
  Future<bool> sendGrab({
    required String orderNo,
    required double amount,
    required String grabbedAt,
  }) =>
      send(
        '抢单成功 $orderNo',
        '金额 ${amount.toStringAsFixed(2)} 元\n订单 $orderNo\n时间 $grabbedAt',
      );

  Future<bool> _bark(String title, String body) async {
    final key = config.notifyKey.trim();
    if (key.isEmpty) return false;
    final server = config.notifyBarkServer.trim();
    final lower = server.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return false;
    }
    final url = Uri.parse(
        '${server.replaceAll(RegExp(r'/+$'), '')}/push');
    final payload = utf8.encode(jsonEncode({
      'device_key': key,
      'title': title,
      'body': body,
      'group': 'DPGrabber',
    }));
    final (status, text) =
        await _post(url, payload, {'Content-Type': 'application/json'},
            const Duration(seconds: 8));
    return status == 200 && text.replaceAll(' ', '').contains('"code":200');
  }

  Future<bool> _serverchan(String title, String body) async {
    final key = config.notifyKey.trim();
    if (key.isEmpty) return false;
    final url =
        Uri.parse('https://sctapi.ftqq.com/${Uri.encodeComponent(key)}.send');
    final payload = utf8.encode(Uri(queryParameters: {
      'title': title,
      'desp': body,
    }).query);
    final (status, text) = await _post(
        url,
        payload,
        {'Content-Type': 'application/x-www-form-urlencoded'},
        const Duration(seconds: 8));
    return status == 200 && text.replaceAll(' ', '').contains('"code":0');
  }

  Future<bool> _pushplus(String title, String body) async {
    final token = config.notifyKey.trim();
    if (token.isEmpty) return false;
    final payload = utf8.encode(jsonEncode({
      'token': token,
      'title': title,
      'content': body,
      'template': 'txt',
    }));
    final (status, text) = await _post(
        Uri.parse('https://www.pushplus.plus/send'),
        payload,
        {'Content-Type': 'application/json'},
        const Duration(seconds: 8));
    return status == 200 && text.replaceAll(' ', '').contains('"code":200');
  }

  Future<bool> _webhook(String title, String body) async {
    final urlText = config.notifyWebhook.trim();
    final lower = urlText.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return false;
    }
    final payload =
        utf8.encode(jsonEncode({'title': title, 'body': body}));
    final (status, _) = await _post(Uri.parse(urlText), payload,
        {'Content-Type': 'application/json'}, const Duration(seconds: 8));
    return status >= 200 && status < 300;
  }
}
