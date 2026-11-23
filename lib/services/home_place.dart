import 'package:shared_preferences/shared_preferences.dart';

import 'package:grid_frontend/models/place.dart';

/// The Settings → Home location as a synthetic Place, so map grouping and
/// presence can treat it like any other spot without adding it to Places.
Future<Place?> loadHomePlace() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('home_location');
  if (raw == null || raw.isEmpty) return null;
  final parts = raw.split(',');
  if (parts.length != 2) return null;
  final lat = double.tryParse(parts[0]);
  final lng = double.tryParse(parts[1]);
  if (lat == null || lng == null) return null;
  return Place(
    id: '__home__',
    name: 'Home',
    latitude: lat,
    longitude: lng,
    radiusMeters: (prefs.get('home_radius') as num?)?.toDouble() ?? 150,
    icon: 'home',
    color: '#22c55e',
  );
}
