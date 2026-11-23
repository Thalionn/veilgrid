import 'dart:async';
import 'dart:math' as math;

import 'package:libre_location/libre_location.dart' as libre;
import 'package:shared_preferences/shared_preferences.dart';

import '../../utilities/lat_lng_validation.dart';
import '../sharing_state_notifier.dart';
import 'location_service_config.dart';
import 'location_update.dart';

/// User-facing "Sharing mode" — maps to a `libre_location` preset plus a
/// throttling profile inside [LocationDispatch].
enum SharingMode { light, balanced, live }

extension SharingModePref on SharingMode {
  String get prefValue => switch (this) {
        SharingMode.light => 'light',
        SharingMode.balanced => 'balanced',
        SharingMode.live => 'live',
      };

  libre.TrackingPreset get preset => switch (this) {
        SharingMode.light => libre.TrackingPreset.low,
        SharingMode.balanced => libre.TrackingPreset.balanced,
        SharingMode.live => libre.TrackingPreset.high,
      };

  /// The service-layer tier LocationManager pushes for this mode. Kept
  /// beside [preset] so the two mappings cannot drift apart.
  TrackingMode get trackingMode => switch (this) {
        SharingMode.light => TrackingMode.batterySaver,
        SharingMode.balanced => TrackingMode.normal,
        SharingMode.live => TrackingMode.live,
      };

  static SharingMode fromPrefValue(String? raw) => switch (raw) {
        'light' => SharingMode.light,
        'live' => SharingMode.live,
        _ => SharingMode.balanced,
      };
}

/// Coarse activity bucket derived from `libre_location.onActivityChange`.
enum LocationActivity { still, walking, inVehicle, unknown }

/// Decides which raw GPS fixes become Matrix posts.
///
/// Sits between `LocationManager.locationStream` and
/// `RoomService.updateRooms`. Maintains a small state machine driven by
/// the plugin's motion + activity streams; throttles posting per state +
/// per current [SharingMode]; respects [SharingStateNotifier.isPaused]
/// (the single chokepoint that closes both the mid-session-incognito
/// bug and the auto-pause-at-home flow).
///
/// `start()` is idempotent — safe to call once at app boot.
class LocationDispatch {
  LocationDispatch(this._sharingState) {
    instance = this;
  }

  /// The dispatch created at boot, so settings can re-read its throttle.
  static LocationDispatch? instance;

  final SharingStateNotifier _sharingState;

  SharingMode _mode = SharingMode.balanced;

  // Optional user-defined throttle, overriding the per-mode tables.
  bool _customEnabled = false;
  double _customDistanceM = 100;
  Duration _customInterval = const Duration(seconds: 60);
  LocationActivity _activity = LocationActivity.unknown;
  DateTime? _lastPostAt;
  LocationUpdate? _lastPostedLocation;

  /// True after a STILL transition until the next post drains it. Forces
  /// one "final" post when the user stops moving so contacts see the
  /// resting position immediately.
  bool _justEnteredStill = false;

  StreamSubscription<libre.Position>? _motionSub;
  StreamSubscription<libre.ActivityEvent>? _activitySub;

  bool _started = false;

  // Fires once per successful post to rooms. UI (the sharing pill) listens
  // to animate a "just broadcast" cue. Never emits while sharing is paused.
  final _broadcastController = StreamController<void>.broadcast();

  /// Broadcast tick — one event per successful location post to rooms.
  Stream<void> get onBroadcast => _broadcastController.stream;

  /// Mirrors [SharingStateNotifier.isPaused] for callers that only hold a
  /// dispatch reference (e.g. the sharing pill cue).
  bool get isPaused => _sharingState.isPaused;

