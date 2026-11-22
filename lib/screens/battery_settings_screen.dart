import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:grid_frontend/services/battery_guard.dart';
import 'package:grid_frontend/services/location/location_dispatch.dart';
import 'package:grid_frontend/services/map_data_saver.dart';
import 'package:grid_frontend/services/location_manager.dart';
import 'package:grid_frontend/styles/grid_colors.dart';

/// Battery & tracking submenu: choose how aggressively location is sampled,
/// override the update rate, and pause sharing when the battery gets low.
class BatterySettingsScreen extends StatefulWidget {
  const BatterySettingsScreen({super.key});

  @override
  State<BatterySettingsScreen> createState() => _BatterySettingsScreenState();
}

class _BatterySettingsScreenState extends State<BatterySettingsScreen> {
  final Battery _battery = Battery();

  SharingMode _mode = SharingMode.balanced;
  bool _custom = false;
  double _intervalSeconds = 60;
  double _distanceMeters = 100;
  int _threshold = 0;
  int? _level;

  @override
  void initState() {
    super.initState();
    MapDataSaver.instance.addListener(_onDataSaverChanged);
    MapDataSaver.instance.start();
    _load();
  }

  @override
  void dispose() {
    MapDataSaver.instance.removeListener(_onDataSaverChanged);
    super.dispose();
  }

  void _onDataSaverChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final mode = SharingModePref.fromPrefValue(prefs.getString('sharing_mode'));
    final interval = (prefs.getInt('custom_interval_seconds') ?? 60)
        .clamp(30, 600)
        .toDouble();
    final distance = (prefs.getInt('custom_distance_meters') ?? 100)
        .clamp(25, 1000)
        .toDouble();
    var level = _level;
    try {
      level = await _battery.batteryLevel;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _mode = mode;
      _custom = prefs.getBool('custom_throttle_enabled') ?? false;
      _intervalSeconds = interval;
      _distanceMeters = distance;
      _threshold = prefs.getInt(BatteryGuard.thresholdKey) ?? 0;
      _level = level;
    });
  }

  Future<void> _setMode(SharingMode mode) async {
    setState(() => _mode = mode);
    await LocationDispatch.instance?.setMode(mode);
    LocationManager.instance.setTrackingMode(mode.trackingMode);
  }

  Future<void> _saveCustom() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('custom_throttle_enabled', _custom);
    await prefs.setInt('custom_interval_seconds', _intervalSeconds.round());
    await prefs.setInt('custom_distance_meters', _distanceMeters.round());
    await LocationDispatch.instance?.reloadSettings();
  }

  Future<void> _setThreshold(int value) async {
    setState(() => _threshold = value);
    await BatteryGuard.instance.setThreshold(value);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.gridColors;
    return Scaffold(
      appBar: AppBar(title: const Text('Battery & tracking')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _sectionLabel(context, 'Tracking mode'),
          for (final mode in SharingMode.values)
            RadioListTile<SharingMode>(
              value: mode,
              groupValue: _mode,
              title: Text(_modeLabel(mode)),
              subtitle: Text(_modeHint(mode),
                  style: TextStyle(fontSize: 12, color: c.text3)),
              onChanged: (v) {
                if (v != null) _setMode(v);
              },
            ),
          const SizedBox(height: 8),

          _sectionLabel(context, 'Custom update rate'),
          SwitchListTile(
            title: const Text('Use a custom rate'),
            subtitle: const Text(
                'Override the mode above with your own interval and distance'),
            value: _custom,
            onChanged: (v) {
              setState(() => _custom = v);
              _saveCustom();
            },
          ),
          if (_custom) ...[
            ListTile(
              title: const Text('Update every'),
              subtitle: Text('${_intervalSeconds.round()} s',
                  style: TextStyle(color: c.mint)),
              dense: true,
            ),
            Slider(
              value: _intervalSeconds,
              min: 30,
              max: 600,
              divisions: 19,
              label: '${_intervalSeconds.round()} s',
              onChanged: (v) {
                setState(() => _intervalSeconds = v);
                _saveCustom();
              },
            ),
            ListTile(
              title: const Text('Minimum distance'),
              subtitle: Text('${_distanceMeters.round()} m',
                  style: TextStyle(color: c.mint)),
              dense: true,
            ),
            Slider(
              value: _distanceMeters,
              min: 25,
              max: 1000,
              divisions: 39,
              label: '${_distanceMeters.round()} m',
              onChanged: (v) {
                setState(() => _distanceMeters = v);
                _saveCustom();
              },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Sends are skipped unless this much time or distance has '
                'passed. Bigger values save battery but update more slowly.',
                style: TextStyle(fontSize: 12, color: c.text3),
              ),
            ),
            const SizedBox(height: 8),
          ],

          _sectionLabel(context, 'Map'),
          SwitchListTile(
            title: const Text('Wi-Fi only basemap'),
            subtitle: const Text(
                'Hide map tiles on mobile data; contacts, trails and places still show'),
            value: MapDataSaver.instance.enabled,
            onChanged: (v) => MapDataSaver.instance.setEnabled(v),
          ),
          if (MapDataSaver.instance.enabled)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                MapDataSaver.instance.onCellular
                    ? 'Currently on mobile data — basemap hidden.'
                    : 'Currently on Wi-Fi — basemap visible.',
                style: TextStyle(fontSize: 12, color: c.text3),
              ),
            ),

          _sectionLabel(context, 'Low battery'),
          ListTile(
            title: const Text('Pause sharing below'),
            subtitle: const Text(
                'Stops sharing and drops to battery-saving tracking until charged'),
            trailing: DropdownButton<int>(
              value: _threshold,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: 0, child: Text('Off')),
                DropdownMenuItem(value: 10, child: Text('10%')),
                DropdownMenuItem(value: 15, child: Text('15%')),
                DropdownMenuItem(value: 20, child: Text('20%')),
                DropdownMenuItem(value: 30, child: Text('30%')),
              ],
              onChanged: (v) {
                if (v != null) _setThreshold(v);
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.battery_std),
            title: const Text('Current battery'),
            subtitle: Text(_level == null ? '—' : '$_level%'),
          ),

          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'Location, screen and cellular data are what drain the battery. '
              'Battery saver drops GPS accuracy and update frequency; staying '
              'on a non-map tab while travelling also uses much less data.',
              style: TextStyle(fontSize: 12, color: c.text3),
            ),
          ),
        ],
      ),
    );
  }

  String _modeLabel(SharingMode mode) => switch (mode) {
        SharingMode.light => 'Battery saver',
        SharingMode.balanced => 'Balanced',
        SharingMode.live => 'Live',
      };

  String _modeHint(SharingMode mode) => switch (mode) {
        SharingMode.light =>
          'Roughly every 5 min / 500 m, low accuracy. Lowest battery use.',
        SharingMode.balanced =>
          'Every ~60 s / 50 m while moving, high accuracy. Default.',
        SharingMode.live =>
          'Every ~15 s / 10 m, high accuracy. Highest battery use.',
      };

  Widget _sectionLabel(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
