import 'package:grid_frontend/utilities/geo_math.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:libre_location/libre_location.dart' as libre;
import 'package:shared_preferences/shared_preferences.dart';

import '../sharing_state_notifier.dart';
import '../location_manager.dart';

/// Pauses sharing while the user is at their saved home.
///
/// Uses the position stream and a distance check rather than the plugin's
/// OS geofence API: libre_location 0.4.3 throws while parsing its own
/// geofence events on Android (`_Map<Object?, Object?>` cast), so those
/// transitions never arrive. The distance check also handles the case the
/// OS geofence cannot: being **already inside** the radius when home is set
/// (a geofence only reports enter/exit transitions).
///
/// Tracking runs in a foreground service, so the position stream keeps
/// flowing while the app is backgrounded, which is when auto-pause matters.
///
/// Reads `home_location` ("lat,lng"), `home_radius` (metres) and
/// `auto_pause_at_home_enabled`. Radius changes apply immediately through
/// [syncFromPrefs].
class HomeGeofenceService {
  HomeGeofenceService._(this._sharingState);
  static final HomeGeofenceService instance =
      HomeGeofenceService._(SharingStateNotifier.instance);

  final SharingStateNotifier _sharingState;

  // Below this, GPS jitter alone can flip the state.
  static const double _minRadiusM = 50;

  StreamSubscription<libre.Position>? _positionSub;
  bool _started = false;

  double? _homeLat;
  double? _homeLng;
  double? _radiusMeters;
  bool _monitoring = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _positionSub = libre.LibreLocation.positionStream.listen(
      (position) => _evaluate(position.latitude, position.longitude),
      onError: (Object e) {
        // A broken position event must not take the app down.
        debugPrint('[Home] position stream error: $e');
      },
    );
    await syncFromPrefs();
  }

  Future<void> stop() async {
    await _positionSub?.cancel();
    _positionSub = null;
    _monitoring = false;
    _started = false;
  }

  /// Re-reads the home prefs and immediately evaluates the current position
  /// against them, so being home at the moment of setup pauses right away.
  Future<void> syncFromPrefs() async {
    if (_sharingState.userIncognito) {
      _clear();
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool('auto_pause_at_home_enabled') ?? false;
    final raw = prefs.getString('home_location');
    final radius = (prefs.get('home_radius') as num?)?.toDouble() ?? 150;

    if (!enabled || raw == null || raw.isEmpty) {
      _clear();
      return;
    }

    final parts = raw.split(',');
    if (parts.length != 2) {
      _clear();
      return;
    }
    final lat = double.tryParse(parts[0].trim());
    final lng = double.tryParse(parts[1].trim());
    if (lat == null || lng == null) {
      _clear();
      return;
    }

    _homeLat = lat;
    _homeLng = lng;
    _radiusMeters = math.max(radius, _minRadiusM);
    _monitoring = true;

    final me = LocationManager.instance.currentLatLng;
    if (me != null) {
      _evaluate(me.latitude, me.longitude);
    }
  }

  void _clear() {
    _monitoring = false;
    _homeLat = null;
    _homeLng = null;
    _radiusMeters = null;
    _sharingState.setPausedAtHome(false);
  }

  void _evaluate(double lat, double lng) {
    final homeLat = _homeLat;
    final homeLng = _homeLng;
    final radius = _radiusMeters;
    if (!_monitoring || homeLat == null || homeLng == null || radius == null) {
      return;
    }

    final meters = distanceMeters(homeLat, homeLng, lat, lng);
    final paused = _sharingState.pausedAtHome;

    if (!paused && meters <= radius) {
      _sharingState.setPausedAtHome(true);
    } else if (paused && meters > radius + math.max(30, radius * 0.2)) {
      // Hysteresis keeps boundary jitter from flapping the pause state.
      _sharingState.setPausedAtHome(false);
    }
  }
}
