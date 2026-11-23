import 'dart:async';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:libre_location/libre_location.dart' as libre;
import 'package:shared_preferences/shared_preferences.dart';
import 'location/location_service.dart';
import 'location/location_update.dart';
import 'location/location_service_config.dart';
import 'location/libre_location_service.dart';
import 'location/location_dispatch.dart';
import 'sharing_state_notifier.dart';
import '../utilities/lat_lng_validation.dart';

/// A simpler location manager relying on the plugin's own stop-detection.
/// Battery Saver Mode slightly changes the config, otherwise we let
/// the plugin handle moving vs stationary. Includes a `grabLocationAndPing`
/// method for manual location fetch/ping.
class LocationManager with ChangeNotifier {
  LocationManager._();
  static final LocationManager instance = LocationManager._();

  final StreamController<LocationUpdate> _locationStreamController = StreamController.broadcast();
  final LocationService _locationService = LibreLocationService();

  LocationUpdate? _lastPosition;
  LatLng? _lastKnown;
  bool _isTracking = false;
  bool _isInForeground = true;
  bool _isMoving = false;
  DateTime? _lastLocationUpdate;

  TrackingMode _trackingMode = TrackingMode.normal;

  late final AppLifecycleListener _lifecycleListener;
  StreamSubscription<LocationUpdate>? _locationSubscription;
  StreamSubscription<bool>? _motionSubscription;
  StreamSubscription<libre.ActivityEvent>? _activitySubscription;
  LocationActivity _activity = LocationActivity.unknown;
  libre.TrackingPreset? _appliedPreset;

  // Speed fallback for driving when activity recognition is unavailable.
  bool _speedDriving = false;
  DateTime? _lastFastFixAt;

  /// Must be awaited once at boot, before [startTracking]. Hydrates the
  /// persisted sharing mode so the first config push uses the user's choice
  /// rather than the default.
  Future<void> initialize() async {
    // Hydrate the last fix first so the map can start on the user's location
    // instead of a placeholder before the tracker delivers anything.
    await _loadLastKnown();
    await _loadTrackingMode();
    _initializeLifecycleListener();
    // Pausing (incognito or the home geofence) must also relax the GPS
    // hardware, not just suppress sending.
    SharingStateNotifier.instance.addListener(_onSharingStateChanged);
    _activitySubscription =
        libre.LibreLocation.onActivityChange.listen((event) {
      _activity = _activityFrom(event.activity);
      // In a vehicle we want live movement on the map; on foot/still we go
      // back to the user's chosen tracking tier.
      _applyTrackingPreset();
    });
    _setupLocationService();
  }

  void _onSharingStateChanged() {
    _updateTrackingConfig();
    _applyTrackingPreset();
    notifyListeners();
  }

  LocationActivity _activityFrom(String? activity) => switch (activity) {
        'still' => LocationActivity.still,
        'walking' || 'on_foot' || 'running' || 'on_bicycle' =>
          LocationActivity.walking,
        'in_vehicle' => LocationActivity.inVehicle,
        _ => LocationActivity.unknown,
      };

  /// Chooses the tracker tier from pause state, the user's mode, and whether
  /// they are currently driving. Driving is the one time we spend battery for
  /// live movement, matching how Life360 shows a car moving on the road.
  Future<void> _applyTrackingPreset() async {
    if (!_isTracking) return;
    final paused = SharingStateNotifier.instance.isPaused;
    final libre.TrackingPreset preset;
    if (paused) {
      preset = libre.TrackingPreset.low;
    } else if (_activity == LocationActivity.inVehicle || _speedDriving) {
      // Driving is the one time contacts need live movement. Spend the
      // battery here so the car is actually shown on the road.
      preset = libre.TrackingPreset.high;
    } else if (_activity == LocationActivity.walking) {
      preset = _trackingMode == TrackingMode.live
          ? libre.TrackingPreset.high
          : libre.TrackingPreset.balanced;
    } else {
      // Stationary (or not yet classified): GPS at high accuracy every minute
      // is pure waste when the position is not changing. The low tier uses
      // passive fixes with a 500 m / 5 min floor; the dispatch heartbeat still
      // posts the last known position so contacts see a fresh "last seen".
      // Live sharing keeps the tighter tier because the user asked for it.
      preset = _trackingMode == TrackingMode.live
          ? libre.TrackingPreset.balanced
          : libre.TrackingPreset.low;
    }
    if (_appliedPreset == preset) return;
    _appliedPreset = preset;
    try {
      await libre.LibreLocation.setPreset(preset);
    } catch (_) {
      // Tracker may not be up yet; the next activity event retries.
      _appliedPreset = null;
    }
  }

