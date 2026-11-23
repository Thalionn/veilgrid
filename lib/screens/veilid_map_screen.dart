import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grid_frontend/models/place.dart';
import 'package:grid_frontend/screens/map/grid_map_style.dart';
import 'package:grid_frontend/screens/battery_settings_screen.dart';
import 'package:grid_frontend/screens/veilid_scan_screen.dart';
import 'package:grid_frontend/services/veilid_service.dart';
import 'package:grid_frontend/services/location_manager.dart';
import 'package:grid_frontend/services/places_service.dart';
import 'package:grid_frontend/services/map_data_saver.dart';
import 'package:grid_frontend/services/sharing_state_notifier.dart';
import 'package:grid_frontend/styles/grid_colors.dart';
import 'package:grid_frontend/utilities/lat_lng_validation.dart';
import 'package:grid_frontend/widgets/contact_detail_sheet.dart';
import 'package:grid_frontend/widgets/grid/grid_button.dart';
import 'package:grid_frontend/widgets/grid/grid_contact_row.dart';
import 'package:grid_frontend/widgets/grid/grid_sheet.dart';
import 'package:grid_frontend/widgets/grid/grid_status_pill.dart';
import 'package:grid_frontend/widgets/grid/place_info_sheet.dart';
import 'package:grid_frontend/widgets/grid/tab_active.dart';

/// A minimal P2P map: the basemap plus a marker for each contact's latest
/// received location, your own position, places, a sharing pill, and a home
/// circle. No server.
class VeilidMapScreen extends StatefulWidget {
  const VeilidMapScreen({super.key});

  @override
  State<VeilidMapScreen> createState() => _VeilidMapScreenState();
}

class _VeilidMapScreenState extends State<VeilidMapScreen> {
  MapLibreMapController? _controller;
  String? _styleJson;
  bool? _isDark;
  bool _styleLoaded = false;

  final List<Circle> _homeCircles = [];
  Circle? _meCircle;
  final Map<String, Circle> _contactCircles = {};
  final List<Circle> _placeCircles = [];
  StreamSubscription<Map<String, dynamic>>? _locSub;
  StreamSubscription<void>? _contactsSub;
  bool _centeredOnMe = false;
  bool _sending = false;

