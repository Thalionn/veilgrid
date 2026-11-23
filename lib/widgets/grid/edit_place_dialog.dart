import 'package:flutter/material.dart';

import 'package:grid_frontend/models/place.dart';
import 'package:grid_frontend/services/location_manager.dart';
import 'package:grid_frontend/services/units_controller.dart';

/// Rename a saved place, resize its radius, or move it to the current fix.
/// Returns the edited place, or null when cancelled.
Future<Place?> showEditPlaceDialog(BuildContext context, Place place) async {
  final controller = TextEditingController(text: place.name);
  double radius = place.radiusMeters.clamp(25.0, 1000.0);
  double latitude = place.latitude;
  double longitude = place.longitude;
  bool moved = false;

  final result = await showDialog<Place>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) {
        final me = LocationManager.instance.currentLatLng;
        return AlertDialog(
          title: const Text('Edit place'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    hintText: 'Home, Work, Gym…',
                  ),
                  onChanged: (_) => setDialogState(() {}),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('Radius'),
                    Expanded(
                      child: Slider(
                        value: radius,
                        min: 25,
                        max: 1000,
                        divisions: 39,
                        label: formatDistance(radius),
                        onChanged: (v) =>
                            setDialogState(() => radius = v),
                      ),
                    ),
                    Text(formatDistance(radius)),
                  ],
                ),
                TextButton.icon(
                  onPressed: me == null
                      ? null
                      : () => setDialogState(() {
                            latitude = me.latitude;
                            longitude = me.longitude;
                            moved = true;
                          }),
                  icon: Icon(moved
                      ? Icons.check_circle_outline
                      : Icons.my_location),
                  label: Text(moved
                      ? 'Moved to current position'
                      : 'Move to current position'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: controller.text.trim().isEmpty
                  ? null
                  : () => Navigator.of(dialogContext).pop(
                        place.copyWith(
                          name: controller.text.trim(),
                          latitude: latitude,
                          longitude: longitude,
                          radiusMeters: radius.roundToDouble(),
                        ),
                      ),
              child: const Text('Save'),
            ),
          ],
        );
      },
    ),
  );
  // The route's exit animation may still have the TextField attached when the
  // dialog future completes; disposing here trips ChangeNotifier's
  // "disposed with dependents" assert. Let it be collected with the route.
  return result;
}