  // Listen for app foreground/background changes
  void _initializeLifecycleListener() {
    _lifecycleListener = AppLifecycleListener(
      onStateChange: (state) {
        switch (state) {
          case AppLifecycleState.resumed:
            _isInForeground = true;
            _updateTrackingConfig();
            _applyTrackingPreset();
            break;
          case AppLifecycleState.paused:
          case AppLifecycleState.inactive:
          case AppLifecycleState.detached:
            _isInForeground = false;
            _updateTrackingConfig();
            _applyTrackingPreset();
            break;
          default:
            break;
        }
      },
    );
  }

  DateTime? _lastPersistAt;

  /// The most recent fix we know of, persisted across launches. Null until
  /// the first fix ever.
  LatLng? get lastKnownLatLng => _lastKnown ?? currentLatLng;

  Future<void> _loadLastKnown() async {
    final prefs = await SharedPreferences.getInstance();
    final lat = prefs.getDouble('last_fix_lat');
    final lng = prefs.getDouble('last_fix_lng');
    if (lat != null && lng != null && isFiniteLatLng(lat, lng)) {
      _lastKnown = LatLng(lat, lng);
    }
  }

  void _remember(LocationUpdate fix) {
    if (!isFiniteLatLng(fix.latitude, fix.longitude)) return;
    _lastKnown = LatLng(fix.latitude, fix.longitude);
    // Fire-and-forget: the next launch should open where we were. Throttled:
    // while driving there is a fix every few seconds, and rewriting the prefs
    // file each time is pointless disk I/O.
    final now = DateTime.now();
    if (_lastPersistAt != null &&
        now.difference(_lastPersistAt!) < const Duration(seconds: 30)) {
      return;
    }
    _lastPersistAt = now;
    unawaited(SharedPreferences.getInstance().then((prefs) async {
      await prefs.setDouble('last_fix_lat', fix.latitude);
      await prefs.setDouble('last_fix_lng', fix.longitude);
    }));
  }

  /// Reads the same `sharing_mode` pref that [LocationDispatch] owns and
  /// writes. Deliberately not a second pref: LocationManager and
  /// LocationDispatch both push a preset to the plugin, and when they
  /// disagreed the UI showed one mode while tracking ran another (#341).
  Future<void> _loadTrackingMode() async {
    final prefs = await SharedPreferences.getInstance();
    _trackingMode =
        SharingModePref.fromPrefValue(prefs.getString('sharing_mode'))
            .trackingMode;
  }

  /// Applies [mode] to the running tracker. Persisting it is
  /// [LocationDispatch.setMode]'s job — call that first.
  void setTrackingMode(TrackingMode mode) {
    if (_trackingMode == mode) return;
    _trackingMode = mode;
    _updateTrackingConfig();
    _applyTrackingPreset();
    notifyListeners();
  }

  /// 8 m/s (~29 km/h) is above cycling, so it reliably means a vehicle.
  /// Falls back to walking speed for two minutes before clearing, so slow
  /// traffic does not drop back to the stationary tier.
  void _updateSpeedDriving(LocationUpdate fix, DateTime now) {
    if (fix.speed >= 8.0) {
      _lastFastFixAt = now;
      if (!_speedDriving) {
        _speedDriving = true;
        _applyTrackingPreset();
      }
    } else if (_speedDriving &&
        fix.speed < 2.0 &&
        _lastFastFixAt != null &&
        now.difference(_lastFastFixAt!) >= const Duration(minutes: 2)) {
      _speedDriving = false;
      _applyTrackingPreset();
    }
  }

