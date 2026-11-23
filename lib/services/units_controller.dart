import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One switch for every distance and speed shown in the app.
enum MeasurementSystem {
  imperial('Miles', 'ft · mi · mph'),
  metric('Kilometers', 'm · km · km/h');

  const MeasurementSystem(this.label, this.detail);
  final String label;
  final String detail;

  static MeasurementSystem fromPrefValue(String? raw) =>
      MeasurementSystem.values.firstWhere(
        (u) => u.name == raw,
        orElse: () => MeasurementSystem.imperial,
      );
}

/// Below this a contact counts as not moving, so no speed is shown.
const double minDisplaySpeedMps = 1.4;

const double _metersPerMile = 1609.344;
const double _feetPerMeter = 3.28084;

/// Formats a ground distance using the user's chosen system.
///
/// Imperial uses feet below 1000 ft and miles above it; metric uses metres
/// below 1 km and kilometres above it.
String formatDistance(double meters, {bool rounded = false}) {
  if (!meters.isFinite) return '—';
  final imperial =
      UnitsController.instance.system == MeasurementSystem.imperial;
  if (!imperial) {
    if (meters < 1000) {
      return rounded
          ? '${(meters / 10).round() * 10} m'
          : '${meters.round()} m';
    }
    final km = meters / 1000;
    return km < 10 ? '${km.toStringAsFixed(1)} km' : '${km.round()} km';
  }

  final feet = meters * _feetPerMeter;
  if (feet < 1000) {
    final value = rounded ? (feet / 50).round() * 50 : feet.round();
    return '$value ft';
  }
  final miles = meters / _metersPerMile;
  return miles < 10 ? '${miles.toStringAsFixed(1)} mi' : '${miles.round()} mi';
}

/// Speed as "12 mph" or "19 km/h". Null when there is no useful motion.
String? formatSpeed(double? speedMps) {
  if (speedMps == null || speedMps < minDisplaySpeedMps) return null;
  return UnitsController.instance.system == MeasurementSystem.metric
      ? '${(speedMps * 3.6).round()} km/h'
      : '${(speedMps * 2.236936).round()} mph';
}

/// User-selectable measurement system. Defaults to miles, which is what Grid
/// showed before the setting existed; the user can change it from Settings.
class UnitsController extends ChangeNotifier {
  UnitsController._();
  static final UnitsController instance = UnitsController._();

  static const _prefsKey = 'measurement_system';
  static const _legacySpeedKey = 'speed_unit';

  MeasurementSystem _system = MeasurementSystem.imperial;
  MeasurementSystem get system => _system;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    if (saved != null) {
      _system = MeasurementSystem.fromPrefValue(saved);
    } else {
      // Migrate the old speed-only setting so metric users keep km/h.
      final legacy = prefs.getString(_legacySpeedKey);
      _system = legacy == 'kmh'
          ? MeasurementSystem.metric
          : MeasurementSystem.imperial;
      await prefs.setString(_prefsKey, _system.name);
    }
    notifyListeners();
  }

  Future<void> setSystem(MeasurementSystem system) async {
    if (system == _system) return;
    _system = system;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, system.name);
  }
}
