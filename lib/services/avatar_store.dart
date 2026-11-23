import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local avatar cache: my profile photo and the latest photo each contact has
/// sent. Stored app-privately as base64; images never touch a server.
class AvatarStore extends ChangeNotifier {
  AvatarStore._();
  static final AvatarStore instance = AvatarStore._();

  static const _myKey = 'my_avatar';
  static const _contactsKey = 'contact_avatars';
  /// Base64 grows by ~4/3 and the message also carries JSON/signature
  /// overhead, so keep the raw PNG comfortably below the app-message limit.
  static const int maxBytes = 16000;

  Uint8List? _mine;
  final Map<String, Uint8List> _contacts = {};
  bool _loaded = false;

  Uint8List? get mine => _mine;
  Uint8List? avatarFor(String address) => _contacts[address];

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final mine = prefs.getString(_myKey);
    if (mine != null && mine.isNotEmpty) {
      try {
        _mine = base64Decode(mine);
      } catch (_) {}
    }
    final raw = prefs.getString(_contactsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        map.forEach((address, value) {
          if (value is String && value.isNotEmpty) {
            try {
              _contacts[address] = base64Decode(value);
            } catch (_) {}
          }
        });
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> setMine(Uint8List? bytes) async {
    if (bytes != null && bytes.length > maxBytes) {
      throw ArgumentError('Avatar is too large');
    }
    _mine = bytes;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (bytes == null) {
      await prefs.remove(_myKey);
    } else {
      await prefs.setString(_myKey, base64Encode(bytes));
    }
  }

  Future<void> setContactAvatar(String address, Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > maxBytes) return;
    _contacts[address] = bytes;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _contactsKey,
      jsonEncode(_contacts.map((k, v) => MapEntry(k, base64Encode(v)))),
    );
  }

  Future<void> removeContactAvatar(String address) async {
    if (_contacts.remove(address) == null) return;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _contactsKey,
      jsonEncode(_contacts.map((k, v) => MapEntry(k, base64Encode(v)))),
    );
  }
}
