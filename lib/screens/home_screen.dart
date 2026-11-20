import 'package:flutter/material.dart';
import 'package:grid_frontend/screens/contacts_screen.dart';
import 'package:grid_frontend/screens/places_screen.dart';
import 'package:grid_frontend/screens/settings_screen.dart';
import 'package:grid_frontend/screens/veilid_map_screen.dart';
import 'package:grid_frontend/services/update_service.dart';
import 'package:grid_frontend/widgets/grid/update_sheet.dart';
import 'package:grid_frontend/widgets/grid/tab_active.dart';

/// Main app shell: Map, Contacts, Places, and Settings tabs over the P2P backend.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // Quietly look for a newer GitHub release after the first frame; if one
    // exists, offer it without blocking startup.
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkForUpdate());
  }

  Future<void> _checkForUpdate() async {
    final info = await UpdateService.instance.maybeCheck();
    if (!mounted || info == null) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text('Grid ${info.version} is available'),
        duration: const Duration(seconds: 10),
        action: SnackBarAction(
          label: 'Update',
          onPressed: () {
            if (!mounted) return;
            showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              builder: (_) => UpdateSheet(info: info),
            );
          },
        ),
      ),
    );
  }

  static const _tabs = [
    VeilidMapScreen(),
    ContactsScreen(),
    PlacesScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          for (var i = 0; i < _tabs.length; i++)
            TabActive(active: _index == i, child: _tabs[i]),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: 'Map',
          ),
          NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: 'Contacts',
          ),
          NavigationDestination(
            icon: Icon(Icons.place_outlined),
            selectedIcon: Icon(Icons.place),
            label: 'Places',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
