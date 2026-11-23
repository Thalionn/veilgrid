import 'dart:async';
import 'dart:convert';

import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:grid_frontend/models/place.dart';
import 'package:grid_frontend/services/places_service.dart';
import 'package:grid_frontend/services/veilid_service.dart';
import 'package:grid_frontend/utilities/lat_lng_validation.dart';

/// Watches incoming contact fixes and emits arrival/departure alerts for the
/// user's saved places, à la Life360.
///
/// Inside/outside state is rebuilt from the latest fixes on startup and the
/// arrival time is persisted, so an observed stay keeps its duration across
/// restarts. The first fix for each contact only seeds state, so opening the
/// app does not replay arrivals for everyone already at a place. A 40 m exit
/// slack keeps GPS jitter from producing leave/arrive pairs at the boundary.
class PlaceAlertService {
  PlaceAlertService._();
  static final PlaceAlertService instance = PlaceAlertService._();

  static const int _maxAlerts = 50;
  static const double _exitSlackMeters = 40;
  static const String _presencePrefsKey = 'place_inside_since';

  final StreamController<PlaceAlert> _controller =
      StreamController<PlaceAlert>.broadcast();

  Stream<PlaceAlert> get alerts => _controller.stream;

  final List<PlaceAlert> _recent = [];
  List<PlaceAlert> get recentAlerts => List.unmodifiable(_recent);

  final Map<String, Set<String>> _insideByAddress = {};
  final Map<String, Map<String, DateTime>> _insideSince = {};
  final Set<String> _knownAddresses = {};
  final Set<String> _trackedPlaceIds = {};

  StreamSubscription<Map<String, dynamic>>? _locationSub;
  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _loadPresence();
    PlacesService.instance.addListener(_onPlacesChanged);
    _locationSub = VeilidService.instance.locationUpdates.listen(_onFix);
    _seedExistingPlaces();
  }

  Future<void> _loadPresence() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_presencePrefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      data.forEach((address, times) {
        if (times is! Map) return;
        final parsed = <String, DateTime>{};
        times.forEach((id, iso) {
          if (id is String && iso is String) {
            final at = DateTime.tryParse(iso);
            if (at != null) parsed[id] = at;
          }
        });
        if (parsed.isNotEmpty) _insideSince[address] = parsed;
      });
    } catch (_) {
      // Corrupt: start with unknown dwell times.
    }
  }

  Future<void> _persistPresence() async {
    final data = <String, Map<String, String>>{};
    _insideSince.forEach((address, times) {
      if (times.isEmpty) return;
      data[address] = {
        for (final e in times.entries) e.key: e.value.toIso8601String(),
      };
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_presencePrefsKey, jsonEncode(data));
  }

  void stop() {
    if (!_started) return;
    _started = false;
    PlacesService.instance.removeListener(_onPlacesChanged);
    _locationSub?.cancel();
    _locationSub = null;
  }

  void _onPlacesChanged() => _seedExistingPlaces();

  /// Learns existing places without firing alerts for contacts already there,
  /// and forgets state for places the user removed.
  void _seedExistingPlaces() {
    final places = PlacesService.instance.places;
    final ids = places.map((p) => p.id).toSet();
    _trackedPlaceIds.removeWhere((id) => !ids.contains(id));
    for (final place in places) {
      if (!_trackedPlaceIds.add(place.id)) continue;
      VeilidService.instance.contactLocations.forEach((address, loc) {
        if (_isInside(place, loc, slack: 0)) {
          _insideByAddress.putIfAbsent(address, () => <String>{}).add(place.id);
        }
      });
    }
    for (final inside in _insideByAddress.values) {
      inside.removeWhere((id) => !ids.contains(id));
    }
    for (final times in _insideSince.values) {
      times.removeWhere((id, _) => !ids.contains(id));
    }
  }

  /// The saved place a contact is currently inside, plus when they arrived
  /// (null when the app started with them already there).
  ({Place place, DateTime? since})? placeFor(String address) {
    final inside = _insideByAddress[address];
    if (inside == null || inside.isEmpty) return null;
    final id = inside.first;
    Place? place;
    for (final p in PlacesService.instance.places) {
      if (p.id == id) {
        place = p;
        break;
      }
    }
    if (place == null) return null;
    return (place: place, since: _insideSince[address]?[id]);
  }

  void _onFix(Map<String, dynamic> loc) {
    final address = loc['from'];
    if (address is! String) return;
    final places = PlacesService.instance.places;
    if (places.isEmpty) return;

    // The first fix for a contact only establishes state.
    final firstObservation = _knownAddresses.add(address);
    final inside = _insideByAddress.putIfAbsent(address, () => <String>{});

    for (final place in places) {
      final wasInside = inside.contains(place.id);
      final nowInside = _isInside(
        place,
        loc,
        slack: wasInside ? _exitSlackMeters : 0,
      );
      if (nowInside == wasInside) continue;
      if (nowInside) {
        inside.add(place.id);
        if (!firstObservation) {
          _insideSince.putIfAbsent(address, () => {})[place.id] = DateTime.now();
          unawaited(_persistPresence());
        }
      } else {
        inside.remove(place.id);
        if (_insideSince[address]?.remove(place.id) != null) {
          unawaited(_persistPresence());
        }
      }
      if (firstObservation) continue;
      _emit(PlaceAlert(
        address: address,
        placeId: place.id,
        placeName: place.name,
        at: DateTime.now(),
        arrived: nowInside,
      ));
    }
  }

  bool _isInside(Place place, Map<String, dynamic> loc, {required double slack}) {
    final lat = (loc['lat'] as num?)?.toDouble();
    final lng = (loc['lng'] as num?)?.toDouble();
    if (lat == null || lng == null || !isFiniteLatLng(lat, lng)) return false;
    final meters = Geolocator.distanceBetween(
        place.latitude, place.longitude, lat, lng);
    return meters <= place.radiusMeters + slack;
  }

  void _emit(PlaceAlert alert) {
    _recent.insert(0, alert);
    if (_recent.length > _maxAlerts) _recent.removeLast();
    _controller.add(alert);
  }
}
