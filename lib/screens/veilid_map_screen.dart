import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:grid_frontend/models/place.dart';
import 'package:grid_frontend/screens/map/grid_map_style.dart';
import 'package:grid_frontend/screens/battery_settings_screen.dart';
import 'package:grid_frontend/screens/veilid_scan_screen.dart';
import 'package:grid_frontend/services/veilid_service.dart';
import 'package:grid_frontend/services/avatar_store.dart';
import 'package:grid_frontend/services/avatar_visuals.dart';
import 'package:grid_frontend/services/contact_situation.dart';
import 'package:grid_frontend/services/home_place.dart';
import 'package:grid_frontend/services/location_manager.dart';
import 'package:grid_frontend/services/map_marker_style.dart';
import 'package:grid_frontend/services/map_preferences.dart';
import 'package:grid_frontend/services/place_icons.dart';
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

  Symbol? _meSymbol;
  final Map<String, Circle> _contactCircles = {};
  final Map<String, Symbol> _contactSymbols = {};
  final Set<String> _avatarImages = {};
  final Map<String, int> _avatarWidths = {};
  final Map<String, String> _groupedAddresses = {};
  int? _clusterSignature;
  final Map<String, Symbol> _placeSymbols = {};
  final Set<String> _placeImages = {};
  Symbol? _homeSymbol;
  Place? _homePlace;
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
    AvatarStore.instance.addListener(_onAvatarChanged);
    MapPreferences.instance.addListener(_onMapPrefsChanged);
    _contactsSub = VeilidService.instance.contactsChanged.listen((_) {
      if (!_active || !mounted) return;
      setState(() {});
      _refreshMarkers();
      _refreshPlaces();
      _refreshHome();
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
    AvatarStore.instance.removeListener(_onAvatarChanged);
    MapPreferences.instance.removeListener(_onMapPrefsChanged);
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

  /// A visible saved place containing the contact, when places are shown.
  Place? _groupPlaceFor(String address, double lat, double lng) {
    Place? best;
    var bestMeters = double.infinity;
    final candidates = <Place>[
      if (_homePlace != null) _homePlace!,
      if (MapPreferences.instance.showPlaces)
        ...PlacesService.instance.places.where((p) => p.visible),
    ];
    for (final place in candidates) {
      if (!isFiniteLatLng(place.latitude, place.longitude)) continue;
      final meters = Geolocator.distanceBetween(
          place.latitude, place.longitude, lat, lng);
      if (meters <= place.radiusMeters && meters < bestMeters) {
        best = place;
        bestMeters = meters;
      }
    }
    return best;
  }

  String _contactName(String address) {
    final n = VeilidService.instance.getContactName(address);
    if (n != null && n.isNotEmpty) return n;
    final parts = address.split(':');
    return parts.length >= 2 ? parts[1] : address;
  }

  Future<void> _refreshMarkersNow(MapLibreMapController controller) async {
    final contacts = VeilidService.instance.contactLocations;
    final groupedPlaces = <String, Place>{};
    _groupedAddresses.clear();
    for (final entry in contacts.entries) {
      final loc = entry.value;
      final lat = (loc['lat'] as num?)?.toDouble();
      final lng = (loc['lng'] as num?)?.toDouble();
      if (lat == null || lng == null || !isFiniteLatLng(lat, lng)) continue;
      final place = _groupPlaceFor(entry.key, lat, lng);
      _groupedAddresses[entry.key] = place?.id ?? '';
      if (place != null) groupedPlaces[entry.key] = place;
    }

    // Your own position uses the same avatar/initials marker as contacts.
    final me = LocationManager.instance.currentLatLng;
    final mePlace =
        me == null ? null : _groupPlaceFor('__me__', me.latitude, me.longitude);
    if (mePlace != null) {
      _groupedAddresses['__me__'] = mePlace.id;
      groupedPlaces['__me__'] = mePlace;
    }
    if (me != null && mePlace == null) {
      final myName = await VeilidService.instance.myName();
      final hasName = myName != null && myName.trim().isNotEmpty;
      final label = hasName ? initialsFor(myName) : 'YOU';
      final photo = AvatarStore.instance.mine;
      final String imageId;
      var iconScale = mapMarkerIconSize;
      if (photo != null) {
        imageId = 'me_avatar_${photo.hashCode}';
        if (_avatarImages.add(imageId)) {
          await controller.addImage(imageId, photo);
        }
        final width = _avatarWidths[imageId] ??= await imagePixelWidth(photo);
        if (width > 0) iconScale = mapMarkerIconSize * 128 / width;
      } else {
        imageId = 'me_badge_${label}_${avatarColorFor(myName ?? 'You').value}';
        if (_avatarImages.add(imageId)) {
          await controller.addImage(
            imageId,
            await renderInitialsBadge(label, name: myName ?? 'You'),
          );
        }
      }
      final options = SymbolOptions(
        geometry: LatLng(me.latitude, me.longitude),
        iconImage: imageId,
        iconSize: iconScale,
        iconAnchor: 'center',
      );
      if (_meSymbol == null) {
        _meSymbol = await controller.addSymbol(options);
      } else {
        await controller.updateSymbol(_meSymbol!, options);
      }
    } else if (_meSymbol != null) {
      await controller.removeSymbol(_meSymbol!);
      _meSymbol = null;
    }

    // Contact positions, tagged with their address for tap handling.
    final seen = <String>{};
    for (final entry in contacts.entries) {
      final loc = entry.value;
      final lat = (loc['lat'] as num?)?.toDouble();
      final lng = (loc['lng'] as num?)?.toDouble();
      if (lat == null || lng == null || !isFiniteLatLng(lat, lng)) continue;
      seen.add(entry.key);
      final place = groupedPlaces[entry.key];
      if (place != null) {
        final symbol = _contactSymbols.remove(entry.key);
        if (symbol != null) await controller.removeSymbol(symbol);
        final circle = _contactCircles.remove(entry.key);
        if (circle != null) await controller.removeCircle(circle);
        continue;
      }
      final avatar = AvatarStore.instance.avatarFor(entry.key);
      final String imageId;
      var iconScale = mapMarkerIconSize;
      if (avatar != null) {
        imageId = 'avatar_${entry.key.hashCode}_${avatar.hashCode}';
        if (_avatarImages.add(imageId)) {
          await controller.addImage(imageId, avatar);
        }
        final width = _avatarWidths[imageId] ??= await imagePixelWidth(avatar);
        if (width > 0) iconScale = mapMarkerIconSize * 128 / width;
      } else {
        final name = _contactName(entry.key);
        final initials = initialsFor(name);
        imageId = 'badge_${entry.key.hashCode}_${initials}_'
            '${avatarColorFor(name).value}';
        if (_avatarImages.add(imageId)) {
          await controller.addImage(
            imageId,
            await renderInitialsBadge(initials, name: name),
          );
        }
      }
      final options = SymbolOptions(
        geometry: LatLng(lat, lng),
        iconImage: imageId,
        iconSize: iconScale,
        iconAnchor: 'center',
      );
      final existing = _contactSymbols[entry.key];
      if (existing == null) {
        _contactSymbols[entry.key] =
            await controller.addSymbol(options, {'address': entry.key});
      } else {
        await controller.updateSymbol(existing, options);
      }
      final circle = _contactCircles.remove(entry.key);
      if (circle != null) await controller.removeCircle(circle);
    }
    // Drop markers for contacts that were removed.
    for (final address in _contactCircles.keys.toList()) {
      if (seen.contains(address)) continue;
      await controller.removeCircle(_contactCircles.remove(address)!);
    }
    for (final address in _contactSymbols.keys.toList()) {
      if (seen.contains(address)) continue;
      await controller.removeSymbol(_contactSymbols.remove(address)!);
    }
    final signature = Object.hashAll([
      for (final e in _groupedAddresses.entries) '${e.key}=${e.value}',
    ]);
    if (_clusterSignature != signature) {
      _clusterSignature = signature;
      unawaited(_refreshPlaces());
      unawaited(_refreshHome());
    }
  }

  /// Draw the saved home location: a GeoJSON radius polygon (MapLibre scales
  /// it natively at every zoom, so it always covers the true ground area) plus
  /// a small centre marker.
  Future<void> _refreshHome() async {
    final controller = _controller;
    if (controller == null || !_styleLoaded) return;

    final loadedHome = await loadHomePlace();
    final homeChanged = _homePlace?.latitude != loadedHome?.latitude ||
        _homePlace?.longitude != loadedHome?.longitude ||
        _homePlace?.radiusMeters != loadedHome?.radiusMeters;
    _homePlace = loadedHome;
    if (loadedHome == null) {
      if (_homeAreaReady) {
        await controller.setGeoJsonSource('home_area', _emptyAreas());
      }
      if (_homeSymbol != null) {
        await controller.removeSymbol(_homeSymbol!);
        _homeSymbol = null;
      }
      if (homeChanged) unawaited(_refreshMarkers());
      return;
    }
    final lat = loadedHome.latitude;
    final lng = loadedHome.longitude;
    final radiusMeters = loadedHome.radiusMeters;

    final showRadii = MapPreferences.instance.showRadii;
    final data = _areaCollection(showRadii
        ? [
            _areaFeature('home', lat, lng, radiusMeters, '#22c55e'),
          ]
        : []);
    if (!_homeAreaReady && showRadii) {
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
    } else if (_homeAreaReady) {
      await controller.setGeoJsonSource('home_area', data);
    }

    final members = await _peopleAtPlace(loadedHome);
    final String imageId;
    if (members.isEmpty) {
      imageId = 'home_marker_22c55e';
      if (_placeImages.add(imageId)) {
        await controller.addImage(
          imageId,
          await renderPlaceMarker('home', const Color(0xFF22C55E)),
        );
      }
    } else {
      final memberKey =
          members.map((m) => m.photo?.hashCode ?? m.initials).join(',');
      imageId =
          'home_cluster_${members.length}_${memberKey.hashCode}';
      if (_placeImages.add(imageId)) {
        await controller.addImage(
          imageId,
          await renderPlaceCluster(
            placeIcon: Icons.home,
            color: const Color(0xFF22C55E),
            people: members,
          ),
        );
      }
    }
    final symbolOptions = SymbolOptions(
      geometry: LatLng(lat, lng),
      iconImage: imageId,
      iconSize: mapMarkerIconSize,
      iconAnchor: 'center',
    );
    if (_homeSymbol == null) {
      _homeSymbol = await controller.addSymbol(
        symbolOptions,
        {'home': true},
      );
    } else {
      await controller.updateSymbol(_homeSymbol!, symbolOptions);
    }
    if (homeChanged) unawaited(_refreshMarkers());
  }

  void _onDataSaverChanged() {
    if (mounted) setState(() {});
  }

  void _onAvatarChanged() {
    _refreshMarkers();
    _refreshPlaces();
    _refreshHome();
  }

  void _onMapPrefsChanged() {
    _refreshHome();
    _refreshPlaces();
    _refreshMarkers();
  }

  void _onPlacesChanged() {
    if (!mounted || !_active) return;
    _refreshPlaces();
    _refreshMarkers();
  }

  Future<List<ClusterAvatar>> _peopleAtPlace(Place place) async {
    final people = <ClusterAvatar>[];
    final me = LocationManager.instance.currentLatLng;
    if (me != null &&
        _groupPlaceFor('__me__', me.latitude, me.longitude)?.id == place.id) {
      final name = await VeilidService.instance.myName();
      final hasName = name != null && name.trim().isNotEmpty;
      people.add(ClusterAvatar(
        initials: hasName ? initialsFor(name) : 'YOU',
        color: avatarColorFor(name ?? 'You'),
        photo: AvatarStore.instance.mine,
      ));
    }
    for (final entry in VeilidService.instance.contactLocations.entries) {
      final loc = entry.value;
      final lat = (loc['lat'] as num?)?.toDouble();
      final lng = (loc['lng'] as num?)?.toDouble();
      if (lat == null || lng == null || !isFiniteLatLng(lat, lng)) continue;
      if (_groupPlaceFor(entry.key, lat, lng)?.id != place.id) continue;
      final name = _contactName(entry.key);
      people.add(ClusterAvatar(
        initials: initialsFor(name),
        color: avatarColorFor(name),
        photo: AvatarStore.instance.avatarFor(entry.key),
      ));
    }
    return people;
  }

  /// Saved places as translucent radius circles, sized from the current zoom
  /// so the circle matches the real radius rather than a fixed pixel blob.
  Future<void> _refreshPlaces() async {
    final controller = _controller;
    if (controller == null || !_styleLoaded) return;
    for (final symbol in _placeSymbols.values) {
      await controller.removeSymbol(symbol);
    }
    _placeSymbols.clear();

    final prefs = MapPreferences.instance;
    if (!prefs.showPlaces) {
      if (_placesAreaReady) {
        await controller.setGeoJsonSource('places_area', _emptyAreas());
      }
      return;
    }

    final features = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final place in PlacesService.instance.places) {
      if (!place.visible) continue;
      if (!isFiniteLatLng(place.latitude, place.longitude)) continue;
      seen.add(place.id);
      final color = place.color ?? prefs.placeColor;
      final iconId = place.icon ?? 'place';
      if (prefs.showRadii) {
        features.add(_areaFeature(place.id, place.latitude, place.longitude,
            place.radiusMeters, color));
      }
      final parsedColor =
          Color(int.parse(color.substring(1), radix: 16) | 0xFF000000);
      final members = await _peopleAtPlace(place);
      final String imageId;
      if (members.isEmpty) {
        imageId = 'place_${place.id}_${iconId}_$color';
        if (_placeImages.add(imageId)) {
          await controller.addImage(
            imageId,
            await renderPlaceMarker(iconId, parsedColor),
          );
        }
      } else {
        final memberKey = members
            .map((m) => m.photo?.hashCode ?? m.initials)
            .join(',');
        imageId =
            'place_cluster_${place.id}_${iconId}_${color}_${members.length}_${memberKey.hashCode}';
        if (_placeImages.add(imageId)) {
          await controller.addImage(
            imageId,
            await renderPlaceCluster(
              placeIcon: placeIconFor(iconId).icon,
              color: parsedColor,
              people: members,
            ),
          );
        }
      }
      final options = SymbolOptions(
        geometry: LatLng(place.latitude, place.longitude),
        iconImage: imageId,
        iconSize: mapMarkerIconSize,
        iconAnchor: 'center',
      );
      final existing = _placeSymbols[place.id];
      if (existing == null) {
        _placeSymbols[place.id] = await controller.addSymbol(
          options,
          {'placeId': place.id},
        );
      } else {
        await controller.updateSymbol(existing, options);
      }
    }

    final data = _areaCollection(features);
    if (!_placesAreaReady) {
      await controller.addGeoJsonSource('places_area', data);
      await controller.addFillLayer(
        'places_area',
        'places_area_fill',
        FillLayerProperties(
            fillColor: ['get', 'color'], fillOpacity: 0.10),
      );
      await controller.addLineLayer(
        'places_area',
        'places_area_line',
        LineLayerProperties(
            lineColor: ['get', 'color'], lineWidth: 1.5, lineOpacity: 0.5),
      );
      _placesAreaReady = true;
    } else {
      await controller.setGeoJsonSource('places_area', data);
    }
    for (final id in _placeSymbols.keys.toList()) {
      if (seen.contains(id)) continue;
      await controller.removeSymbol(_placeSymbols.remove(id)!);
    }
  }

  Map<String, dynamic> _emptyAreas() =>
      {'type': 'FeatureCollection', 'features': <dynamic>[]};

  Map<String, dynamic> _areaCollection(List<Map<String, dynamic>> features) =>
      {'type': 'FeatureCollection', 'features': features};

  /// GeoJSON polygon approximating a ground-radius circle.
  Map<String, dynamic> _areaFeature(
      String id, double lat, double lng, double radiusMeters,
      [String? color]) {
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
      'properties': {
        'id': id,
        if (color != null) 'color': color,
      },
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

  void _onSymbolTapped(Symbol symbol) {
    final data = symbol.data;
    if (data?['home'] == true && _homePlace != null) {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => PlaceInfoSheet(place: _homePlace!, editable: false),
      );
      return;
    }
    final placeId = data?['placeId'] as String?;
    if (placeId != null) {
      _openPlace(placeId);
      return;
    }
    final address = data?['address'] as String?;
    if (address != null) _openContact(address);
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

  Future<void> _openContact(String address) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ContactDetailSheet(address: address),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openContactSheet() async {
    final address = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _MapContactSheet(),
    );
    if (!mounted) return;
    if (address != null) {
      await _openContact(address);
    } else {
      setState(() {});
    }
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
      await VeilidService.instance.sendLocation(
        pos.latitude,
        pos.longitude,
        batteryLevel: LocationManager.instance.batteryLevel,
        isCharging: LocationManager.instance.isCharging,
      );
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
              controller.onSymbolTapped.add(_onSymbolTapped);
            },
            onStyleLoadedCallback: () {
              if (!mounted) return;
              _styleLoaded = true;
              // A style reload invalidates every annotation handle; drop the
              // stale handles instead of trying to remove them from the new
              // style.
              _meSymbol = null;
              _contactCircles.clear();
              _contactSymbols.clear();
              _placeSymbols.clear();
              _placeImages.clear();
              _avatarImages.clear();
              _homeSymbol = null;
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
  const _MapContactSheet();

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

  Widget _contactRow(BuildContext context, String address) {
    final situation = contactSituationFor(address);
    final paused = VeilidService.instance.isContactPaused(address);
    return GridContactRow(
      name: _displayName(address),
      handle: address,
      imageBytes: AvatarStore.instance.avatarFor(address),
      placeLine: situation?.placeLine,
      timeText: situation?.durationLabel,
      statusLabel: paused ? 'PAUSED' : 'LINKED',
      statusKind: paused ? GridStatusKind.paused : GridStatusKind.live,
      onTap: () => Navigator.of(context).pop(address),
    );
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
              for (final address in contacts) _contactRow(context, address),
          ],
        ),
      ),
    );
  }
}
