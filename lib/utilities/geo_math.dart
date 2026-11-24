import 'dart:math' as math;

const double _earthRadiusMeters = 6371000.0;

/// Great-circle distance between two coordinates, in metres.
double distanceMeters(
  double lat1,
  double lng1,
  double lat2,
  double lng2,
) {
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLng = (lng2 - lng1) * math.pi / 180;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * _earthRadiusMeters * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}
