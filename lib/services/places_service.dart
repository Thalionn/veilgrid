import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grid_frontend/models/place.dart';

/// Stores the user's saved places (Life360-style) in SharedPreferences and
/// notifies listeners on change.
class PlacesService extends ChangeNotifier {
  PlacesService._();
  static final PlacesService instance = PlacesService._();

  static const _prefsKey = 'grid_places';

  List<Place> _places = [];
  List<Place> get places => List.unmodifiable(_places);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        _places = list
            .map((e) => Place.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        _places = [];
      }
    }
    notifyListeners();
  }

  Future<void> add(Place place) async {
    _places = [..._places, place];
    await _save();
  }

  Future<void> update(Place updated) async {
    final index = _places.indexWhere((p) => p.id == updated.id);
    if (index < 0) return;
    final next = List<Place>.from(_places);
    next[index] = updated;
    _places = next;
    await _save();
  }

  Future<void> remove(String id) async {
    _places = _places.where((p) => p.id != id).toList();
    await _save();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(_places.map((p) => p.toJson()).toList()),
    );
    notifyListeners();
  }
}
