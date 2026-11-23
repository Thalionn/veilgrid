import 'package:flutter/material.dart';

import 'package:grid_frontend/services/map_preferences.dart';
import 'package:grid_frontend/styles/grid_colors.dart';

/// Map visibility and color preferences shared by the map screen.
class MapSettingsScreen extends StatefulWidget {
  const MapSettingsScreen({super.key});

  @override
  State<MapSettingsScreen> createState() => _MapSettingsScreenState();
}

class _MapSettingsScreenState extends State<MapSettingsScreen> {
  @override
  void initState() {
    super.initState();
    MapPreferences.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    MapPreferences.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final prefs = MapPreferences.instance;
    final c = context.gridColors;
    return Scaffold(
      appBar: AppBar(title: const Text('Map display')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          SwitchListTile(
            title: const Text('Show radius circles'),
            subtitle: const Text(
                'Show the circle around home and saved places. Place pins stay visible.'),
            value: prefs.showRadii,
            onChanged: prefs.setShowRadii,
          ),
          SwitchListTile(
            title: const Text('Show saved places'),
            subtitle: const Text(
                'Hide every place pin and circle without deleting the places'),
            value: prefs.showPlaces,
            onChanged: prefs.setShowPlaces,
          ),
          const Divider(height: 24),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Default place color',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: c.text)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'A place can override this in its edit sheet.',
              style: TextStyle(fontSize: 12, color: c.text3),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final color in MapPreferences.placeColors)
                  _ColorDot(
                    color: color,
                    selected: prefs.placeColor == color,
                    onTap: () => prefs.setPlaceColor(color),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final value = Color(int.parse(color.substring(1), radix: 16) | 0xFF000000);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: value,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? context.gridColors.text
                : context.gridColors.hairlineStrong,
            width: selected ? 3 : 1,
          ),
        ),
        child: selected
            ? const Icon(Icons.check, size: 18, color: Colors.white)
            : null,
      ),
    );
  }
}
