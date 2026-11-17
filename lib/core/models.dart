/// Data models and pure helpers shared by the DPGrabber core.
///
/// Ported from `pc/dpapi.py` (`Session` / `ApiError` / `extract_clerk` /
/// `normalize_ms` / `amount_yuan_from_cents` / `_parse_code`) and
/// `pc/history.py` (`HistoryEntry`), per PORTING_CONTRACT §1.2 / §1.4.
/// Nothing in this file touches the network or the clock.
library;

/// Error kinds; the three platforms must agree on these names (§1.2).
enum ApiErrorKind { auth, ip, api, network, cancelled }

/// One failure of an API call.
class ApiError implements Exception {
  final ApiErrorKind kind;
  final String message;
  const ApiError(this.kind, this.message);

  @override
  String toString() => 'ApiError($kind): $message';
}

/// A logged-in session: token + shop id. Memory only, never persisted.
class Session {
  final String token;
  final String sid;
  const Session({required this.token, this.sid = '50'});

  Session copyWith({String? token, String? sid}) =>
      Session(token: token ?? this.token, sid: sid ?? this.sid);
}

/// Clerk extracted from `GET /s/c/clerk/get` (§1.2).
class Clerk {
  final int id;
  final int? shopId;
  final String? name;
  const Clerk({required this.id, this.shopId, this.name});

  factory Clerk.fromMap(Map<String, dynamic> map) {
    int id = 0;
    final rawId = map['id'];
    if (rawId is num) {
      id = rawId.toInt();
    } else if (rawId is String) {
      id = int.tryParse(rawId.trim()) ?? 0;
    }
    int? shopId;
    final rawShop = map['shopId'];
    if (rawShop is num) {
      shopId = rawShop.toInt();
    } else if (rawShop is String) {
      shopId = int.tryParse(rawShop.trim());
    }
    final rawName = map['name'];
    return Clerk(
      id: id,
      shopId: shopId,
      name: rawName?.toString(),
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        if (shopId != null) 'shopId': shopId,
        if (name != null) 'name': name,
      };
}

/// Order dict carrier. The server's order shape is unstable, so the raw
/// map is carried and fields are read through accessors (§1.2). Never a
/// strict `fromJson` model with required fields.
class Order {
  final Map<String, dynamic> raw;
  const Order(this.raw);

  /// `raw['id']`, numbers converted to string; missing -> ''.
  String get id => orderIdOf(raw);

  /// `raw['no'] ?? id`.
  String get no {
    final v = raw['no'];
    if (v == null) return id;
    return v.toString();
  }

  /// `(raw['totalAmount'] ?? 0) / 100`; when `totalAmount` is 0/missing,
  /// falls back to `raw['servicePrice']` (PROTOCOL.md §5.2).
  double get amountYuan {
    final total = raw['totalAmount'];
    if (total is num && total != 0) return total / 100.0;
    final fallback = raw['servicePrice'];
    if (fallback is num) return fallback / 100.0;
    return 0.0;
  }

  int get createTimeMs => normalizeMs(raw['createTime']);

  String get userWechatId {
    final v = raw['userWechatId'];
    return v == null ? '' : v.toString();
  }

  String get userMemo {
    final v = raw['userMemo'];
    return v == null ? '' : v.toString();
  }

  int? get status {
    final v = raw['status'];
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  int get clerkId {
    final v = raw['clerkId'];
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim()) ?? 0;
    return 0;
  }
}

/// History outcome enum (§7.2).
enum HistoryOutcome { success, failed, risk, unknown, skipped }

/// Parse a history outcome string; unknown values become [HistoryOutcome.unknown].
HistoryOutcome parseHistoryOutcome(String? value) {
  switch (value) {
    case 'success':
      return HistoryOutcome.success;
    case 'failed':
      return HistoryOutcome.failed;
    case 'risk':
      return HistoryOutcome.risk;
    case 'skipped':
      return HistoryOutcome.skipped;
    default:
      return HistoryOutcome.unknown;
  }
}

/// One history entry (§1.2 / §7.4). JSON keys are snake_case, matching PC.
class HistoryEntry {
  final String grabbedAt; // local ISO 'yyyy-MM-ddTHH:mm:ss'
  final String no;
  final String id;
  final double amount; // yuan, 2 decimals
  final String userWechatId;
  final String userMemo;
  final String createTime; // server value as string, may be ''
  final HistoryOutcome outcome;
  final String reason;
  final String account; // current login phone (may be missing on old entries)
  final String clerk; // clerk name (may be missing)

  const HistoryEntry({
    required this.grabbedAt,
    required this.no,
    required this.id,
    required this.amount,
    required this.userWechatId,
    required this.userMemo,
    required this.createTime,
    required this.outcome,
    required this.reason,
    required this.account,
    required this.clerk,
  });

