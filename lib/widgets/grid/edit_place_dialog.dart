import 'package:flutter/material.dart';

import 'package:grid_frontend/models/place.dart';
import 'package:grid_frontend/services/location_manager.dart';
import 'package:grid_frontend/services/map_preferences.dart';
import 'package:grid_frontend/services/place_icons.dart';
import 'package:grid_frontend/services/units_controller.dart';
import 'package:grid_frontend/widgets/grid/place_search_sheet.dart';

/// Rename a saved place, resize its radius, or move it to the current fix.
/// Returns the edited place, or null when cancelled.
Future<Place?> showEditPlaceDialog(BuildContext context, Place place) async {
  final controller = TextEditingController(text: place.name);
  double radius = place.radiusMeters.clamp(25.0, 1000.0);
  double latitude = place.latitude;
  double longitude = place.longitude;
  bool moved = false;
  bool visible = place.visible;
  String? color = place.color;
  String? selectionNote;
  String icon = place.icon ?? 'place';

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
                const SizedBox(height: 8),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Icon'),
                ),
                const SizedBox(height: 6),
                PlaceIconPicker(
                  selected: icon,
                  onSelected: (id) => setDialogState(() => icon = id),
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
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Show on map'),
                  value: visible,
                  onChanged: (v) => setDialogState(() => visible = v),
                ),
                const SizedBox(height: 4),
                const Text('Color'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final c in MapPreferences.placeColors)
                      InkWell(
                        onTap: () => setDialogState(() => color = c),
                        borderRadius: BorderRadius.circular(18),
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: Color(
                                int.parse(c.substring(1), radix: 16) | 0xFF000000),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: (color ??
                                          MapPreferences.instance.placeColor) ==
                                      c
                                  ? Theme.of(context).colorScheme.onSurface
                                  : Colors.transparent,
                              width: 3,
                            ),
                          ),
                          child: (color ??
                                      MapPreferences.instance.placeColor) ==
                                  c
                              ? const Icon(Icons.check,
                                  size: 15, color: Colors.white)
                              : null,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                TextButton.icon(
                  onPressed: () async {
                    final selection = await showModalBottomSheet<PlaceSelection>(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.transparent,
                      builder: (_) => PlaceSearchSheet(
                        myLocation: LocationManager.instance.currentLatLng,
                        title: 'Change place location',
                      ),
                    );
                    if (selection == null) return;
                    setDialogState(() {
                      latitude = selection.latitude;
                      longitude = selection.longitude;
                      moved = false;
                      selectionNote = selection.suggestedName ??
                          '${selection.latitude.toStringAsFixed(5)}, '
                              '${selection.longitude.toStringAsFixed(5)}';
                      if (controller.text.trim().isEmpty &&
                          selection.suggestedName != null) {
                        controller.text = selection.suggestedName!;
                      }
                    });
                  },
                  icon: const Icon(Icons.search),
                  label: const Text('Search for an address'),
                ),
                if (selectionNote != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, bottom: 4),
                    child: Text(
                      selectionNote!,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                TextButton.icon(
                  onPressed: me == null
                      ? null
                      : () => setDialogState(() {
                            latitude = me.latitude;
                            longitude = me.longitude;
                            moved = true;
                            selectionNote = 'Current position';
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
                          visible: visible,
                          color: color,
                          icon: icon,
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
