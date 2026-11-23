import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grid_frontend/services/avatar_store.dart';
import 'package:grid_frontend/services/location/home_geofence_service.dart';
import 'package:grid_frontend/screens/battery_settings_screen.dart';
import 'package:grid_frontend/screens/map_settings_screen.dart';
import 'package:grid_frontend/services/location_manager.dart';
import 'package:grid_frontend/services/sharing_state_notifier.dart';
import 'package:grid_frontend/services/theme_controller.dart';
import 'package:grid_frontend/services/units_controller.dart';
import 'package:grid_frontend/services/update_service.dart';
import 'package:grid_frontend/services/veilid_service.dart';
import 'package:grid_frontend/widgets/grid/grid_avatar.dart';
import 'package:grid_frontend/widgets/grid/grid_mono.dart';
import 'package:grid_frontend/widgets/grid/update_sheet.dart';

/// Settings tab: sharing, units, appearance, home location, notifications, and
/// app info — the pieces of the original settings that still apply to the
/// P2P app (no account/Matrix).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String? _homeLocation; // "lat,lng"
  double _homeRadius = 25;
  bool _autoPauseAtHome = false;
  bool _notifications = true;
  String? _displayName;
  String _versionLabel = '';
  bool _checkingUpdate = false;

  @override
  void initState() {
    super.initState();
    _loadHome();
    _loadName();
    _loadVersion();
    SharingStateNotifier.instance.addListener(_onChanged);
    UnitsController.instance.addListener(_onChanged);
    ThemeController.instance.addListener(_onChanged);
    AvatarStore.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    SharingStateNotifier.instance.removeListener(_onChanged);
    UnitsController.instance.removeListener(_onChanged);
    ThemeController.instance.removeListener(_onChanged);
    AvatarStore.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadHome() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _homeLocation = prefs.getString('home_location');
      _homeRadius = ((prefs.get('home_radius') as num?)?.toDouble() ?? 150).clamp(50.0, 1000.0);
      _autoPauseAtHome = prefs.getBool('auto_pause_at_home_enabled') ?? false;
      _notifications = prefs.getBool('notifications_enabled') ?? true;
    });
  }

  Future<void> _setHomeToCurrent() async {
    final me = LocationManager.instance.currentLatLng;
    if (me == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No location fix yet — move a little and retry.')),
        );
      }
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'home_location', '${me.latitude},${me.longitude}');
    await prefs.setDouble('home_radius', _homeRadius);
    await _loadHome();
    await HomeGeofenceService.instance.syncFromPrefs();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Home location set to your current position')),
      );
    }
  }

  Future<void> _clearHome() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('home_location');
    await prefs.remove('home_radius');
    await _loadHome();
    await HomeGeofenceService.instance.syncFromPrefs();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Home location cleared')),
      );
    }
  }

  Future<void> _setPref(String key, Object? value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is bool) await prefs.setBool(key, value);
    if (value is double) await prefs.setDouble(key, value);
  }

  Future<void> _loadName() async {
    final name = await VeilidService.instance.myName();
    if (mounted) setState(() => _displayName = name);
  }

  Future<void> _editName() async {
    final controller = TextEditingController(text: _displayName ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Display name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(
            hintText: 'Your name',
            labelText: 'Display name',
          ),
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
    await VeilidService.instance.setMyName(name);
    await _loadName();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(name.trim().isEmpty
            ? 'Display name cleared'
            : 'Display name set to "$name"')),
      );
    }
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() => _versionLabel = '${info.version} (${info.buildNumber})');
    }
  }

  Future<void> _checkForUpdates() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    try {
      final info = await UpdateService.instance.checkForUpdate();
      if (!mounted) return;
      setState(() => _checkingUpdate = false);
      if (info == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('You are running the latest version.')),
        );
      } else {
        await showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (_) => UpdateSheet(info: info),
        );
      }
    } on UpdateException catch (e) {
      if (!mounted) return;
      setState(() => _checkingUpdate = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      setState(() => _checkingUpdate = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not check for updates.')),
      );
    }
  }

  /// Revoke the current rendezvous address and mint a new one. Contacts hold
  /// the old address, so this deliberately breaks their ability to reach us
  /// until they scan the new QR.
  Future<void> _rotateAddress() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Create a new address?'),
        content: const Text(
            'Your current address stops working immediately. Anyone who has '
            'your old QR code can no longer find you, and your contacts must '
            'scan your new code to reconnect.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Create new address'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      final address = await VeilidService.instance.rotateAddress();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('New address ready'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Share your new QR code from the Contacts tab.'),
              const SizedBox(height: 12),
              GridMono(address, size: 10, uppercase: false, maxLines: 3),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not create a new address: $e')),
      );
    }
  }

  Future<void> _pickAvatar() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 90,
      );
      if (picked == null) return;
      final png = _circularAvatar(await picked.readAsBytes());
      await AvatarStore.instance.setMine(png);
      await VeilidService.instance.sendProfile();
      messenger.showSnackBar(
        const SnackBar(content: Text('Profile photo updated')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not use that photo: $e')),
      );
    }
  }

  Future<void> _removeAvatar() async {
    await AvatarStore.instance.setMine(null);
    await VeilidService.instance.sendProfile();
  }

  /// Crop to a square, mask to a circle, and encode small enough to fit a
  /// Veilid app message. PNG keeps the transparent corners for map symbols.
  static Uint8List _circularAvatar(Uint8List input) {
    final decoded = img.bakeOrientation(img.decodeImage(input)!);
    for (final size in [128, 112, 96, 80]) {
      final square = img.copyResizeCropSquare(decoded, size: size);
      final out = img.Image(width: size, height: size, numChannels: 4);
      final r = (size - 1) / 2;
      final c = r;
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          final dx = x - c;
          final dy = y - c;
          final d2 = dx * dx + dy * dy;
          if (d2 <= r * r) {
            if (d2 >= (r - 2.5) * (r - 2.5)) {
              out.setPixelRgba(x, y, 255, 255, 255, 255);
            } else {
              out.setPixel(x, y, square.getPixel(x, y));
            }
          } else {
            out.setPixelRgba(x, y, 0, 0, 0, 0);
          }
        }
      }
      final png = img.encodePng(out, level: 9);
      if (png.length <= AvatarStore.maxBytes) return png;
    }
    throw StateError('photo is too detailed to compress');
  }

  @override
  Widget build(BuildContext context) {
    final incognito = SharingStateNotifier.instance.userIncognito;
    final system = UnitsController.instance.system;
    final themeMode = ThemeController.instance.mode;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _sectionLabel(context, 'Profile'),
          ListTile(
            leading: GridAvatar(
              name: _displayName ?? 'You',
              size: 40,
              imageBytes: AvatarStore.instance.mine,
            ),
            title: Text(_displayName ?? 'No name set'),
            subtitle: const Text('Shown to your contacts'),
            trailing: const Icon(Icons.edit_outlined, size: 20),
            onTap: _editName,
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Profile photo'),
            subtitle: Text(AvatarStore.instance.mine == null
                ? 'Choose a picture to show on your contacts\' maps'
                : 'Shown on your contacts\' maps'),
            trailing: AvatarStore.instance.mine == null
                ? const Icon(Icons.add_photo_alternate_outlined, size: 20)
                : IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    tooltip: 'Remove photo',
                    onPressed: _removeAvatar,
                  ),
            onTap: _pickAvatar,
          ),

          const SizedBox(height: 12),
          _sectionLabel(context, 'Sharing'),
          SwitchListTile(
            title: const Text('Pause location sharing'),
            subtitle: const Text('Go incognito — stop sharing your live location'),
            value: incognito,
            onChanged: (v) => SharingStateNotifier.instance.setUserIncognito(v),
          ),

          const SizedBox(height: 12),
          _sectionLabel(context, 'Battery'),
          ListTile(
            leading: const Icon(Icons.battery_saver_outlined),
            title: const Text('Battery & tracking'),
            subtitle: const Text(
                'Update rate, battery saver mode, low-battery pause'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const BatterySettingsScreen(),
              ));
            },
          ),

          const SizedBox(height: 12),
          _sectionLabel(context, 'Map'),
          ListTile(
            leading: const Icon(Icons.layers_outlined),
            title: const Text('Map display'),
            subtitle: const Text(
                'Radius circles, saved places and place colors'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const MapSettingsScreen()),
            ),
          ),

          const SizedBox(height: 12),
          _sectionLabel(context, 'Security'),
          if (VeilidService.instance.identityStoreInsecure)
            ListTile(
              leading: Icon(Icons.warning_amber_rounded,
                  color: Theme.of(context).colorScheme.error),
              title: const Text('Identity key is not hardware-protected'),
              subtitle: const Text(
                  'This device could not use its secure keystore, so the key '
                  'is stored on disk. Avoid untrusted backups.'),
            ),
          ListTile(
            leading: const Icon(Icons.autorenew),
            title: const Text('New address'),
            subtitle: const Text(
                'Revoke your current address; contacts must re-link with your new QR'),
            onTap: _rotateAddress,
          ),

          const SizedBox(height: 12),
          _sectionLabel(context, 'Home'),
          ListTile(
            title: const Text('Home location'),
            subtitle: _homeLocation == null
                ? const Text('Not set')
                : GridMono(_homeLocation!, size: 10, uppercase: false),
            leading: const Icon(Icons.home_outlined),
          ),
          ListTile(
            title: const Text('Set home to current position'),
            leading: const Icon(Icons.my_location),
            onTap: _setHomeToCurrent,
          ),
          ListTile(
            leading: const Icon(Icons.radar),
            title: const Text('Home radius'),
            subtitle: Text(
                '${formatDistance(_homeRadius)} — pause sharing within this distance'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Slider(
              value: _homeRadius.clamp(50.0, 1000.0),
              min: 50,
              max: 1000,
              divisions: 19,
              label: formatDistance(_homeRadius),
              onChanged: (v) => setState(() => _homeRadius = v),
              onChangeEnd: (v) {
                _setPref('home_radius', v);
                HomeGeofenceService.instance.syncFromPrefs();
              },
            ),
          ),
          ListTile(
            title: const Text('Clear home location'),
            leading: const Icon(Icons.close),
            enabled: _homeLocation != null,
            onTap: _clearHome,
          ),
          SwitchListTile(
            title: const Text('Auto-pause at home'),
            subtitle: const Text('Pause sharing automatically when you arrive home'),
            value: _autoPauseAtHome,
            onChanged: (v) {
              setState(() => _autoPauseAtHome = v);
              _setPref('auto_pause_at_home_enabled', v);
              HomeGeofenceService.instance.syncFromPrefs();
            },
          ),

          const SizedBox(height: 12),
          _sectionLabel(context, 'Notifications'),
          SwitchListTile(
            title: const Text('Location update notifications'),
            subtitle: const Text('Notify when a contact shares a new location'),
            value: _notifications,
            onChanged: (v) {
              setState(() => _notifications = v);
              _setPref('notifications_enabled', v);
            },
          ),

          const SizedBox(height: 12),
          _sectionLabel(context, 'Units'),
          ListTile(
            title: const Text('Units'),
            subtitle: Text(
                'Distances in ${system.label.toLowerCase()} (${system.detail})'),
            trailing: DropdownButton<MeasurementSystem>(
              value: system,
              underline: const SizedBox.shrink(),
              items: MeasurementSystem.values
                  .map((u) => DropdownMenuItem(value: u, child: Text(u.label)))
                  .toList(),
              onChanged: (u) {
                if (u != null) UnitsController.instance.setSystem(u);
              },
            ),
          ),

          const SizedBox(height: 12),
          _sectionLabel(context, 'Appearance'),
          ListTile(
            title: const Text('Theme'),
            subtitle: Text(_themeLabel(themeMode)),
            trailing: DropdownButton<ThemeMode>(
              value: themeMode,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
                DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
                DropdownMenuItem(value: ThemeMode.system, child: Text('System')),
              ],
              onChanged: (m) {
                if (m != null) ThemeController.instance.setMode(m);
              },
            ),
          ),

          const SizedBox(height: 24),
          _sectionLabel(context, 'About'),
          const ListTile(
            title: Text('VeilGrid'),
            subtitle: Text('Peer-to-peer location sharing over Veilid'),
          ),
          ListTile(
            leading: const Icon(Icons.system_update_outlined),
            title: const Text('Check for updates'),
            subtitle: Text(_versionLabel.isEmpty
                ? 'Installed from GitHub Releases'
                : 'Version $_versionLabel'),
            trailing: _checkingUpdate
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right),
            onTap: _checkingUpdate ? null : _checkForUpdates,
          ),
          const ListTile(
            title: Text('Your address'),
            subtitle: GridMono('View it in the Contacts tab', size: 10, uppercase: false),
            enabled: false,
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
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

  String _themeLabel(ThemeMode m) => switch (m) {
        ThemeMode.dark => 'Dark',
        ThemeMode.light => 'Light',
        ThemeMode.system => 'System',
      };
}
