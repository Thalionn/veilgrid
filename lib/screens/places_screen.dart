import 'dart:async';

import 'package:flutter/material.dart';
import 'package:grid_frontend/models/place.dart';
import 'package:grid_frontend/services/location_manager.dart';
import 'package:grid_frontend/services/place_presence.dart';
import 'package:grid_frontend/services/places_service.dart';
import 'package:grid_frontend/services/place_icons.dart';
import 'package:grid_frontend/services/units_controller.dart';
import 'package:grid_frontend/services/veilid_service.dart';
import 'package:grid_frontend/styles/grid_colors.dart';
import 'package:grid_frontend/widgets/grid/edit_place_dialog.dart';
import 'package:grid_frontend/widgets/grid/grid_button.dart';
import 'package:grid_frontend/widgets/grid/place_search_sheet.dart';
import 'package:grid_frontend/widgets/grid/tab_active.dart';

/// "Places" tab: saved places, who is currently inside, and place editing.
class PlacesScreen extends StatefulWidget {
  const PlacesScreen({super.key});

  @override
  State<PlacesScreen> createState() => _PlacesScreenState();
}

class _PlacesScreenState extends State<PlacesScreen> {
  StreamSubscription<Map<String, dynamic>>? _locationSub;
  DateTime _lastPresenceRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  bool _active = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = TabActive.of(context);
    if (active == _active) return;
    _active = active;
    // Catch up on anything that changed while this tab was hidden.
    if (_active) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    PlacesService.instance.load();
    _locationSub = VeilidService.instance.locationUpdates.listen((_) {
      if (!_active || !mounted) return;
      final now = DateTime.now();
      if (now.difference(_lastPresenceRefresh).inSeconds < 5) return;
      _lastPresenceRefresh = now;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _locationSub?.cancel();
    super.dispose();
  }

  String _name(String address) {
    final n = VeilidService.instance.getContactName(address);
    if (n != null && n.isNotEmpty) return n;
    final p = address.split(':');
    return p.length >= 2 ? p[1] : address;
  }

  /// Contact addresses currently within [place]'s radius.
  List<String> _whoIsHere(Place place) => contactsAtPlace(place);

  /// Add a place: search an address/place, or use the current position, then
  /// name it and pick a radius.
  Future<void> _openAddPlace() async {
    final selection = await showModalBottomSheet<PlaceSelection>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PlaceSearchSheet(
        myLocation: LocationManager.instance.currentLatLng,
      ),
    );
    if (selection == null || !mounted) return;
    await _confirmPlace(selection);
  }

  Future<void> _confirmPlace(PlaceSelection selection) async {
    final controller = TextEditingController(text: selection.suggestedName ?? '');
    double radius = 150;
    String icon = 'place';
    final result = await showDialog<(String, double, String)>( 
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Add place'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Home, Work, Gym…',
                ),
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
                      min: 50,
                      max: 500,
                      divisions: 9,
                      label: formatDistance(radius),
                      onChanged: (v) => setDialogState(() => radius = v),
                    ),
                  ),
                  Text(formatDistance(radius)),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop((controller.text, radius, icon)),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    final (name, r, placeIcon) = result;
    if (name.trim().isEmpty) return;
    await PlacesService.instance.add(Place(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.trim(),
      latitude: selection.latitude,
      longitude: selection.longitude,
      radiusMeters: r,
      icon: placeIcon,
    ));
    if (mounted) setState(() {});
  }

  Future<void> _editPlace(Place place) async {
    final updated = await showEditPlaceDialog(context, place);
    if (updated == null) return;
    await PlacesService.instance.update(updated);
    if (mounted) setState(() {});
  }

  Future<void> _toggleVisible(Place place) async {
    await PlacesService.instance.update(place.copyWith(visible: !place.visible));
    if (mounted) setState(() {});
  }

  Future<void> _deletePlace(Place place) async {
    await PlacesService.instance.remove(place.id);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.gridColors;
    final places = PlacesService.instance.places;

    return Scaffold(
      appBar: AppBar(title: const Text('Places')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _section(c, 'Saved places'),
          if (places.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Text('No places yet — search an address, or use your current location.',
                  style: TextStyle(color: c.text3, fontSize: 13)),
            )
          else ...[
            for (final p in places) _placeTile(context, p),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                'Tap a place to edit its name, radius or position.',
                style: TextStyle(color: c.text3, fontSize: 12),
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: GridButton(
              label: 'Add a place',
              icon: Icons.add_location_alt_outlined,
              style: GridButtonStyle.secondary,
              onPressed: _openAddPlace,
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeTile(BuildContext context, Place place) {
    final c = context.gridColors;
    final here = _whoIsHere(place);
    final labels = [if (selfAtPlace(place)) 'You', ...here.map(_name)];
    final who = labels.isEmpty ? 'Nobody here' : labels.join(', ');
    return ListTile(
      leading: Icon(
        place.visible ? placeIconFor(place.icon).icon : Icons.visibility_off_outlined,
        color: place.visible ? c.mint : c.text3,
      ),
      title: Text(place.name),
      subtitle: Text(
          '${place.visible ? '' : 'Hidden on map · '}$who · within '
          '${formatDistance(place.radiusMeters, rounded: true)}'),
      isThreeLine: false,
      onTap: () => _editPlace(place),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(
              place.visible
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              size: 20,
            ),
            tooltip: place.visible ? 'Hide on map' : 'Show on map',
            onPressed: () => _toggleVisible(place),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Remove place',
            onPressed: () => _deletePlace(place),
          ),
        ],
      ),
    );
  }

  Widget _section(GridColors c, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
      child: Text(label.toUpperCase(),
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
              color: c.mint)),
    );
  }
}