  // Coalesce marker rebuilds: one own fix and one incoming contact update can
  // arrive together, and rebuilding a marker twice per message is wasted work.
  bool _markerRefreshRunning = false;
  bool _markerRefreshQueued = false;
  bool _active = true;
  bool _dataSaverActive = false;
  bool _homeAreaReady = false;
  bool _placesAreaReady = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = TabActive.of(context);
    if (active == _active) return;
    _active = active;
    if (!_active) return;
    // Catch up: the map was frozen while another tab was visible.
    _refreshMarkers();
    _refreshPlaces();
    _refreshHome();
    if (!_centeredOnMe && LocationManager.instance.currentLatLng != null) {
      _centeredOnMe = true;
      _centerOnMe();
    }
  }

  @override
  void initState() {
    super.initState();
    _locSub = VeilidService.instance.locationUpdates.listen((_) {
      if (!_active || !mounted) return;
      _refreshMarkers();
    });
    LocationManager.instance.addListener(_onLocation);
    SharingStateNotifier.instance.addListener(_onSharingChanged);
    PlacesService.instance.addListener(_onPlacesChanged);
    MapDataSaver.instance.addListener(_onDataSaverChanged);
    MapDataSaver.instance.start();
    _contactsSub = VeilidService.instance.contactsChanged.listen((_) {
      if (!_active || !mounted) return;
      setState(() {});
      _refreshMarkers();
    });
    // The tracker's stationary interval is long (up to ~15 min), so force a
    // fresh fix on open instead of waiting for the next scheduled update.
    if (LocationManager.instance.currentLatLng == null ||
        LocationManager.instance.isLocationStale) {
      LocationManager.instance.grabLocationAndPing();
    }
  }

  @override
  void dispose() {
    LocationManager.instance.removeListener(_onLocation);
    SharingStateNotifier.instance.removeListener(_onSharingChanged);
    PlacesService.instance.removeListener(_onPlacesChanged);
    MapDataSaver.instance.removeListener(_onDataSaverChanged);
    _locSub?.cancel();
    _contactsSub?.cancel();
    super.dispose();
  }

  void _onLocation() {
    if (!mounted || !_active) return;
    _refreshMarkers();
    // Center once the first fix arrives (the camera may have started on the
    // default location before GPS delivered anything).
    if (!_centeredOnMe && LocationManager.instance.currentLatLng != null) {
      _centeredOnMe = true;
      _centerOnMe();
    }
  }

  void _onSharingChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshMarkers() async {
    // Two streams (own fixes + received fixes) can fire together; serialize so
    // neither run sees a half-updated handle map.
    if (_markerRefreshRunning) {
      _markerRefreshQueued = true;
      return;
    }
    final controller = _controller;
    if (controller == null || !_styleLoaded) return;
    _markerRefreshRunning = true;
    try {
      await _refreshMarkersNow(controller);
    } finally {
      _markerRefreshRunning = false;
      if (_markerRefreshQueued) {
        _markerRefreshQueued = false;
        // Ignore the result: this is a coalesced follow-up.
        _refreshMarkers();
      }
    }
  }

  Future<void> _refreshMarkersNow(MapLibreMapController controller) async {

    // Your position (blue). Updated in place instead of removed and re-added.
    final me = LocationManager.instance.currentLatLng;
    if (me != null) {
      final options = CircleOptions(
        geometry: LatLng(me.latitude, me.longitude),
        circleRadius: 7.0,
        circleColor: '#2563eb',
        circleOpacity: 1.0,
        circleStrokeWidth: 2.0,
        circleStrokeColor: '#ffffff',
      );
      if (_meCircle == null) {
        _meCircle = await controller.addCircle(options);
      } else {
        await controller.updateCircle(_meCircle!, options);
      }
    } else if (_meCircle != null) {
      await controller.removeCircle(_meCircle!);
      _meCircle = null;
    }

    // Contact positions (amber), tagged with their address for tap handling.
    final contacts = VeilidService.instance.contactLocations;
    final seen = <String>{};
    for (final entry in contacts.entries) {
      final loc = entry.value;
      final lat = (loc['lat'] as num?)?.toDouble();
      final lng = (loc['lng'] as num?)?.toDouble();
      if (lat == null || lng == null || !isFiniteLatLng(lat, lng)) continue;
      seen.add(entry.key);
      final options = CircleOptions(
        geometry: LatLng(lat, lng),
        circleRadius: 7.0,
        circleColor: '#f59e0b',
        circleOpacity: 1.0,
        circleStrokeWidth: 2.0,
        circleStrokeColor: '#ffffff',
      );
      final existing = _contactCircles[entry.key];
      if (existing == null) {
        _contactCircles[entry.key] =
            await controller.addCircle(options, {'address': entry.key});
      } else {
        await controller.updateCircle(existing, options);
      }
    }
    // Drop markers for contacts that were removed.
    for (final address in _contactCircles.keys.toList()) {
      if (seen.contains(address)) continue;
      await controller.removeCircle(_contactCircles.remove(address)!);
    }
  }

  /// Draw the saved home location: a GeoJSON radius polygon (MapLibre scales
  /// it natively at every zoom, so it always covers the true ground area) plus
  /// a small centre marker.
  Future<void> _refreshHome() async {
    final controller = _controller;
    if (controller == null || !_styleLoaded) return;

    if (_homeCircles.isNotEmpty) {
      await controller.removeCircles(List<Circle>.from(_homeCircles));
      _homeCircles.clear();
    }

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('home_location');
    if (raw == null || raw.isEmpty) {
      if (_homeAreaReady) {
        await controller.setGeoJsonSource('home_area', _emptyAreas());
      }
      return;
    }
    final parts = raw.split(',');
    if (parts.length != 2) return;
    final lat = double.tryParse(parts[0]);
    final lng = double.tryParse(parts[1]);
    if (lat == null || lng == null) return;
    final radiusMeters = prefs.getDouble('home_radius') ?? 150;

    final data = _areaCollection([
      _areaFeature('home', lat, lng, radiusMeters),
    ]);
    if (!_homeAreaReady) {
      await controller.addGeoJsonSource('home_area', data);
      await controller.addFillLayer(
        'home_area',
        'home_area_fill',
        FillLayerProperties(fillColor: '#22c55e', fillOpacity: 0.12),
      );
      await controller.addLineLayer(
        'home_area',
        'home_area_line',
        LineLayerProperties(
            lineColor: '#22c55e', lineWidth: 1.5, lineOpacity: 0.5),
      );
      _homeAreaReady = true;
    } else {
      await controller.setGeoJsonSource('home_area', data);
    }

    _homeCircles.add(await controller.addCircle(CircleOptions(
      geometry: LatLng(lat, lng),
      circleRadius: 6.0,
      circleColor: '#22c55e',
      circleOpacity: 1.0,
      circleStrokeWidth: 2.0,
      circleStrokeColor: '#ffffff',
    )));
  }

  void _onDataSaverChanged() {
    if (mounted) setState(() {});
  }

  void _onPlacesChanged() {
    if (!mounted || !_active) return;
    _refreshPlaces();
  }

  /// Saved places as translucent radius circles, sized from the current zoom
  /// so the circle matches the real radius rather than a fixed pixel blob.
  Future<void> _refreshPlaces() async {
    final controller = _controller;
    if (controller == null || !_styleLoaded) return;
    if (_placeCircles.isNotEmpty) {
      await controller.removeCircles(List<Circle>.of(_placeCircles));
      _placeCircles.clear();
    }

    final features = <Map<String, dynamic>>[];
    for (final place in PlacesService.instance.places) {
      if (!isFiniteLatLng(place.latitude, place.longitude)) continue;
      features.add(_areaFeature(
          place.id, place.latitude, place.longitude, place.radiusMeters));
      // Keep a tappable centre marker; the radius itself is a native layer.
      _placeCircles.add(await controller.addCircle(
        CircleOptions(
          geometry: LatLng(place.latitude, place.longitude),
          circleRadius: 6.0,
          circleColor: '#14b8a6',
          circleOpacity: 0.9,
          circleStrokeWidth: 2.0,
          circleStrokeColor: '#ffffff',
        ),
        {'placeId': place.id},
      ));
    }

    final data = _areaCollection(features);
    if (!_placesAreaReady) {
      await controller.addGeoJsonSource('places_area', data);
      await controller.addFillLayer(
        'places_area',
        'places_area_fill',
        FillLayerProperties(fillColor: '#14b8a6', fillOpacity: 0.10),
      );
      await controller.addLineLayer(
        'places_area',
        'places_area_line',
        LineLayerProperties(
            lineColor: '#14b8a6', lineWidth: 1.5, lineOpacity: 0.5),
      );
      _placesAreaReady = true;
    } else {
      await controller.setGeoJsonSource('places_area', data);
    }
  }

  Map<String, dynamic> _emptyAreas() =>
      {'type': 'FeatureCollection', 'features': <dynamic>[]};

  Map<String, dynamic> _areaCollection(List<Map<String, dynamic>> features) =>
      {'type': 'FeatureCollection', 'features': features};

  /// GeoJSON polygon approximating a ground-radius circle.
  Map<String, dynamic> _areaFeature(
      String id, double lat, double lng, double radiusMeters) {
    const earth = 6371000.0;
    const steps = 64;
    final latRad = lat * math.pi / 180;
    final ring = <List<double>>[];
    for (var i = 0; i <= steps; i++) {
      final bearing = 2 * math.pi * i / steps;
      final dLat = (radiusMeters / earth) * math.cos(bearing);
      final dLng = (radiusMeters / (earth * math.cos(latRad))) *
          math.sin(bearing);
      ring.add([lng + dLng * 180 / math.pi, lat + dLat * 180 / math.pi]);
    }
    return {
      'type': 'Feature',
      'properties': {'id': id},
      'geometry': {
        'type': 'Polygon',
        'coordinates': [ring],
      },
    };
  }

  void _openPlace(String id) {
    Place? place;
    for (final p in PlacesService.instance.places) {
      if (p.id == id) {
        place = p;
        break;
      }
    }
    final selected = place;
    if (selected == null) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => PlaceInfoSheet(place: selected),
    );
  }

  void _onCircleTapped(Circle circle) {
    final data = circle.data;
    final placeId = data?['placeId'] as String?;
    if (placeId != null) {
      _openPlace(placeId);
      return;
    }
    final address = data?['address'] as String?;
    if (address == null) return;
    _openContact(address);
  }

  void _openContact(String address) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ContactDetailSheet(address: address),
    ).then((_) => setState(() {}));
  }

  void _openContactSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _MapContactSheet(onJumpTo: _jumpToContact),
    ).then((_) => setState(() {}));
  }

  /// Center the camera on a contact's latest location.
  Future<void> _jumpToContact(String address) async {
    final controller = _controller;
    final loc = VeilidService.instance.contactLocations[address];
    if (controller == null || loc == null) return;
    final lat = (loc['lat'] as num?)?.toDouble();
    final lng = (loc['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return;
    await controller.moveCamera(CameraUpdate.newCameraPosition(
      CameraPosition(target: LatLng(lat, lng), zoom: 15),
    ));
  }

  Future<void> _sendLocation() async {
    setState(() => _sending = true);
    try {
      if (LocationManager.instance.currentLatLng == null) {
        await LocationManager.instance.grabLocationAndPing();
      }
      final pos = LocationManager.instance.currentLatLng;
      if (pos == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No location fix yet — waiting for GPS.')),
          );
        }
        return;
      }
      await VeilidService.instance.sendLocation(pos.latitude, pos.longitude);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Shared ${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)} '
              'to ${VeilidService.instance.contactAddresses.length} contact(s)',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Share failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _centerOnMe() async {
    final controller = _controller;
    final me = LocationManager.instance.currentLatLng;
    if (controller == null || me == null) return;
    await controller.moveCamera(CameraUpdate.newCameraPosition(
      CameraPosition(target: LatLng(me.latitude, me.longitude), zoom: 14),
    ));
  }

  Widget _buildSharingPill() {
    final paused = SharingStateNotifier.instance.isPaused;
    final count = VeilidService.instance.contactAddresses.length;
    final c = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: _openContactSheet,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: paused ? c.surfaceContainerHighest : c.primary,
          borderRadius: BorderRadius.circular(999),
          boxShadow: const [
            BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 2)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(paused ? Icons.pause_circle_outline : Icons.circle,
                size: 14,
                color: paused ? c.onSurfaceVariant : c.onPrimary),
            const SizedBox(width: 8),
            Text(
              paused ? 'Paused' : 'Sharing · $count contact${count == 1 ? '' : 's'}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: paused ? c.onSurfaceVariant : c.onPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dataSaver = MapDataSaver.instance.active;
    if (_isDark != isDark || _dataSaverActive != dataSaver) {
      _isDark = isDark;
      _dataSaverActive = dataSaver;
      _styleJson = buildGridMapStyle(dark: isDark, dataSaver: dataSaver);
      _styleLoaded = false;
    }

    // Start where we last were (persisted across launches). Only fall back to
    // a zoomed-out world view when there has never been a fix — anything else
    // shows a misleading arbitrary city until GPS arrives.
    final known = LocationManager.instance.lastKnownLatLng;
    final LatLng initialTarget =
        known != null ? LatLng(known.latitude, known.longitude) : const LatLng(20.0, 0.0);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Map'),
        actions: [
          IconButton(
            icon: _sending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.share_location),
            tooltip: 'Share my location',
            onPressed: _sending ? null : _sendLocation,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _centerOnMe,
        child: const Icon(Icons.my_location),
      ),
      body: Stack(
        children: [
          MapLibreMap(
            styleString: _styleJson!,
            initialCameraPosition: CameraPosition(
              target: initialTarget,
              zoom: known != null ? 15 : 1.5,
            ),
            onMapCreated: (controller) {
              _controller = controller;
              controller.onCircleTapped.add(_onCircleTapped);
            },
            onStyleLoadedCallback: () {
              if (!mounted) return;
              _styleLoaded = true;
              // A style reload invalidates every annotation handle; drop the
              // stale handles instead of trying to remove them from the new
              // style.
              _meCircle = null;
              _contactCircles.clear();
              _homeCircles.clear();
              _placeCircles.clear();
              _homeAreaReady = false;
              _placesAreaReady = false;
              _refreshMarkers();
              _refreshHome();
              _refreshPlaces();
            },
          ),
          if (_dataSaverActive)
            Positioned(
              top: 12,
              left: 16,
              right: 16,
              child: Center(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () {
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const BatterySettingsScreen(),
                      ));
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: context.gridColors.surface2,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: context.gridColors.hairline),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.data_saver_on,
                              size: 14, color: context.gridColors.mint),
                          const SizedBox(width: 6),
                          Text('Basemap off on mobile data',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: context.gridColors.text)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Center(child: _buildSharingPill()),
          ),
        ],
      ),
    );
  }
}

