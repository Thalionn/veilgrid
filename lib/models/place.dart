/// A saved location (Home, Work, …) with a radius, à la Life360 "Places".
class Place {
  const Place({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.radiusMeters,
    this.visible = true,
    this.color,
  });

  final String id;
  final String name;
  final double latitude;
  final double longitude;
  final double radiusMeters;
  final bool visible;
  final String? color;

  Place copyWith({
    String? name,
    double? latitude,
    double? longitude,
    double? radiusMeters,
    bool? visible,
    String? color,
  }) =>
      Place(
        id: id,
        name: name ?? this.name,
        latitude: latitude ?? this.latitude,
        longitude: longitude ?? this.longitude,
        radiusMeters: radiusMeters ?? this.radiusMeters,
        visible: visible ?? this.visible,
        color: color ?? this.color,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'latitude': latitude,
        'longitude': longitude,
        'radiusMeters': radiusMeters,
        'visible': visible,
        if (color != null) 'color': color,
      };

  factory Place.fromJson(Map<String, dynamic> j) => Place(
        id: j['id'] as String,
        name: j['name'] as String,
        latitude: (j['latitude'] as num).toDouble(),
        longitude: (j['longitude'] as num).toDouble(),
        radiusMeters: (j['radiusMeters'] as num).toDouble(),
        visible: j['visible'] as bool? ?? true,
        color: j['color'] as String?,
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


/// One entry in the Activity feed. Kept separate from transient movement
/// alerts so it can be persisted and filtered by contact or kind.
enum ActivityKind { startedMoving, stopped, arrived, left }

class ContactActivity {
  const ContactActivity({
    required this.address,
    required this.at,
    required this.kind,
    this.placeName,
  });

  final String address;
  final DateTime at;
  final ActivityKind kind;
  final String? placeName;

  Map<String, dynamic> toJson() => {
        'address': address,
        'at': at.toIso8601String(),
        'kind': kind.name,
        if (placeName != null) 'place': placeName,
      };

  factory ContactActivity.fromJson(Map<String, dynamic> j) => ContactActivity(
        address: j['address'] as String,
        at: DateTime.parse(j['at'] as String),
        kind: ActivityKind.values.firstWhere(
          (k) => k.name == j['kind'],
          orElse: () => ActivityKind.stopped,
        ),
        placeName: j['place'] as String?,
      );
}