  /// Called by [RoomService] after a successful post. Suppressed while
  /// paused/incognito so the cue never fires when we aren't really sharing.
  void notifyBroadcast() {
    if (_sharingState.isPaused) return;
    if (_broadcastController.isClosed) return;
    _broadcastController.add(null);
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;

    // Hydrate the user-chosen mode without blocking the start path.
    final prefs = await SharedPreferences.getInstance();
    _mode = SharingModePref.fromPrefValue(prefs.getString('sharing_mode'));
    await reloadSettings();

    _motionSub = libre.LibreLocation.onMotionChange.listen((p) {
      if (!p.isMoving) {
        _justEnteredStill = true;
      }
    });
    _activitySub = libre.LibreLocation.onActivityChange.listen((e) {
      _activity = _mapActivity(e.activity);
    });
  }

  Future<void> stop() async {
    await _motionSub?.cancel();
    _motionSub = null;
    await _activitySub?.cancel();
    _activitySub = null;
    _started = false;
  }

  void dispose() {
    _broadcastController.close();
  }

  SharingMode get mode => _mode;

  /// Re-reads the custom throttle preferences. Called at start and whenever
  /// the battery settings change.
  Future<void> reloadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _customEnabled = prefs.getBool('custom_throttle_enabled') ?? false;
    final seconds = (prefs.getInt('custom_interval_seconds') ?? 60).clamp(15, 3600);
    final meters = (prefs.getInt('custom_distance_meters') ?? 100).clamp(10, 5000);
    _customInterval = Duration(seconds: seconds);
    _customDistanceM = meters.toDouble();
  }

  /// Switches the user-facing mode. Persists the choice, swaps the
  /// underlying `libre_location` preset, and rewires the throttle on
  /// the next fix.
  Future<void> setMode(SharingMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('sharing_mode', mode.prefValue);
    // While paused, LocationManager owns the preset (battery-saving); don't
    // stomp it here or pausing would silently re-enable high accuracy.
    if (_sharingState.isPaused) return;
    try {
      await libre.LibreLocation.setPreset(mode.preset);
    } catch (_) {
      // Plugin may not be tracking yet (e.g. user hasn't granted
      // location permission). The chosen mode is persisted; when
      // tracking starts the chosen preset will be applied via
      // libre's normal start path.
    }
  }

  /// Returns true if [fix] should be posted to Matrix. Records the post
  /// for distance/interval bookkeeping when true.
  bool shouldPost(LocationUpdate fix) {
    if (_sharingState.isPaused) return false;

    // Reject a NaN/Inf/out-of-range fix at the throttle chokepoint. Left
    // through, an invalid fix gets recorded as `_lastPostedLocation`, and the
    // next haversine distance against it is NaN — which never clears the
    // distance threshold, silently wedging distance-based posting until a
    // timed heartbeat bails us out. Dropping it here keeps the bookkeeping
    // anchored to the last *real* position (complements the send-path guard).
    if (!isFiniteLatLng(fix.latitude, fix.longitude)) return false;

    final now = DateTime.now();
    final last = _lastPostAt;
    final prev = _lastPostedLocation;

    // First fix in this session → always send.
    if (last == null || prev == null) {
      _record(fix, now);
      return true;
    }

    // Final-post-on-stop: one decisive update when the user transitions
    // to STILL, so contacts see "arrived" promptly. Then suppression
    // kicks in until motion resumes.
    if (_justEnteredStill) {
      _justEnteredStill = false;
      _record(fix, now);
      return true;
    }

    final elapsed = now.difference(last);
    final distance = _haversineMeters(
      prev.latitude,
      prev.longitude,
      fix.latitude,
      fix.longitude,
    );
    // A custom cadence is for check-ins while resting. It must not slow the
    // one case that needs live updates: a contact driving on the road.
    final t = (_customEnabled && _activity != LocationActivity.inVehicle)
        ? _Thresholds(
            distanceM: _customDistanceM,
            interval: _customInterval,
            heartbeat: Duration(
              seconds: math.max(_customInterval.inSeconds * 4, 300),
            ),
          )
        : _thresholdsFor(_activity, _mode);

    if (distance >= t.distanceM || elapsed >= t.interval) {
      _record(fix, now);
      return true;
    }

    // Stationary heartbeat — even when locked still, post once every
    // heartbeat window so the "Bing - 2m ago" timestamp doesn't slowly
    // creep up to "an hour ago" on idle phones.
    if (_activity == LocationActivity.still && elapsed >= t.heartbeat) {
      _record(fix, now);
      return true;
    }

    return false;
  }

  void _record(LocationUpdate fix, DateTime at) {
    _lastPostedLocation = fix;
    _lastPostAt = at;
  }

  LocationActivity _mapActivity(String? activity) {
    switch (activity) {
      case 'still':
        return LocationActivity.still;
      case 'walking':
      case 'on_foot':
      case 'running':
      case 'on_bicycle':
        return LocationActivity.walking;
      case 'in_vehicle':
        return LocationActivity.inVehicle;
      default:
        return LocationActivity.unknown;
    }
  }

  _Thresholds _thresholdsFor(LocationActivity activity, SharingMode mode) {
    // Driving outranks every other tier: it is the one moment contacts should
    // see a person move along a road, even for users on the light tier.
    if (activity == LocationActivity.inVehicle) {
      // ~5 s in Live, 10 s otherwise: fast enough that the car visibly follows
      // the road instead of hopping between intersections.
      return mode == SharingMode.live
          ? const _Thresholds(
              distanceM: 25,
              interval: Duration(seconds: 5),
              heartbeat: Duration(minutes: 2),
            )
          : const _Thresholds(
              distanceM: 50,
              interval: Duration(seconds: 10),
              heartbeat: Duration(minutes: 3),
            );
    }

    // Light mode: state-transition pings + 15-min heartbeat. This is the
    // "I just want my friends to know roughly where I am" tier.
    if (mode == SharingMode.light) {
      return const _Thresholds(
        distanceM: 1000,
        interval: Duration(minutes: 5),
        heartbeat: Duration(minutes: 15),
      );
    }

    switch (activity) {
      case LocationActivity.walking:
        return mode == SharingMode.live
            ? const _Thresholds(
                distanceM: 25,
                interval: Duration(seconds: 30),
                heartbeat: Duration(minutes: 10),
              )
            : const _Thresholds(
                distanceM: 100,
                interval: Duration(seconds: 60),
                heartbeat: Duration(minutes: 10),
              );
      case LocationActivity.still:
        // Stationary heartbeat is mode-aware: Live keeps contacts fresh even
        // when not moving (the point of live sharing); Light sips battery.
        switch (mode) {
          case SharingMode.live:
            return const _Thresholds(
              distanceM: 999999,
              interval: Duration(minutes: 5),
              heartbeat: Duration(seconds: 45),
            );
          case SharingMode.balanced:
            return const _Thresholds(
              distanceM: 999999,
              interval: Duration(minutes: 10),
              heartbeat: Duration(minutes: 5),
            );
          case SharingMode.light:
            return const _Thresholds(
              distanceM: 999999, // effectively never on distance alone
              interval: Duration(minutes: 30),
              heartbeat: Duration(minutes: 15),
            );
        }
      case LocationActivity.unknown:
        // Before the activity classifier has weighed in. Be conservative —
        // every 60s or 100m. This is the bootup state.
        return const _Thresholds(
          distanceM: 100,
          interval: Duration(seconds: 60),
          heartbeat: Duration(minutes: 15),
        );
      case LocationActivity.inVehicle:
        // Already returned above; kept so the switch stays exhaustive.
        return const _Thresholds(
          distanceM: 50,
          interval: Duration(seconds: 10),
          heartbeat: Duration(minutes: 3),
        );
    }
  }

  // Haversine distance in meters between two lat/lng pairs.
  static double _haversineMeters(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    const earthMeters = 6371000.0;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLng = (lng2 - lng1) * math.pi / 180;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) *
            math.cos(lat2 * math.pi / 180) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthMeters * c;
  }
}

class _Thresholds {
  const _Thresholds({
    required this.distanceM,
    required this.interval,
    required this.heartbeat,
  });
  final double distanceM;
  final Duration interval;
  final Duration heartbeat;
}
