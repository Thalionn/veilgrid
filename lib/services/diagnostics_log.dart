import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DiagnosticEntry {
  const DiagnosticEntry(this.at, this.tag, this.message);
  final DateTime at;
  final String tag;
  final String message;

  String format() {
    String two(int n) => n.toString().padLeft(2, '0');
    final t = '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
    return '$t $tag $message';
  }
}

/// In-memory, opt-in diagnostic ring buffer. Coordinates stay on the device
/// and are only copied/shared when the user explicitly taps that action.
class DiagnosticsLog extends ChangeNotifier {
  DiagnosticsLog._();
  static final DiagnosticsLog instance = DiagnosticsLog._();

  static const _prefsKey = 'battery_diagnostics_enabled';
  static const int _maxEntries = 2000;

  bool _enabled = true;
  bool get enabled => _enabled;

  final List<DiagnosticEntry> _entries = [];
  List<DiagnosticEntry> get entries => List.unmodifiable(_entries);

  Timer? _notifyTimer;
  bool _dirty = false;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_prefsKey) ?? true;
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, value);
    if (value) log('LOG', 'diagnostics enabled');
  }

  void log(String tag, String message) {
    if (!_enabled) return;
    _entries.insert(0, DiagnosticEntry(DateTime.now(), tag, message));
    if (_entries.length > _maxEntries) _entries.removeLast();
    // A GPS fix every few seconds must not trigger a full UI rebuild each time.
    if (_notifyTimer == null) {
      _notifyTimer = Timer(const Duration(milliseconds: 500), () {
        _notifyTimer = null;
        if (_dirty) {
          _dirty = false;
          notifyListeners();
        }
      });
    }
    _dirty = true;
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  String exportText() => _entries.reversed.map((e) => e.format()).join('\n');
}
