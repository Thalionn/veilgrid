import 'package:flutter/material.dart';

import 'package:grid_frontend/models/place.dart';
import 'package:grid_frontend/services/place_presence.dart';
import 'package:grid_frontend/services/places_service.dart';
import 'package:grid_frontend/services/units_controller.dart';
import 'package:grid_frontend/styles/grid_colors.dart';
import 'package:grid_frontend/widgets/grid/edit_place_dialog.dart';
import 'package:grid_frontend/widgets/grid/grid_sheet.dart';

/// Read-only detail sheet shown when a saved place's circle is tapped on the
/// map: its radius, who is currently inside it, and an edit action.
class PlaceInfoSheet extends StatefulWidget {
  const PlaceInfoSheet({super.key, required this.place});

  final Place place;

  @override
  State<PlaceInfoSheet> createState() => _PlaceInfoSheetState();
}

class _PlaceInfoSheetState extends State<PlaceInfoSheet> {
  late Place _place = widget.place;

  Future<void> _edit() async {
    final updated = await showEditPlaceDialog(context, _place);
    if (updated == null) return;
    await PlacesService.instance.update(updated);
    if (mounted) setState(() => _place = updated);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.gridColors;
    final here = contactsAtPlace(_place);
    final who = here.isEmpty
        ? 'Nobody is here right now'
        : here.map(contactLabel).join(', ');

    return GridSheetContainer(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GridSheetHeader(
              title: _place.name,
              subtitle:
                  'Saved place · ${formatDistance(_place.radiusMeters, rounded: true)} radius',
              onClose: () => Navigator.of(context).pop(),
              trailing: IconButton(
                icon: const Icon(Icons.edit_outlined, size: 20),
                tooltip: 'Edit place',
                onPressed: _edit,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(Icons.place_outlined, size: 18, color: c.mint),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    who,
                    style: TextStyle(
                      fontSize: 14,
                      color: here.isEmpty ? c.text3 : c.text,
                      fontWeight: here.isEmpty ? FontWeight.w400 : FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${_place.latitude.toStringAsFixed(4)}, '
              '${_place.longitude.toStringAsFixed(4)}',
              style: TextStyle(fontSize: 11, color: c.text3),
            ),
          ],
        ),
      ),
    );
  }
}
