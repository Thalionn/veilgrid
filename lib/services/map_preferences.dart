import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Map display choices that do not belong to a single place.
class MapPreferences extends ChangeNotifier {
  MapPreferences._();
  static final MapPreferences instance = MapPreferences._();

  static const _radiiKey = 'map_show_radii';
  static const _placesKey = 'map_show_places';
  static const _colorKey = 'map_place_color';

  static const List<String> placeColors = [
    '#14b8a6', // teal (default)
    '#3b82f6', // blue
    '#8b5cf6', // purple
    '#f59e0b', // amber
    '#ec4899', // pink
    '#22c55e', // green
  ];

  bool _showRadii = true;
  bool _showPlaces = true;
  String _placeColor = placeColors.first;

  bool get showRadii => _showRadii;
  bool get showPlaces => _showPlaces;
  String get placeColor => _placeColor;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _showRadii = prefs.getBool(_radiiKey) ?? true;
    _showPlaces = prefs.getBool(_placesKey) ?? true;
    final color = prefs.getString(_colorKey);
    if (color != null && placeColors.contains(color)) _placeColor = color;
    notifyListeners();
  }

  Future<void> setShowRadii(bool value) async {
    if (_showRadii == value) return;
    _showRadii = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_radiiKey, value);
  }

  Future<void> setShowPlaces(bool value) async {
    if (_showPlaces == value) return;
    _showPlaces = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_placesKey, value);
  }

  Future<void> setPlaceColor(String color) async {
    if (_placeColor == color) return;
    _placeColor = color;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_colorKey, color);
  }
}
