import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:grid_frontend/services/contact_situation.dart';
import 'package:grid_frontend/services/places_service.dart';
import 'package:grid_frontend/services/veilid_service.dart';
import 'package:grid_frontend/screens/veilid_scan_screen.dart';
import 'package:grid_frontend/widgets/grid/grid_avatar.dart';
import 'package:grid_frontend/widgets/grid/grid_button.dart';
import 'package:grid_frontend/widgets/grid/grid_contact_row.dart';
import 'package:grid_frontend/widgets/grid/grid_mono.dart';
import 'package:grid_frontend/widgets/grid/grid_status_pill.dart';
import 'package:grid_frontend/widgets/grid/grid_address_qr.dart';
import 'package:grid_frontend/widgets/contact_detail_sheet.dart';
import 'package:grid_frontend/widgets/grid/tab_active.dart';

/// Contacts tab: my shareable address (QR) plus the list of linked contacts.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  String? _address;
  late final StreamSubscription<void> _contactsSub;
  StreamSubscription<Map<String, dynamic>>? _locationSub;
  DateTime _lastLiveRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  bool _active = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = TabActive.of(context);
    if (active == _active) return;
    _active = active;
    // The list may have changed while this tab was hidden (e.g. linking from
    // the map's contact sheet).
    if (_active) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _loadAddress();
    _contactsSub = VeilidService.instance.contactsChanged.listen((_) {
      if (!_active || !mounted) return;
      setState(() {});
    });
    _locationSub = VeilidService.instance.locationUpdates.listen((_) {
      if (!_active || !mounted) return;
      // "At Work · 2h" only needs an occasional refresh, not one per fix.
      final now = DateTime.now();
      if (now.difference(_lastLiveRefresh).inSeconds < 3) return;
      _lastLiveRefresh = now;
      setState(() {});
    });
    PlacesService.instance.addListener(_onPlacesChanged);
  }

  void _onPlacesChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _contactsSub.cancel();
    _locationSub?.cancel();
    PlacesService.instance.removeListener(_onPlacesChanged);
    super.dispose();
  }

  Widget _contactRow(String address) {
    final situation = contactSituationFor(address);
    final paused = VeilidService.instance.isContactPaused(address);
    return GridContactRow(
      name: _displayName(address),
      handle: address,
      placeLine: situation?.placeLine,
      timeText: situation?.durationLabel,
      statusLabel: paused ? 'PAUSED' : 'LINKED',
      statusKind: paused ? GridStatusKind.paused : GridStatusKind.live,
      avatarStatus: GridAvatarStatus.idle,
      showDivider: true,
      onTap: () => _openContact(address),
    );
  }

  Future<void> _loadAddress() async {
    final address = await VeilidService.instance.myAddress();
    if (mounted) setState(() => _address = address);
  }

  Future<void> _openScan() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const VeilidScanScreen()),
    );
    if (mounted) setState(() {});
  }

  Future<void> _copyAddress() async {
    final address = _address;
    if (address == null) return;
    await Clipboard.setData(ClipboardData(text: address));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Address copied to clipboard')),
      );
    }
  }

  String _short(String address) {
    final parts = address.split(':');
    return parts.length >= 2 ? parts[1] : address;
  }

  String _displayName(String address) {
    return VeilidService.instance.getContactName(address) ?? _short(address);
  }

  void _openContact(String address) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ContactDetailSheet(address: address),
    ).then((_) => setState(() {}));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final contacts = VeilidService.instance.contactAddresses;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Contacts'),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: 'Add contact',
            onPressed: _openScan,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: Column(
              children: [
                if (_address != null)
                  GridAddressQr(data: _address!, size: 160)
                else
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: CircularProgressIndicator(),
                  ),
                const SizedBox(height: 12),
                Text('Scan this to add you', style: theme.textTheme.bodySmall),
                const SizedBox(height: 8),
                if (_address != null)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: GridMono(
                          _address!,
                          size: 10,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        tooltip: 'Copy address',
                        onPressed: _copyAddress,
                      ),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: GridButton(
              label: 'Add contact',
              icon: Icons.qr_code_scanner,
              style: GridButtonStyle.secondary,
              onPressed: _openScan,
            ),
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text('Contacts (${contacts.length})',
                style: theme.textTheme.titleMedium),
          ),
          const SizedBox(height: 4),
          if (contacts.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Text('No contacts yet — scan a friend\'s QR to link.',
                  style: theme.textTheme.bodySmall),
            )
          else
            for (final address in contacts) _contactRow(address),
        ],
      ),
    );
  }
}