/// Slide-up contact sheet over the map: list + add. Tapping a contact jumps
/// the map camera to their latest location.
class _MapContactSheet extends StatefulWidget {
  const _MapContactSheet({required this.onJumpTo});

  final void Function(String address) onJumpTo;

  @override
  State<_MapContactSheet> createState() => _MapContactSheetState();
}

class _MapContactSheetState extends State<_MapContactSheet> {
  String _short(String address) {
    final parts = address.split(':');
    return parts.length >= 2 ? parts[1] : address;
  }

  String _displayName(String address) {
    return VeilidService.instance.getContactName(address) ?? _short(address);
  }

  Future<void> _openScan() async {
    Navigator.of(context).pop();
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const VeilidScanScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final contacts = VeilidService.instance.contactAddresses;
    final paused = SharingStateNotifier.instance.isPaused;
    return GridSheetContainer(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GridSheetHeader(
              title: 'Contacts',
              subtitle: paused ? 'Sharing paused' : 'Sharing live',
              onClose: () => Navigator.of(context).pop(),
            ),
            const SizedBox(height: 12),
            GridButton(
              label: 'Add contact',
              icon: Icons.qr_code_scanner,
              style: GridButtonStyle.secondary,
              onPressed: _openScan,
            ),
            const SizedBox(height: 8),
            if (contacts.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('No contacts yet — scan a friend\'s QR to link.',
                    style: Theme.of(context).textTheme.bodySmall),
              )
            else
              for (final address in contacts)
                GridContactRow(
                  name: _displayName(address),
                  handle: address,
                  statusLabel:
                      VeilidService.instance.isContactPaused(address)
                          ? 'PAUSED'
                          : 'LINKED',
                  statusKind: VeilidService.instance.isContactPaused(address)
                      ? GridStatusKind.paused
                      : GridStatusKind.live,
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.onJumpTo(address);
                  },
                ),
          ],
        ),
      ),
    );
  }
}
