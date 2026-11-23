import 'package:grid_frontend/services/place_alert_service.dart';
import 'package:grid_frontend/services/veilid_service.dart';

/// Human-friendly "just now", "40m", "2h 15m".
String formatDwell(Duration d) {
  if (d.inMinutes < 1) return 'just now';
  final hours = d.inHours;
  final minutes = d.inMinutes % 60;
  if (hours == 0) return '${minutes}m';
  return minutes == 0 ? '${hours}h' : '${hours}h ${minutes}m';
}

/// A contact's current state for list rows and the detail sheet: driving,
/// which saved place they are inside, and how long they have been there.
class ContactSituation {
  const ContactSituation({
    required this.moving,
    this.placeName,
    this.since,
  });

  final bool moving;
  final String? placeName;
  final DateTime? since;

  bool get atPlace => !moving && placeName != null;

  String get placeLine {
    if (moving) return 'Driving';
    if (placeName != null) return 'At $placeName';
    return 'Stationary';
  }

  String? get durationLabel {
    if (moving || since == null) return null;
    return formatDwell(DateTime.now().difference(since!));
  }

  String get fullLabel {
    final d = durationLabel;
    return d == null ? placeLine : '$placeLine · $d';
  }
}

/// Null until the contact has sent at least one fix.
ContactSituation? contactSituationFor(String address) {
  final motion = VeilidService.instance.contactMotion(address);
  if (motion == null) return null;
  final moving = motion['moving'] == true;
  final presence = PlaceAlertService.instance.placeFor(address);
  if (moving) {
    return ContactSituation(moving: true, placeName: presence?.place.name);
  }
  return ContactSituation(
    moving: false,
    placeName: presence?.place.name,
    // A place arrival is more precise than "stopped moving"; fall back to the
    // motion clock when the contact was already inside when the app started.
    since: presence?.since ?? motion['since'] as DateTime?,
  );
}
