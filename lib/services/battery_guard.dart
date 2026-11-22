import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sharing_state_notifier.dart';

/// Pauses location sharing when the battery gets low.
///
/// The threshold is user-configurable in Settings → Battery. It resumes
/// automatically when the phone is charging or the level recovers a few
/// points above the threshold (hysteresis), so it cannot flap at the edge.
class BatteryGuard {
  BatteryGuard._();
  static final BatteryGuard instance = BatteryGuard._();

  static const String thresholdKey = 'pause_battery_threshold';

  final Battery _battery = Battery();
  final SharingStateNotifier _state = SharingStateNotifier.instance;

  StreamSubscription<BatteryState>? _stateSub;
  Timer? _timer;
  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _stateSub = _battery.onBatteryStateChanged.listen((_) => checkNow());
    // Battery state changes cover plug/unplug; the timer catches the slow
    // discharge between those events.
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => checkNow());
    await checkNow();
  }

  Future<void> stop() async {
    await _stateSub?.cancel();
    _stateSub = null;
    _timer?.cancel();
    _timer = null;
    _started = false;
  }

  Future<int> threshold() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(thresholdKey) ?? 0;
  }

  Future<void> setThreshold(int percent) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(thresholdKey, percent);
    await checkNow();
  }

  /// Re-evaluates the current level against the configured threshold.
  Future<void> checkNow() async {
    try {
      final limit = await threshold();
      if (limit <= 0) {
        _state.setPausedForBattery(false);
        return;
      }

      final level = await _battery.batteryLevel;
      final status = await _battery.batteryState;
      final charging =
          status == BatteryState.charging || status == BatteryState.full;

      if (!charging && level <= limit) {
        _state.setPausedForBattery(true);
      } else if (charging || level > limit + 5) {
        _state.setPausedForBattery(false);
      }
    } catch (e) {
      // Battery APIs must never take down the app.
      debugPrint('[Battery] guard check failed: $e');
    }
  }
}
