import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hides the basemap on mobile data when the user asks for it.
///
/// Markers and the home circle are map annotations, not style layers,
/// so they keep rendering over a plain background. The setting exists because
/// a moving vector map can download hundreds of megabytes over cellular in a
/// long trip; Life360 uses roughly 30 MB for the same kind of day.
class MapDataSaver extends ChangeNotifier {
  MapDataSaver._();
  static final MapDataSaver instance = MapDataSaver._();

  static const String prefKey = 'map_wifi_only';

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _sub;

  bool _enabled = false;
  bool _onCellular = false;
  bool _started = false;

  bool get enabled => _enabled;
  bool get onCellular => _onCellular;

  /// True when the basemap should be suppressed right now.
  bool get active => _enabled && _onCellular;

  Future<void> start() async {
    if (_started) return;
    _started = true;

    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(prefKey) ?? false;
    _onCellular = _isCellular(await _connectivity.checkConnectivity());

    _sub = _connectivity.onConnectivityChanged.listen((results) {
      final cellular = _isCellular(results);
      if (cellular == _onCellular) return;
      _onCellular = cellular;
      notifyListeners();
    });

    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKey, value);
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }

  static bool _isCellular(List<ConnectivityResult> results) =>
      results.contains(ConnectivityResult.mobile) &&
      !results.contains(ConnectivityResult.wifi) &&
      !results.contains(ConnectivityResult.ethernet);
}