  factory HistoryEntry.fromJson(Map<String, dynamic> json) {
    final rawOutcome = json['outcome'];
    final outcome = (rawOutcome is String && rawOutcome.isNotEmpty)
        ? parseHistoryOutcome(rawOutcome)
        : HistoryOutcome.success; // old entries without outcome were grabs
    final rawReason = json['reason'];
    return HistoryEntry(
      grabbedAt: json['grabbed_at']?.toString() ?? '',
      no: json['no']?.toString() ?? '',
      id: json['id']?.toString() ?? '',
      amount: (json['amount'] is num)
          ? (json['amount'] as num).toDouble()
          : double.tryParse(json['amount']?.toString() ?? '') ?? 0.0,
      userWechatId: json['userWechatId']?.toString() ?? '',
      userMemo: json['userMemo']?.toString() ?? '',
      createTime: json['createTime']?.toString() ?? '',
      outcome: outcome,
      reason: rawReason == null ? '' : rawReason.toString(),
      account: json['account']?.toString() ?? '',
      clerk: json['clerk']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'grabbed_at': grabbedAt,
        'no': no,
        'id': id,
        'amount': double.parse(amount.toStringAsFixed(2)),
        'userWechatId': userWechatId,
        'userMemo': userMemo,
        'createTime': createTime,
        'outcome': outcome.name,
        'reason': reason,
        'account': account,
        'clerk': clerk,
      };
}

/// Normalize a timestamp to integer milliseconds (§1.4):
/// <= 0 -> 0; < 1e12 is seconds -> *1000; otherwise already milliseconds.
int normalizeMs(dynamic value) {
  if (value is bool || value == null) return 0;
  double? parsed;
  if (value is num) {
    parsed = value.toDouble();
  } else if (value is String) {
    parsed = double.tryParse(value.trim());
  } else {
    return 0;
  }
  if (parsed == null || parsed.isNaN || parsed.isInfinite) return 0;
  if (parsed <= 0) return 0;
  if (parsed < 1e12) return (parsed * 1000).toInt();
  return parsed.toInt();
}

/// Order amount in cents -> yuan; invalid -> 0.0.
double amountYuanFromCents(dynamic value) {
  if (value is num) return value.toDouble() / 100.0;
  if (value is String) return (double.tryParse(value.trim()) ?? 0.0) / 100.0;
  return 0.0;
}

/// Read the business `code` as an int (number or numeric string);
/// bool / missing / invalid -> null (§1.4).
int? parseCode(Map<String, dynamic> obj) {
  if (!obj.containsKey('code')) return null;
  final code = obj['code'];
  if (code is bool || code == null) return null;
  if (code is int) return code;
  if (code is double) return code == code.truncateToDouble() ? code.toInt() : null;
  if (code is String) {
    final text = code.trim();
    final asInt = int.tryParse(text);
    if (asInt != null) return asInt;
    final asDouble = double.tryParse(text);
    if (asDouble != null && asDouble == asDouble.truncateToDouble()) {
      return asDouble.toInt();
    }
    return null;
  }
  return null;
}

/// Order id as a string; missing -> ''.
String orderIdOf(Map<String, dynamic> order) {
  final value = order['id'];
  return value == null ? '' : value.toString();
}

/// Find the clerk object in a clerk/get response (§1.2): try
/// `response.clerk` -> `response.data` -> the top level, in that order;
/// take the first dict with a positive integer `id`. PC also accepts
/// `response.data` itself being the clerk object, which this covers
/// because `data` is itself a candidate.
Clerk? extractClerk(Map<String, dynamic> decoded) {
  final candidates = <Map<String, dynamic>>[];
  final clerkRaw = decoded['clerk'];
  if (clerkRaw is Map<String, dynamic>) candidates.add(clerkRaw);
  final dataRaw = decoded['data'];
  if (dataRaw is Map<String, dynamic>) candidates.add(dataRaw);
  candidates.add(decoded);
  for (final cand in candidates) {
    final clerk = Clerk.fromMap(cand);
    if (clerk.id > 0) return clerk;
  }
  return null;
}

/// Mask a phone number for logs: keep first 3 and last 4 digits.
String maskPhone(String phone) {
  if (phone.length <= 7) return '***';
  return '${phone.substring(0, 3)}****${phone.substring(phone.length - 4)}';
}

/// Format a [DateTime] as local ISO 'yyyy-MM-ddTHH:mm:ss' (history
/// `grabbed_at`, PC `history.py`).
String formatLocalIso(DateTime dt) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)}T'
      '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
}
