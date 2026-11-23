import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:grid_frontend/services/location_manager.dart';
import 'package:grid_frontend/services/places_service.dart';
import 'package:grid_frontend/styles/grid_colors.dart';
import 'package:grid_frontend/services/veilid_service.dart';
import 'package:grid_frontend/utilities/time_ago_formatter.dart';
import 'package:grid_frontend/widgets/grid/grid_mono.dart';
import 'package:grid_frontend/widgets/grid/grid_sheet.dart';

/// Bottom sheet showing a contact's details and the per-contact sharing toggle.
/// Shared by the Contacts list and the map's marker tap.
class ContactDetailSheet extends StatefulWidget {
  const ContactDetailSheet({super.key, required this.address});

  final String address;

  @override
  State<ContactDetailSheet> createState() => _ContactDetailSheetState();
}

class _ContactDetailSheetState extends State<ContactDetailSheet> {
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    _paused = VeilidService.instance.isContactPaused(widget.address);
  }

  String get _short {
    final parts = widget.address.split(':');
    return parts.length >= 2 ? parts[1] : widget.address;
  }

  String get _name =>
      VeilidService.instance.getContactName(widget.address) ?? _short;

  Future<void> _editName() async {
    final controller =
        TextEditingController(text: VeilidService.instance.getContactName(widget.address) ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null) return;
    await VeilidService.instance.setContactName(widget.address, name);
    if (mounted) setState(() {});
  }

  /// "just now", "40m", "2h 15m": Life360-style elapsed time, so a long stay
  /// does not turn into a confusing "135m".
  static String _formatDwell(Duration d) {
    if (d.inMinutes < 1) return 'just now';
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    if (hours == 0) return '${minutes}m';
    return minutes == 0 ? '${hours}h' : '${hours}h ${minutes}m';
  }

  @override
  Widget build(BuildContext context) {
    final loc = VeilidService.instance.contactLocations[widget.address];
    final c = context.gridColors;
    final motion = VeilidService.instance.contactMotion(widget.address);
    String? status;
    IconData? statusIcon;
    if (motion != null) {
      if (motion['moving'] == true) {
        status = 'Driving';
        statusIcon = Icons.directions_car;
      } else {
        final since = motion['since'] as DateTime?;
        String? placeName;
        final lat = (loc?['lat'] as num?)?.toDouble();
        final lng = (loc?['lng'] as num?)?.toDouble();
        if (lat != null && lng != null) {
          for (final place in PlacesService.instance.places) {
            if (Geolocator.distanceBetween(
                    place.latitude, place.longitude, lat, lng) <=
                place.radiusMeters) {
              placeName = place.name;
              break;
            }
          }
        }
        final forText = since == null
            ? ''
            : _formatDwell(DateTime.now().difference(since));
        status = placeName != null
            ? 'At $placeName · $forText'
            : 'Stationary · $forText';
        statusIcon =
            placeName != null ? Icons.place_outlined : Icons.pause_circle_outline;
      }
    }

    String? lastSeen;
    String? distance;
    if (loc != null) {
      final ts = loc['ts'];
      lastSeen = ts is DateTime ? ts.toIso8601String() : null;
      final lat = (loc['lat'] as num?)?.toDouble();
      final lng = (loc['lng'] as num?)?.toDouble();
      final me = LocationManager.instance.currentLatLng;
      if (lat != null && lng != null && me != null) {
        final m =
            Geolocator.distanceBetween(me.latitude, me.longitude, lat, lng);
        distance = m < 1000
            ? '${m.round()} m'
            : '${(m / 1000).toStringAsFixed(1)} km';
      }
    }

    return GridSheetContainer(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GridSheetHeader(
              title: _name,
              onClose: () => Navigator.of(context).pop(),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: GridMono(widget.address,
                      size: 10,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      uppercase: false),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  tooltip: 'Edit name',
                  onPressed: _editName,
                ),
              ],
            ),
            if (status != null) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(statusIcon, size: 15, color: c.mint),
                  const SizedBox(width: 6),
                  Text(status,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: c.text2)),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                _infoTile(context, 'Last seen',
                    lastSeen == null ? '—' : TimeAgoFormatter.format(lastSeen)),
                const SizedBox(width: 16),
                _infoTile(context, 'Distance', distance ?? '—'),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Share my location'),
              subtitle: const Text(
                  'Stop or resume sharing your live location with this contact'),
              value: !_paused,
              onChanged: (v) async {
                setState(() => _paused = !v);
                await VeilidService.instance
                    .setContactPaused(widget.address, !v);
              },
            ),
            const SizedBox(height: 4),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.person_remove_outlined,
                  color: Theme.of(context).colorScheme.error),
              title: Text('Remove contact',
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error)),
              subtitle: const Text(
                  'Unlink, stop sharing, and forget their last location'),
              onTap: _confirmRemove,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRemove() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove $_name?'),
        content: const Text(
            'You will stop sharing with them and they will stop appearing on '
            'your map. Their stored location on this device is deleted. '
            'Re-linking requires their QR code again.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final nav = Navigator.of(context);
    await VeilidService.instance.removeContact(widget.address);
    nav.pop();
  }

  Widget _infoTile(BuildContext context, String label, String value) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(),
              style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 0.6,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Text(value, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}
