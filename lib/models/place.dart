/// A saved location (Home, Work, …) with a radius, à la Life360 "Places".
class Place {
  const Place({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.radiusMeters,
  });

  final String id;
  final String name;
  final double latitude;
  final double longitude;
  final double radiusMeters;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'latitude': latitude,
        'longitude': longitude,
        'radiusMeters': radiusMeters,
      };

  factory Place.fromJson(Map<String, dynamic> j) => Place(
        id: j['id'] as String,
        name: j['name'] as String,
        latitude: (j['latitude'] as num).toDouble(),
        longitude: (j['longitude'] as num).toDouble(),
        radiusMeters: (j['radiusMeters'] as num).toDouble(),
      );
}

/// A movement transition for a contact ("started moving" / "stopped").
class MovementAlert {
  const MovementAlert({
    required this.address,
    required this.at,
    required this.moving,
  });

  final String address;
  final DateTime at;
  final bool moving;
}


/// A contact entering or leaving a saved place.
class PlaceAlert {
  const PlaceAlert({
    required this.address,
    required this.placeId,
    required this.placeName,
    required this.at,
    required this.arrived,
  });

  final String address;
  final String placeId;
  final String placeName;
  final DateTime at;
  final bool arrived;
}
