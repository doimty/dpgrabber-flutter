/// In-memory run log (PORTING_CONTRACT §12 Q-14, §10.3).
///
/// Cap: 500 entries (§10.3 / iOS snapshot). The log lives only in
/// memory and is cleared on exit — the UI must say so (footer note).
/// The view is a retained-mode list over [entries]: entries are never
/// dropped by a window resize/maximise (PC lesson — the log must
/// survive maximise).
library;

import 'package:flutter/foundation.dart';

import '../core.dart';

/// Maximum in-memory log entries (§12 Q-14).
const int maxLogEntries = 500;

class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String message;

  const LogEntry({
    required this.time,
    required this.level,
    required this.message,
  });

  String get levelName => level.name;
}

class LogStore extends ChangeNotifier {
  final List<LogEntry> _entries = [];

  List<LogEntry> get entries => List.unmodifiable(_entries);

  int get length => _entries.length;

  void add(LogLevel level, String message) {
    _entries.add(LogEntry(time: DateTime.now(), level: level, message: message));
    if (_entries.length > maxLogEntries) {
      _entries.removeRange(0, _entries.length - maxLogEntries);
    }
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }
}