  // Setup location service listeners
  void _setupLocationService() {
    // Listen for location updates
    _locationSubscription = _locationService.locationStream.listen((location) {
      final now = DateTime.now();
      _updateSpeedDriving(location, now);

      // Always update our internal position to keep it fresh
      _lastPosition = location;
      _remember(location);
      
      // Smart throttling: Only skip SENDING updates if stationary and recent
      if (!_isMoving && _lastLocationUpdate != null) {
        final timeSinceLastUpdate = now.difference(_lastLocationUpdate!);

        // Reduced throttling intervals for more frequent updates
        final throttleInterval = effectiveTrackingMode == TrackingMode.batterySaver
            ? const Duration(minutes: 3) // Reduced from 5 to 3 minutes
            : const Duration(seconds: 30); // Reduced from 1 minute to 30 seconds

        if (timeSinceLastUpdate < throttleInterval) {
          debugPrint('[Location] throttled stationary update');
          return; // Skip broadcasting, but we've already updated _lastPosition
        }
      }
      
      // Broadcast the update
      _lastLocationUpdate = now;
      _locationStreamController.add(location);
      notifyListeners();
    });

    // Listen for motion changes
    _motionSubscription = _locationService.motionChangeStream.listen((isMoving) {
      debugPrint('[Location] motion: $isMoving');
      _isMoving = isMoving;
      notifyListeners();
    });
  }

  /// The tracker tier actually in use. While sharing is paused there is no
  /// reason to run high-accuracy location, so drop to the battery-saving
  /// preset; restoring sharing restores the user's chosen tier.
  TrackingMode get effectiveTrackingMode =>
      SharingStateNotifier.instance.isPaused
          ? TrackingMode.batterySaver
          : _trackingMode;

  // Apply the appropriate config based on the sharing state.
  void _updateTrackingConfig() {
    if (!_isTracking) return;

    final config = LocationServiceConfig(
      mode: effectiveTrackingMode,
      // The P2P app shares while running; a boot/headless restart would keep
      // the GPS hot without a UI to pause it.
      enableHeadless: false,
      startOnBoot: false,
    );

    _locationService.setConfig(config);
  }

  // Stream for listening to location updates in your UI
  Stream<LocationUpdate> get locationStream => _locationStreamController.stream;

  // Simple helper to get the last known LatLng
  LatLng? get currentLatLng {
    if (_lastPosition == null) return null;
    return LatLng(_lastPosition!.latitude, _lastPosition!.longitude);
  }

  /// Battery at the last fix, 0.0–1.0, for manual shares between periodic ones.
  double? get batteryLevel => _lastPosition?.batteryLevel;
  bool? get isCharging => _lastPosition?.isCharging;

  bool get isTracking => _isTracking;
  TrackingMode get trackingMode => _trackingMode;
  bool get isInForeground => _isInForeground;
  bool get isMoving => _isMoving;
  DateTime? get lastLocationUpdate => _lastLocationUpdate;
  
  // Check if location data is stale
  bool get isLocationStale {
    if (_lastLocationUpdate == null) return true;
    final age = DateTime.now().difference(_lastLocationUpdate!);
    return age > const Duration(minutes: 10);
  }
  
  // Get age of last location update
  Duration? get locationAge {
    if (_lastLocationUpdate == null) return null;
    return DateTime.now().difference(_lastLocationUpdate!);
  }

  // Start tracking. Let the plugin handle moving vs stationary automatically.
  Future<void> startTracking() async {
    if (_isTracking) return;

    debugPrint('[Location] starting tracking');

    // Request permissions
    final permissionGranted = await _locationService.requestPermission();
    if (!permissionGranted) {
      debugPrint('[Location] permission denied');
      return;
    }

    // Start the location service
    await _locationService.start();
    _isTracking = true;

    // Apply battery-saver/foreground/background config
    _updateTrackingConfig();
    _applyTrackingPreset();
    notifyListeners();
  }

  // Manually request the current location (e.g., for a "Ping" button)
  // This ALWAYS gets a fresh location, bypassing any throttling
  Future<void> grabLocationAndPing() async {
    try {
      final currentPos = await _locationService.getCurrentPosition();
      
      // Always update position and timestamp for manual requests
      _lastPosition = currentPos;
      _remember(currentPos);
      _lastLocationUpdate = DateTime.now();
      _locationStreamController.add(currentPos);
      notifyListeners();
      
      debugPrint('Manual location ping completed');
    } catch (e) {
      debugPrint('[Location] current position failed: $e');
    }
  }

  // Stop tracking and remove listeners
  Future<void> stopTracking() async {
    if (!_isTracking) return;
    await _locationService.stop();
    _isTracking = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    _locationSubscription?.cancel();
    _motionSubscription?.cancel();
    _activitySubscription?.cancel();
    if (_isTracking) {
      _locationService.stop();
      _isTracking = false;
    }
    final service = _locationService;
    if (service is LibreLocationService) {
      service.dispose();
    }
    _locationStreamController.close();
    super.dispose();
  }
}
