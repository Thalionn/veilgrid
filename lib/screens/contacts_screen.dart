import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grid_frontend/services/avatar_store.dart';
import 'package:grid_frontend/services/contact_situation.dart';
import 'package:grid_frontend/services/invite_link.dart';
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
  bool _twoWay = false;
  String? _inviteToken;
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
    _loadInviteSettings();
    AvatarStore.instance.addListener(_onAvatarChanged);
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

  void _onAvatarChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _contactsSub.cancel();
    _locationSub?.cancel();
    PlacesService.instance.removeListener(_onPlacesChanged);
    AvatarStore.instance.removeListener(_onAvatarChanged);
    super.dispose();
  }

  Widget _contactRow(String address) {
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

  static const _twoWayPref = 'invite_two_way';
  static const _tokenPref = 'invite_token';

  Future<void> _loadInviteSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final twoWay = prefs.getBool(_twoWayPref) ?? false;
    var token = prefs.getString(_tokenPref);
    if (twoWay && (token == null || token.isEmpty)) {
      token = _newToken();
      await prefs.setString(_tokenPref, token);
    }
    await VeilidService.instance.setLinkBackToken(twoWay ? token : null);
    if (!mounted) return;
    setState(() {
      _twoWay = twoWay;
      _inviteToken = token;
    });
  }

  static String _newToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(18, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  Future<void> _setTwoWay(bool value) async {
    var token = _inviteToken;
    if (value && (token == null || token.isEmpty)) token = _newToken();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_twoWayPref, value);
    if (token != null) await prefs.setString(_tokenPref, token);
    await VeilidService.instance.setLinkBackToken(value ? token : null);
    if (!mounted) return;
    setState(() {
      _twoWay = value;
      _inviteToken = token;
    });
  }

  Future<void> _shareInvite() async {
    final address = _address;
    if (address == null) return;
    final link = buildInviteLink(
      address,
      twoWay: _twoWay,
      token: _inviteToken,
    );
    await SharePlus.instance.share(ShareParams(
      text: 'Add me on VeilGrid: $link',
      subject: 'VeilGrid invite',
    ));
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
                    ],
                  ),
                const SizedBox(height: 12),
                if (_address != null)
                  Row(
                    children: [
                      Expanded(
                        child: GridButton(
                          label: 'Copy code',
                          icon: Icons.copy_rounded,
                          style: GridButtonStyle.secondary,
                          height: 46,
                          onPressed: _copyAddress,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: GridButton(
                          label: 'Share',
                          icon: Icons.ios_share,
                          style: GridButtonStyle.primary,
                          height: 46,
                          onPressed: _shareInvite,
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Two-way link'),
                  subtitle: const Text(
                      'After they accept, they are linked back to you automatically'),
                  value: _twoWay,
                  onChanged: _setTwoWay,
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
