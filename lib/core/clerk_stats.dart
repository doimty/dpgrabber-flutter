/// Clerk week statistics and the three rates (PORTING_CONTRACT §1.2,
/// §10.8; PC `dpapi.clerk_statistics` + `ui._on_week_orders`).
///
/// PC-only feature: the Android/iOS snapshots have no week statistics.
/// Formulas (PC code):
/// - 续费率 renewalRate = continuedAmount / orderAmount * 100 (money)
/// - 续单率 orderRate   = continuedCount / orderCount * 100 (orders)
/// - 续客率 userRate    = continuedUserCount / totalOrderCount * 100
library;

import 'api_client.dart';
import 'models.dart';

/// Renewal target: below 30% the platform refuses random orders (§10.8).
const double renewalTarget = 30.0;

class ClerkStatistics {
  final int orderCount;
  final int continuedCount;
  final int continuedUserCount;
  final int totalOrderCount;
  final double continuedAmount; // cents
  final double orderAmount; // cents
  final int firstCount;
  final int refundedCount;

  /// All other server fields, kept verbatim (never dropped).
  final Map<String, dynamic> raw;

  const ClerkStatistics({
    required this.orderCount,
    required this.continuedCount,
    required this.continuedUserCount,
    required this.totalOrderCount,
    required this.continuedAmount,
    required this.orderAmount,
    required this.firstCount,
    required this.refundedCount,
    required this.raw,
  });

  factory ClerkStatistics.fromMap(Map<String, dynamic> map) {
    int asInt(dynamic v) {
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v.trim()) ?? 0;
      return 0;
    }

    double asDouble(dynamic v) {
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v.trim()) ?? 0.0;
      return 0.0;
    }

    return ClerkStatistics(
      orderCount: asInt(map['orderCount']),
      continuedCount: asInt(map['continuedCount']),
      continuedUserCount: asInt(map['continuedUserCount']),
      totalOrderCount: asInt(map['totalOrderCount']),
      continuedAmount: asDouble(map['continuedAmount']),
      orderAmount: asDouble(map['orderAmount']),
      firstCount: asInt(map['firstCount']),
      refundedCount: asInt(map['refundedCount']),
      raw: Map.unmodifiable(map),
    );
  }

  static double? _ratio(double numerator, double denominator) {
    if (denominator <= 0) return null;
    return 100.0 * numerator / denominator;
  }

  /// 续费率 (money ratio). Null when the denominator is <= 0 / missing.
  double? get renewalRate => _ratio(continuedAmount, orderAmount);

  /// 续单率 (order-count ratio).
  double? get orderRate =>
      _ratio(continuedCount.toDouble(), orderCount.toDouble());

  /// 续客率 (user ratio).
  ///
  /// TODO(OPEN-Q10): PC code divides by `totalOrderCount`; HANDOFF
  /// §4.1 says the denominator is `orderCount` (D-31). PC code is
  /// followed here; the user still has to decide.
  double? get userRate =>
      _ratio(continuedUserCount.toDouble(), totalOrderCount.toDouble());

  /// Detail lines for the stats tooltip (§10.8), amounts in yuan.
  List<String> detailLines() {
    final lines = <String>[];
    final fee = renewalRate;
    lines.add('续费率（金额比）${fee == null ? '—' : '${fee.toStringAsFixed(1)}%'} '
        '= 续单金额 ${(continuedAmount / 100).toStringAsFixed(2)} '
        '/ 订单金额 ${(orderAmount / 100).toStringAsFixed(2)}');
    final order = orderRate;
    if (order != null) {
      lines.add('续单率（单数比）${order.toStringAsFixed(1)}% '
          '= $continuedCount/$orderCount 单');
    }
    final user = userRate;
    if (user != null) {
      lines.add('续客率（人数比）${user.toStringAsFixed(1)}% '
          '= $continuedUserCount/$totalOrderCount 人');
    }
    return lines;
  }
}

/// Monday (yyyy-MM-dd) of the week containing [day].
DateTime weekMonday(DateTime day) {
  final d = DateTime(day.year, day.month, day.day);
  return d.subtract(Duration(days: d.weekday - 1));
}

String _dateOnly(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Fetch this week's statistics (Monday -> today). Returns the
/// statistics, or — when the statistics call comes back empty — the
/// order-total fallback count (PC `_fetch_week_orders`: log a warning
/// "本周统计为空，改用订单总数：N"). Exactly one of the two is set.
Future<({ClerkStatistics? stats, int? fallbackOrderTotal})>
    fetchWeekStatistics(
  ApiClient client, {
  Session? session,
  DateTime? now,
}) async {
  final today = now ?? DateTime.now();
  final monday = weekMonday(today);
  final mondayText = _dateOnly(monday);
  final todayText = _dateOnly(today);
  final raw = await client.clerkStatistics(mondayText, todayText,
      session: session);
  if (raw.isNotEmpty) {
    return (stats: ClerkStatistics.fromMap(raw), fallbackOrderTotal: null);
  }
  final total = await client.orderTotal(
    '$mondayText 00:00:00',
    '$todayText 23:59:59',
    session: session,
  );
  return (stats: null, fallbackOrderTotal: total);
}
