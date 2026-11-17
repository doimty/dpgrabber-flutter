/// Small support types for the background feature, mirroring the parts
/// of wenxi's `core/json.dart` the background pipeline relies on.
library;

typedef Json = Map<String, dynamic>;

Json asJson(Object? value) =>
    value is Map<String, dynamic> ? value : <String, dynamic>{};

class AppException implements Exception {
  const AppException(this.message);
  final String message;
  @override
  String toString() => message;
}

void require(bool condition, String message) {
  if (!condition) throw AppException(message);
}

/// Serializes mutations while allowing the next operation after a failure.
class AsyncGate {
  Future<void> _tail = Future.value();
  Future<T> run<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

extension BackgroundJsonExt on Json {
  String? str(String key) {
    final value = this[key];
    return value is String ? value : null;
  }

  int? integer(String key) {
    final value = this[key];
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse('$value');
  }

  double number(String key, double fallback) {
    final value = this[key];
    if (value is num) return value.toDouble();
    return double.tryParse('${this[key]}') ?? fallback;
  }

  Json obj(String key) => asJson(this[key]);
}
