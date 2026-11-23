import 'dart:async';

import 'package:flutter/material.dart';
import 'package:grid_frontend/models/place.dart';
import 'package:grid_frontend/services/location_manager.dart';
import 'package:grid_frontend/services/place_alert_service.dart';
import 'package:grid_frontend/services/place_presence.dart';
import 'package:grid_frontend/services/places_service.dart';
import 'package:grid_frontend/services/veilid_service.dart';
import 'package:grid_frontend/styles/grid_colors.dart';
import 'package:grid_frontend/widgets/grid/grid_button.dart';
import 'package:grid_frontend/widgets/grid/place_search_sheet.dart';
import 'package:grid_frontend/widgets/grid/tab_active.dart';

/// "Places" tab: saved places (who's currently there) plus an activity feed of
/// movement and place arrival/departure alerts, modeled on Life360.
class PlacesScreen extends StatefulWidget {
  const PlacesScreen({super.key});

  @override
  State<PlacesScreen> createState() => _PlacesScreenState();
}

class _PlacesScreenState extends State<PlacesScreen> {
  StreamSubscription<MovementAlert>? _alertSub;
  StreamSubscription<PlaceAlert>? _placeAlertSub;
  StreamSubscription<Map<String, dynamic>>? _locSub;
  DateTime _lastLocationRebuild = DateTime.fromMillisecondsSinceEpoch(0);
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
    PlaceAlertService.instance.start();
    _alertSub = VeilidService.instance.movementAlerts.listen((_) {
      if (!_active || !mounted) return;
      setState(() {});
    });
    _placeAlertSub = PlaceAlertService.instance.alerts.listen((_) {
      if (!_active || !mounted) return;
      setState(() {});
    });
    _locSub = VeilidService.instance.locationUpdates.listen((_) {
      // Presence only needs occasional refresh; don't rebuild the whole list on
      // every incoming fix, and skip the work entirely while hidden.
      if (!_active) return;
      final now = DateTime.now();
      if (!mounted || now.difference(_lastLocationRebuild).inSeconds < 5) return;
      _lastLocationRebuild = now;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _alertSub?.cancel();
    _placeAlertSub?.cancel();
    _locSub?.cancel();
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
    final result = await showDialog<(String, double)>(
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
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text('Radius'),
                  Expanded(
                    child: Slider(
                      value: radius,
                      min: 50,
                      max: 500,
                      divisions: 9,
                      label: '${radius.round()} m',
                      onChanged: (v) => setDialogState(() => radius = v),
                    ),
                  ),
                  Text('${radius.round()} m'),
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
                  Navigator.of(context).pop((controller.text, radius)),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    final (name, r) = result;
    if (name.trim().isEmpty) return;
    await PlacesService.instance.add(Place(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.trim(),
      latitude: selection.latitude,
      longitude: selection.longitude,
      radiusMeters: r,
    ));
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
    final movement = VeilidService.instance.recentAlerts;
    final placeAlerts = PlaceAlertService.instance.recentAlerts;
    final feed = <({DateTime at, Widget tile})>[
      for (final a in movement)
        if (!_suppressedByPlace(a, placeAlerts))
          (at: a.at, tile: _alertTile(context, a)),
      for (final a in placeAlerts) (at: a.at, tile: _placeAlertTile(context, a)),
    ]..sort((a, b) => b.at.compareTo(a.at));

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
          else
            for (final p in places) _placeTile(context, p),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: GridButton(
              label: 'Add a place',
              icon: Icons.add_location_alt_outlined,
              style: GridButtonStyle.secondary,
              onPressed: _openAddPlace,
            ),
          ),
          const SizedBox(height: 16),
          _section(c, 'Activity'),
          if (feed.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Text('No activity yet.',
                  style: TextStyle(color: c.text3, fontSize: 13)),
            )
          else
            for (final item in feed.take(20)) item.tile,
        ],
      ),
    );
  }

  Widget _placeTile(BuildContext context, Place place) {
    final c = context.gridColors;
    final here = _whoIsHere(place);
    final who = here.isEmpty
        ? 'Nobody here'
        : here.map(_name).join(', ');
    return ListTile(
      leading: Icon(Icons.place_outlined, color: c.mint),
      title: Text(place.name),
      subtitle: Text('${who} · within ${place.radiusMeters.round()} m'),
      isThreeLine: false,
      trailing: IconButton(
        icon: const Icon(Icons.close, size: 18),
        tooltip: 'Remove place',
        onPressed: () => _deletePlace(place),
      ),
    );
  }

  /// A "stopped" movement alert right next to an arrival at the same place is
  /// redundant; the place alert carries more information.
  bool _suppressedByPlace(MovementAlert a, List<PlaceAlert> places) {
    if (a.moving) return false;
    return places.any((p) =>
        p.arrived &&
        p.address == a.address &&
        p.at.difference(a.at).inSeconds.abs() < 120);
  }

  Widget _placeAlertTile(BuildContext context, PlaceAlert a) {
    final c = context.gridColors;
    return ListTile(
      dense: true,
      leading: Icon(
        a.arrived ? Icons.place : Icons.directions_walk,
        color: a.arrived ? c.mint : c.text3,
        size: 20,
      ),
      title: Text(
          '${_name(a.address)} ${a.arrived ? 'arrived at' : 'left'} ${a.placeName}'),
      subtitle: Text(_timeAgo(a.at),
          style: TextStyle(fontSize: 11, color: c.text3)),
    );
  }

  Widget _alertTile(BuildContext context, MovementAlert a) {
    final c = context.gridColors;
    final ago = _timeAgo(a.at);
    return ListTile(
      dense: true,
      leading: Icon(
        a.moving ? Icons.directions_run : Icons.pause_circle_outline,
        color: a.moving ? c.mint : c.text3,
        size: 20,
      ),
      title: Text('${_name(a.address)} ${a.moving ? 'started moving' : 'stopped'}'),
      subtitle: Text(ago, style: TextStyle(fontSize: 11, color: c.text3)),
    );
  }

  String _timeAgo(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
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
