/// Injectable HTTP transport (PORTING_CONTRACT §1.1, §1.7).
///
/// The core layer only depends on this abstraction, so unit tests can
/// stub the network. The production implementation uses `dart:io`
/// [HttpClient]; `verifyTls == false` accepts any certificate (for
/// troubleshooting only — the UI must warn, §2).
library;

import 'dart:async';
import 'dart:io';

/// One HTTP response: status code + raw body bytes.
class HttpResponse {
  final int statusCode;
  final List<int> bodyBytes;
  const HttpResponse({required this.statusCode, required this.bodyBytes});
}

/// Minimal transport interface. [timeout] is the per-request timeout.
///
/// TODO(OPEN-Q11): the contract's tendency is "the caller's timeout is
/// authoritative, no extra grace added" (DPGrabber original +0.5 s and
/// Android OkHttp +500 ms are NOT applied). This implementation adds no
/// grace; confirm with the user before changing.
abstract class HttpTransport {
  Future<HttpResponse> request({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    List<int>? body,
    required Duration timeout,
  });
}

/// Production transport backed by `dart:io` [HttpClient].
class HttpClientTransport implements HttpTransport {
  final bool verifyTls;

  HttpClientTransport({this.verifyTls = true});

  @override
  Future<HttpResponse> request({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    List<int>? body,
    required Duration timeout,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = timeout;
    if (!verifyTls) {
      client.badCertificateCallback = (_, _, _) => true;
    }
    try {
      final req = await client.openUrl(method, url);
      headers.forEach(req.headers.set);
      if (body != null && body.isNotEmpty) req.add(body);
      final resp = await req.close().timeout(timeout);
      final bytes = await resp.fold<List<int>>(
          <int>[], (acc, chunk) => acc..addAll(chunk)).timeout(timeout);
      return HttpResponse(statusCode: resp.statusCode, bodyBytes: bytes);
    } finally {
      client.close(force: true);
    }
  }
}
