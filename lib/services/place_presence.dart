
import 'package:grid_frontend/utilities/geo_math.dart';
import 'package:grid_frontend/models/place.dart';
import 'package:grid_frontend/services/location_manager.dart';
import 'package:grid_frontend/services/veilid_service.dart';
import 'package:grid_frontend/utilities/lat_lng_validation.dart';

/// Contact addresses whose latest fix is inside [place]'s radius.
///
/// Shared by the Places tab and the map's place sheet so the two cannot
/// disagree about who is "at" a place.
List<String> contactsAtPlace(Place place) {
  final result = <String>[];
  VeilidService.instance.contactLocations.forEach((address, loc) {
    final lat = (loc['lat'] as num?)?.toDouble();
    final lng = (loc['lng'] as num?)?.toDouble();
    if (lat == null || lng == null || !isFiniteLatLng(lat, lng)) return;
    final meters = distanceMeters(
        place.latitude, place.longitude, lat, lng);
    if (meters <= place.radiusMeters) result.add(address);
  });
  return result;
}

/// Display name for a contact address: the local rename if set, otherwise the
/// short form of the DHT record key.
String contactLabel(String address) {
  final name = VeilidService.instance.getContactName(address);
  if (name != null && name.isNotEmpty) return name;
  final parts = address.split(':');
  return parts.length >= 2 ? parts[1] : address;
}


/// True when my own latest fix is inside [place].
bool selfAtPlace(Place place) {
  final me = LocationManager.instance.currentLatLng;
  if (me == null) return false;
  final meters = distanceMeters(
      place.latitude, place.longitude, me.latitude, me.longitude);
  return meters <= place.radiusMeters;
}
