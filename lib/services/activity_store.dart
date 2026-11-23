import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:grid_frontend/models/place.dart';
import 'package:grid_frontend/services/place_alert_service.dart';
import 'package:grid_frontend/services/veilid_service.dart';

/// Persisted, merged feed of movement and place alerts.
///
/// Lives outside the Places screen so the Activity tab can filter it by
/// contact and kind. Only names/times are stored, never coordinates.
class ActivityStore extends ChangeNotifier {
  ActivityStore._();
  static final ActivityStore instance = ActivityStore._();

  static const _prefsKey = 'contact_activity';
  static const int _maxEvents = 100;

  final List<ContactActivity> _events = [];
  List<ContactActivity> get events => List.unmodifiable(_events);

  StreamSubscription<MovementAlert>? _movementSub;
  StreamSubscription<PlaceAlert>? _placeSub;
  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _load();
    _movementSub = VeilidService.instance.movementAlerts.listen((a) {
      _add(ContactActivity(
        address: a.address,
        at: a.at,
        kind: a.moving ? ActivityKind.startedMoving : ActivityKind.stopped,
      ));
    });
    _placeSub = PlaceAlertService.instance.alerts.listen((a) {
      _add(ContactActivity(
        address: a.address,
        at: a.at,
        kind: a.arrived ? ActivityKind.arrived : ActivityKind.left,
        placeName: a.placeName,
      ));
    });
  }

  void stop() {
    _started = false;
    _movementSub?.cancel();
    _movementSub = null;
    _placeSub?.cancel();
    _placeSub = null;
  }

  void _add(ContactActivity event) {
    // The movement detector and place detector both fire when someone
    // arrives; keep the more informative "arrived at Work".
    if (event.kind == ActivityKind.arrived) {
      _events.removeWhere((e) =>
          e.kind == ActivityKind.stopped &&
          e.address == event.address &&
          e.at.difference(event.at).inSeconds.abs() < 120);
    }
    _events.insert(0, event);
    if (_events.length > _maxEvents) _events.removeRange(_maxEvents, _events.length);
    notifyListeners();
    unawaited(_persist());
  }

  Future<void> clear() async {
    _events.clear();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw) as List;
      _events
        ..clear()
        ..addAll(list
            .map((e) => ContactActivity.fromJson(e as Map<String, dynamic>))
            .where((e) => e.at.isBefore(DateTime.now().add(
                  const Duration(minutes: 5),
                ))));
      _events.sort((a, b) => b.at.compareTo(a.at));
      notifyListeners();
    } catch (_) {
      // Corrupt or from an incompatible build: start empty.
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(_events.map((e) => e.toJson()).toList()),
    );
  }
}
