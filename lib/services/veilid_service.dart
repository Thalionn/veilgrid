import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veilid/veilid.dart';
import 'package:grid_frontend/utilities/geo_math.dart';
import 'package:grid_frontend/models/place.dart';
import 'package:grid_frontend/utilities/lat_lng_validation.dart';
import 'avatar_store.dart';
import 'diagnostics_log.dart';

/// Veilid integration for the P2P app.
///
/// A user's stable address is a DHT record key (owned by a local keypair).
/// Private routes are ephemeral, so each node publishes its *current* route
/// blob to that record (the "rendezvous" pattern): a contact looks up the
/// address's record to find the live route. Location is shared over those
/// routes via JSON app messages.
class VeilidService {
  VeilidService._();
  static final VeilidService instance = VeilidService._();

  bool _started = false;

  /// Secret embedded in the current two-way invite link. A link-back request
  /// is accepted only while it matches.
  String? _linkBackToken;
  bool _linkTokenLoaded = false;
  static const String _linkTokenPref = 'link_back_token';
  bool _identityStoreInsecure = false;
  KeyPair? _keyPair;
  RecordKey? _myRecordKey;
  VeilidRoutingContext? _routingContext;

  // Stable contact addresses (DHT record key strings), persisted. The live
  // route for each contact is looked up from their DHT record on demand.
  final List<String> _contactAddresses = [];
  final Map<String, RouteId> _contactRoutes = {}; // address -> imported route
  final Map<String, DateTime> _contactRouteResolvedAt = {};

  // Pinned identity public keys (address -> key string), learned from the
  // DHT record owner. Only the record owner can publish a route blob, so the
  // owner key is the contact's authenticated identity. Persisted.
  final Map<String, String> _contactPublicKeys = {};
  final Map<String, DateTime> _keyLookupAttemptedAt = {};

  // Anti-replay / anti-flood: recently seen message nonces (insertion order)
  // and the time we last accepted anything from each sender.
  final Set<String> _seenNonces = <String>{};
  final Map<String, DateTime> _lastAcceptedAt = {};
  int _rejectedMessages = 0;
  DateTime _lastRejectLog = DateTime.fromMillisecondsSinceEpoch(0);

  // Serializes message handling so signature verification (which can await a
  // DHT lookup) cannot reorder fixes or interleave mutable state updates.
  Future<void> _inbox = Future.value();

  final Random _random = Random.secure();

  // Addresses the user has paused (per-contact sharing off), persisted.
  final Set<String> _pausedAddresses = {};

  static const _contactsPrefKey = 'veilid_contacts';
  static const _pausedPrefKey = 'veilid_paused_contacts';
  static const _myRecordKeyPrefKey = 'veilid_my_record_key';
  static const _myRecordOwnerPrefKey = 'veilid_my_record_owner';
  static const _myNamePrefKey = 'veilid_display_name';
  static const _contactNamesPrefKey = 'veilid_contact_names';
  static const _contactNicknamesPrefKey = 'veilid_contact_nicknames';
  static const _nicknamesMigratedPrefKey = 'veilid_contact_nicknames_migrated';
  static const _contactKeysPrefKey = 'veilid_contact_public_keys';
  static const _contactLocationsPrefKey = 'veilid_contact_locations';
  static const _pendingLinkInviterPrefKey = 'pending_link_inviter';
  static const _pendingLinkTokenPrefKey = 'pending_link_token';
  static const _pendingLinkSincePrefKey = 'pending_link_since';
  // User-secret key (Veilid protected store) for the identity keypair.
  static const _myKeyPairSecretKey = 'grid_identity_keypair';

  // My display name (published to my DHT record) and the local names I've
  // assigned to contacts (address -> name).
  String? _myName;
  final Map<String, String> _contactNames = {};
  final Set<String> _contactNicknames = {};
  bool _refreshingNames = false;
  bool _nicknamesMigrated = false;

  // Two-way link handshake retry state. The invite is only considered done
  // once the inviter answers with a signed profile.
  String? _pendingLinkInviter;
  String? _pendingLinkToken;
  DateTime? _pendingLinkSince;
  Timer? _linkRetryTimer;
  int _linkAttempts = 0;
  DateTime _lastLocationPersist = DateTime.fromMillisecondsSinceEpoch(0);
  final Set<String> _loggedLocationFrom = <String>{};


  // My current route id, so a RouteChange update can tell when it died.
  String? _myRouteId;
  bool _republishing = false;

  // Latest location per contact, keyed by the receiving route id (the route
  // this node created and shared). In-memory for the spike.
  final Map<String, Map<String, dynamic>> _contactLocations = {};

  // Movement tracking: last known moving state per contact address, and the
  // recent "started moving / stopped" alerts (in-memory, newest first).
  final Map<String, bool> _contactMoving = {};
  final Map<String, int> _contactMovingStreak = {};
  final Map<String, DateTime> _contactMovingSince = {};
  final List<MovementAlert> _recentAlerts = [];

  // Life360-ish hysteresis: ~2 m/s (7 km/h) to start, 0.8 m/s to stop, with an
  // instant trigger when the sample is clearly driving speed. Requiring two
  // consecutive samples is what keeps GPS jitter from flapping the state.
  static const double _moveEnterMps = 2.0;
  static const double _moveExitMps = 0.8;
  static const double _moveInstantMps = 5.0;
  static const int _startSamples = 2;
  static const int _stopSamples = 2;

  final StreamController<MovementAlert> _alertController =
      StreamController<MovementAlert>.broadcast();

  /// Movement transition alerts ("started moving" / "stopped") for contacts.
  Stream<MovementAlert> get movementAlerts => _alertController.stream;

  /// Recent movement alerts, newest first.
  List<MovementAlert> get recentAlerts => List.unmodifiable(_recentAlerts);

  /// Motion state for a contact: `{'moving': bool, 'since': DateTime}`.
  /// `since` is when they started moving or stopped, so the UI can show
  /// "Driving" or "Stationary for 12m" like Life360.
  Map<String, dynamic>? contactMotion(String address) {
    final moving = _contactMoving[address];
    if (moving == null) return null;
    return {'moving': moving, 'since': _contactMovingSince[address]};
  }

  final StreamController<Map<String, dynamic>> _locationController =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<void> _contactsChangedController =
      StreamController<void>.broadcast();

  /// Received contact locations, as maps with `lat`, `lng`, `accuracy`,
  /// `routeId`, and `sender`.
  Stream<Map<String, dynamic>> get locationUpdates =>
      _locationController.stream;

  /// Emits whenever the contact list changes (add/pause/rename/restore), so
  /// the map pill and contacts list can refresh.
  Stream<void> get contactsChanged => _contactsChangedController.stream;

  /// Latest location per contact (keyed by route id), for map markers.
  Map<String, Map<String, dynamic>> get contactLocations =>
      Map.unmodifiable(_contactLocations);

  /// True when the node had to fall back to an unencrypted, disk-based
  /// protected store, so the identity private key is not hardware-protected.
  bool get identityStoreInsecure => _identityStoreInsecure;

  Future<void>? _starting;

  /// Starts Veilid exactly once, even when called concurrently (the identity
  /// screen loads the address and publishes the route in parallel).
  Future<void> _ensureStarted() {
    if (_started) return Future.value();
    return _starting ??= _doStart().whenComplete(() => _starting = null);
  }

  Future<void> _doStart() async {
    const platformConfig = VeilidFFIConfig(
      logging: VeilidFFIConfigLogging(
        terminal: VeilidFFIConfigLoggingTerminal(
          enabled: false,
          level: VeilidConfigLogLevel.debug,
        ),
        // Nothing in the app consumes VeilidUpdateLog; formatting and
        // marshalling those events every second was pure background cost.
        api: VeilidFFIConfigLoggingApi(
          enabled: false,
          level: VeilidConfigLogLevel.warn,
        ),
      ),
    );
    Veilid.instance.initializeVeilidCore(platformConfig.toJson());

    final config = await getDefaultVeilidConfig(
      isWeb: kIsWeb,
      programName: 'Grid',
    );

    // Prefer a hardware-backed protected store (Keystore). Only when this
    // device cannot provide one do we fall back to Veilid's disk-based store,
    // and we remember that so Settings can warn that the identity key is not
    // hardware-protected. Failing closed silently would just mean the app
    // never starts on such devices, which is worse than an explicit warning.
    Stream<VeilidUpdate> updates;
    try {
      updates = await Veilid.instance.startupVeilidCore(config);
    } catch (e) {
      debugPrint(
          '[Veilid] protected store unavailable, using insecure fallback: $e');
      _identityStoreInsecure = true;
      final patched = config.copyWith(
        protectedStore: config.protectedStore.copyWith(
          allowInsecureFallback: true,
        ),
      );
      updates = await Veilid.instance.startupVeilidCore(patched);
    }

    _routingContext = await Veilid.instance.routingContext();
    // Keep the update stream subscribed for the process lifetime.
    updates.listen(_handleUpdate);
    await Veilid.instance.attach();

    _started = true;

    // Restore persisted contacts (their stable addresses) and re-resolve their
    // current routes from the DHT. Tolerant: offline contacts stay listed but
    // unresolved until the next send.
    await _restoreContacts();
    await _loadLinkBackToken();
    _scheduleLinkFlush();

    // The app can be backgrounded while the node is still starting, in which
    // case the lifecycle callback ran before `_started` was set. Arm the park
    // timer now instead of staying attached until the next lifecycle change.
    if (!_foreground) setAppForeground(false);

    // One-minute health sample: attachment, live peers and Veilid throughput.
    // Cheap (one state read a minute) and it makes background costs visible in
    // Settings -> Battery & tracking -> Battery diagnostics.
    _stateTimer ??= Timer.periodic(
      const Duration(minutes: 1),
      (_) => _logVeilidState(),
    );
  }

  Timer? _stateTimer;
  bool _stateBusy = false;

  Future<void> _logVeilidState() async {
    if (_stateBusy) return;
    _stateBusy = true;
    try {
      final state = await Veilid.instance.getVeilidState();
      final a = state.attachment;
      final n = state.network;
      DiagnosticsLog.instance.log(
        'VEILID',
        'state=${a.state.name} inet=${a.publicInternetReady} '
        'live=${a.livePeerCount} reliable=${a.reliablePeerCount} '
        'peers=${n.peers.length} down=${n.bpsDown} up=${n.bpsUp} '
        'net=${a.estimatedNetworkSize} parked=$_parked fg=$_foreground '
        'moving=$_moving '
        'idle=${DateTime.now().difference(_lastMovementAt).inSeconds}s',
      );
    } catch (_) {
      // State is best-effort diagnostics only.
    } finally {
      _stateBusy = false;
    }
  }

  // --- Background duty cycle ------------------------------------------------
  //
  // A full Veilid node keeps ~32 peer connections and continuous DHT/route
  // maintenance, which measured ~23% of one CPU core even when idle. That is
  // far more than location tracking needs. While the UI is hidden and the
  // phone is still, the node is parked (detached) and only wakes for a short
  // sync window so queued messages can arrive and our route stays fresh.
  // Movement or opening the app wakes it immediately.
  static const Duration _parkAfter = Duration(minutes: 5);
  static const Duration _syncEvery = Duration(minutes: 5);
  static const Duration _syncWindow = Duration(seconds: 30);

  bool _foreground = true;
  bool _parked = false;
  bool _windowOpen = false;
  bool _moving = false;
  DateTime _lastMovementAt = DateTime.now();

  Timer? _parkTimer;
  Timer? _syncTimer;
  Timer? _windowTimer;
  Future<void> _powerOp = Future.value();

  /// True while the node is detached as part of the background duty cycle.
  bool get nodeParked => _parked;

  /// Serializes attach/detach so a sync window cannot race an app resume.
  Future<T> _serialize<T>(Future<T> Function() op) {
    final next = _powerOp.then((_) => op());
    _powerOp = next.then((_) {}, onError: (Object e) {
      debugPrint('[Veilid] power op failed: $e');
    });
    return next;
  }

  /// App lifecycle hook: visible means stay attached; hidden starts the
  /// countdown to parking.
  void setAppForeground(bool foreground) {
    _foreground = foreground;
    if (foreground) {
      _cancelTimers();
      unawaited(_resume('foreground'));
      _scheduleLinkFlush();
    } else if (_started && !_parked && _parkTimer == null) {
      _parkTimer = Timer(_parkAfter, () {
        _parkTimer = null;
        unawaited(_park('still in background'));
      });
    }
  }

  /// Location hook: called on every fix. Movement keeps the node attached for
  /// the whole trip; going still starts the park countdown.
  void setMoving(bool moving) {
    _moving = moving;
    if (!moving) return;
    _lastMovementAt = DateTime.now();
    if (!_parked) return;
    _cancelTimers();
    unawaited(_resume('movement'));
  }

  void _cancelTimers() {
    _parkTimer?.cancel();
    _parkTimer = null;
    _syncTimer?.cancel();
    _syncTimer = null;
    _windowTimer?.cancel();
    _windowTimer = null;
  }

  Future<void> _park(String reason) => _serialize(() async {
        if (_foreground || !_started || _parked) return;
        // Never park mid-trip, no matter how old the last transition was.
        if (_moving) {
          _parkTimer = Timer(const Duration(minutes: 1), () {
            _parkTimer = null;
            unawaited(_park(reason));
          });
          return;
        }
        // A send window is in flight; try again once it has closed.
        if (_windowOpen) {
          _parkTimer = Timer(const Duration(minutes: 1), () {
            _parkTimer = null;
            unawaited(_park(reason));
          });
          return;
        }
        // Never park in the middle of a trip, even if the UI is hidden.
        final idle = DateTime.now().difference(_lastMovementAt);
        if (idle < _parkAfter) {
          DiagnosticsLog.instance.log(
              'VEILID', 'DETACH deferred (movement ${idle.inSeconds}s ago)');
          _parkTimer = Timer(_parkAfter - idle, () {
            _parkTimer = null;
            unawaited(_park(reason));
          });
          return;
        }
        _parked = true;
        try {
          await Veilid.instance.detach();
          DiagnosticsLog.instance.log('VEILID', 'DETACH parked ($reason)');
        } catch (e) {
          _parked = false;
          DiagnosticsLog.instance.log('VEILID', 'DETACH failed: $e');
        }
        if (_parked) _scheduleSync();
      });

  void _scheduleSync() {
    if (!_parked || _syncTimer != null) return;
    _syncTimer = Timer(_syncEvery, () {
      _syncTimer = null;
      unawaited(_openWindow());
    });
  }

  Future<void> _openWindow() => _serialize(() async {
        if (!_parked || _foreground) return;
        try {
          await Veilid.instance.attach();
          await publishMyRoute();
          _windowOpen = true;
          DiagnosticsLog.instance.log('VEILID', 'ATTACH sync window');
          _scheduleLinkFlush();
        } catch (e) {
          DiagnosticsLog.instance.log('VEILID', 'sync window failed: $e');
          _scheduleSync();
          return;
        }
        _windowTimer = Timer(_syncWindow, () => unawaited(_closeWindow()));
      });

  Future<void> _closeWindow() => _serialize(() async {
        _windowTimer = null;
        if (!_parked || !_windowOpen) return;
        _windowOpen = false;
        try {
          await Veilid.instance.detach();
          DiagnosticsLog.instance.log('VEILID', 'DETACH sync window end');
        } catch (e) {
          DiagnosticsLog.instance.log('VEILID', 'sync window detach failed: $e');
        }
        _scheduleSync();
      });

  Future<void> _resume(String reason) => _serialize(() async {
        if (!_started || !_parked) return;
        _cancelTimers();
        try {
          await Veilid.instance.attach();
          await publishMyRoute();
          _parked = false;
          _windowOpen = false;
          DiagnosticsLog.instance.log('VEILID', 'ATTACH $reason');
          _scheduleLinkFlush();
        } catch (e) {
          DiagnosticsLog.instance.log('VEILID', 'ATTACH $reason failed: $e');
        }
      });

  /// Runs [work] inside a temporary attach window while parked, then parks
  /// again. Used for scheduled location sends so a heartbeat does not leave
  /// the node attached for the rest of the day.
  Future<T> _whileParkedWindow<T>(
    String reason,
    Future<T> Function() work,
  ) async {
    await _serialize(() async {
      await Veilid.instance.attach();
      await publishMyRoute();
      _windowOpen = true;
      DiagnosticsLog.instance.log('VEILID', 'ATTACH $reason');
    });
    try {
      return await work();
    } finally {
      // The app may have come back (or the phone started moving) while the
      // send was in flight; `_resume` has already attached for good.
      if (_parked && !_foreground) {
        await _serialize(() async {
          _windowOpen = false;
          try {
            await Veilid.instance.detach();
            DiagnosticsLog.instance.log('VEILID', 'DETACH $reason end');
          } catch (e) {
            DiagnosticsLog.instance.log('VEILID', 'DETACH $reason failed: $e');
          }
          _scheduleSync();
        });
      }
    }
  }

  Future<void> _loadLinkBackToken() async {
    if (_linkTokenLoaded) return;
    _linkTokenLoaded = true;
    final prefs = await SharedPreferences.getInstance();
    _linkBackToken = prefs.getString(_linkTokenPref);
  }

  Future<void> setLinkBackToken(String? token) async {
    _linkTokenLoaded = true;
    _linkBackToken = token;
    final prefs = await SharedPreferences.getInstance();
    if (token == null || token.isEmpty) {
      await prefs.remove(_linkTokenPref);
    } else {
      await prefs.setString(_linkTokenPref, token);
    }
  }

  Future<void> _restoreContacts() async {
    final prefs = await SharedPreferences.getInstance();
    final addresses = prefs.getStringList(_contactsPrefKey) ?? const <String>[];
    if (addresses.isNotEmpty) {
      debugPrint('[Veilid] restoring ${addresses.length} saved contact(s)');
    }
    for (final address in addresses) {
      if (!_contactAddresses.contains(address)) {
        _contactAddresses.add(address);
      }
      try {
        _contactRoutes[address] = await _importContactRoute(address);
        _contactRouteResolvedAt[address] = DateTime.now();
      } catch (e) {
        debugPrint('[Veilid] restore contact route failed for ${_maskAddress(address)}: $e');
      }
    }
    // Restore per-contact pause state.
    _pausedAddresses
      ..clear()
      ..addAll(prefs.getStringList(_pausedPrefKey) ?? const <String>[]);

    // Restore display name + local contact names.
    _myName = prefs.getString(_myNamePrefKey);
    final namesRaw = prefs.getString(_contactNamesPrefKey);
    if (namesRaw != null && namesRaw.isNotEmpty) {
      try {
        final map = jsonDecode(namesRaw) as Map<String, dynamic>;
        _contactNames
          ..clear()
          ..addAll(map.map((k, v) => MapEntry(k, v as String)));
      } catch (_) {}
    }
    final nicknames = prefs.getStringList(_contactNicknamesPrefKey);
    _contactNicknames
      ..clear()
      ..addAll(nicknames ?? const <String>[]);
    await _loadPendingLink();
    await _restoreContactLocations();
    _nicknamesMigrated =
        prefs.getBool(_nicknamesMigratedPrefKey) ?? false;
    if (!_nicknamesMigrated) {
      // First run with nickname tracking: a stored name equal to the published
      // name was auto-filled; one that differs is a user nickname.
      _contactNicknames.clear();
    }

    // Restore pinned identity keys for contacts we already verified.
    final keysRaw = prefs.getString(_contactKeysPrefKey);
    if (keysRaw != null && keysRaw.isNotEmpty) {
      try {
        final map = jsonDecode(keysRaw) as Map<String, dynamic>;
        _contactPublicKeys
          ..clear()
          ..addAll(map.map((k, v) => MapEntry(k, v as String)));
      } catch (_) {}
    }

    _contactsChangedController.add(null);
  }

  Future<void> _persistContacts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_contactsPrefKey, _contactAddresses);
  }

  Future<void> _persistPaused() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_pausedPrefKey, _pausedAddresses.toList());
  }

  Future<void> _persistContactKeys() async {
    final prefs = await SharedPreferences.getInstance();
    if (_contactPublicKeys.isEmpty) {
      await prefs.remove(_contactKeysPrefKey);
    } else {
      await prefs.setString(_contactKeysPrefKey, jsonEncode(_contactPublicKeys));
    }
  }

  void _handleUpdate(VeilidUpdate update) {
    if (update is VeilidAppMessage) {
      // Chain handlers so fixes are processed in arrival order even when a
      // handler awaits a DHT lookup to verify the sender's identity.
      _inbox = _inbox.then((_) => _handleAppMessage(update)).catchError(
        (Object e) {
          debugPrint('[Veilid] message handler error: $e');
        },
      );
    } else if (update is VeilidUpdateRouteChange) {
      _handleRouteChange(update);
    }
  }

  /// When my published route dies, mint a fresh one and rewrite my DHT record
  /// so contacts always resolve a live route.
  void _handleRouteChange(VeilidUpdateRouteChange update) {
    // Detaching on purpose reports our route drained; do not fight it.
    if (_parked) return;
    final mine = _myRouteId;
    if (mine == null || !update.deadRoutes.contains(mine)) return;
    if (_republishing) return;
    _republishing = true;
    unawaited(publishMyRoute().catchError((Object e) {
      debugPrint('[Veilid] route republish failed: $e');
    }).whenComplete(() => _republishing = false));
  }

  /// Handle an incoming app message.
  ///
  /// This is the trust boundary. A location payload is accepted only when it
  /// comes from a linked contact, is fresh, carries a valid signature made by
  /// the identity key that owns that contact's DHT record, and is not a
  /// replay or a flood. Everything downstream (map, history, places, movement
  /// alerts) assumes the data passing this point was authenticated, so an
  /// unauthenticated peer can no longer move markers, poison a trail, or
  /// trigger fake alerts.
  Future<void> _handleAppMessage(VeilidAppMessage update) async {
    final Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(utf8.decode(update.message));
      if (decoded is! Map<String, dynamic>) {
        _reject('malformed payload');
        return;
      }
      payload = decoded;
    } catch (_) {
      _reject('malformed payload');
      return;
    }
    if (payload['type'] == 'profile') {
      await _handleProfile(payload);
      return;
    }
    if (payload['type'] == 'link_request') {
      await _handleLinkRequest(payload);
      return;
    }
    if (payload['type'] != 'location') return;
    if (payload['v'] != _locationProtocolVersion) {
      _reject('unsupported protocol version');
      return;
    }

    final from = payload['from'];
    if (from is! String || from.isEmpty || from.length > 256) {
      _reject('invalid sender');
      return;
    }
    // Allowlist: only people the user linked can influence this device.
    if (!_contactAddresses.contains(from)) {
      _reject('sender is not a contact', from: from);
      return;
    }

    final lat = (payload['lat'] as num?)?.toDouble();
    final lng = (payload['lng'] as num?)?.toDouble();
    if (lat == null || lng == null || !isFiniteLatLng(lat, lng)) {
      // NaN/Infinity/out-of-range would reach MapLibre's native LatLng and
      // abort the process, so it must never get past this point.
      _reject('invalid coordinates');
      return;
    }
    var accuracy = (payload['accuracy'] as num?)?.toDouble();
    if (accuracy != null &&
        (!accuracy.isFinite || accuracy < 0 || accuracy > 1e6)) {
      accuracy = null;
    }

    final tsRaw = payload['ts'];
    final nonce = payload['nonce'];
    final signature = payload['sig'];
    if (tsRaw is! String || nonce is! String || signature is! String) {
      _reject('missing signature fields');
      return;
    }
    if (tsRaw.length > 64 || nonce.length > 64 || signature.length > 256) {
      _reject('oversized signature fields');
      return;
    }
    final ts = DateTime.tryParse(tsRaw);
    if (ts == null) {
      _reject('invalid timestamp');
      return;
    }
    final now = DateTime.now();
    if (now.toUtc().difference(ts.toUtc()).abs() > _maxClockSkew) {
      _reject('stale timestamp');
      return;
    }
    // A repeated nonce means the same message was delivered twice or replayed.
    // Freshness above bounds how long a captured message stays usable, so a
    // nonce cache is enough replay protection — and unlike a timestamp
    // watermark it survives a sender's clock adjustment.
    if (_seenNonces.contains(nonce)) {
      _reject('replayed message');
      return;
    }
    final lastAccepted = _lastAcceptedAt[from];
    if (lastAccepted != null &&
        now.difference(lastAccepted) < _minBetweenMessages) {
      _reject('rate limited');
      return;
    }

    final publicKey = await _publicKeyFor(from);
    if (publicKey == null) {
      _reject('unknown identity key');
      return;
    }
    final signed = _locationSigningBytes(
      from: from,
      ts: tsRaw,
      nonce: nonce,
      lat: lat,
      lng: lng,
      accuracy: accuracy,
    );
    if (!await _verifySignature(publicKey, signed, signature)) {
      _reject('bad signature');
      return;
    }

    _seenNonces.add(nonce);
    if (_seenNonces.length > 512) _seenNonces.remove(_seenNonces.first);
    _lastAcceptedAt[from] = now;

    // First fix from this contact starts their state clock.
    _contactMoving.putIfAbsent(from, () => false);
    _contactMovingSince.putIfAbsent(from, () => now);
    final rawBattery = payload['battery'];
    int? battery;
    if (rawBattery is num && rawBattery.isFinite) {
      final rounded = rawBattery.round();
      if (rounded >= 0 && rounded <= 100) battery = rounded;
    }
    final charging =
        payload['charging'] is bool ? payload['charging'] as bool : null;

    final prev = _contactLocations[from];
    final loc = <String, dynamic>{
      'lat': lat,
      'lng': lng,
      'accuracy': accuracy,
      'from': from,
      'routeId': update.routeId,
      'sender': update.sender?.toString(),
      'ts': now,
      if (battery != null) 'battery': battery,
      if (charging != null) 'charging': charging,
    };
    _locationController.add(loc);
    _contactLocations[from] = loc;
    // Keep the last known position across restarts so the marker does not
    // vanish until the contact sends again.
    if (now.difference(_lastLocationPersist) >= const Duration(seconds: 30)) {
      _lastLocationPersist = now;
      unawaited(_persistContactLocations());
    }
    if (_loggedLocationFrom.add(from)) {
      DiagnosticsLog.instance.log(
          'LOC',
          'first fix from ${_maskAddress(from)} '
              'acc=${accuracy?.toStringAsFixed(0) ?? '?'}m');
    } else if (prev != null) {
      final age = now.difference(prev['ts'] is DateTime
          ? prev['ts'] as DateTime
          : now);
      if (age >= const Duration(minutes: 10)) {
        DiagnosticsLog.instance.log(
            'LOC',
            'fix after ${age.inMinutes}m gap from ${_maskAddress(from)}');
      }
    }
    if (from == _pendingLinkInviter) {
      _clearPendingLink('two-way location received');
    }
    // Detect movement transitions ("started moving" / "stopped").
    if (prev != null) _detectMovement(from, prev, lat, lng, now);
  }

  static const int _locationProtocolVersion = 2;
  static const String _locationSigningPrefix = 'grid-loc-v2';
  static const Duration _maxClockSkew = Duration(minutes: 5);
  static const Duration _minBetweenMessages = Duration(milliseconds: 500);
  static const Duration _keyLookupCooldown = Duration(seconds: 30);

  VeilidCryptoSystem? _cryptoSystem;
  CryptoKind? _cryptoSystemKind;

  Future<VeilidCryptoSystem> _crypto(CryptoKind kind) async {
    if (_cryptoSystem != null && _cryptoSystemKind == kind) return _cryptoSystem!;
    _cryptoSystem = await Veilid.instance.getCryptoSystem(kind);
    _cryptoSystemKind = kind;
    return _cryptoSystem!;
  }

  /// The bytes covered by a location signature. Both sides must derive this
  /// identically: fixed 6-decimal coordinates, raw timestamp string, raw nonce.
  Uint8List _locationSigningBytes({
    required String from,
    required String ts,
    required String nonce,
    required double lat,
    required double lng,
    double? accuracy,
  }) {
    final canonical = [
      _locationSigningPrefix,
      from,
      ts,
      nonce,
      lat.toStringAsFixed(6),
      lng.toStringAsFixed(6),
      accuracy == null ? '' : accuracy.toStringAsFixed(1),
    ].join('\n');
    return Uint8List.fromList(utf8.encode(canonical));
  }

  Future<String> _signLocation({
    required String from,
    required String ts,
    required String nonce,
    required double lat,
    required double lng,
    double? accuracy,
  }) async {
    final keyPair = await _keyPairOrCreate();
    final crypto = await _crypto(keyPair.key.kind);
    final signature = await crypto.signWithKeyPair(
      keyPair,
      _locationSigningBytes(
        from: from,
        ts: ts,
        nonce: nonce,
        lat: lat,
        lng: lng,
        accuracy: accuracy,
      ),
    );
    return signature.toString();
  }

  Future<bool> _verifySignature(
      PublicKey publicKey, Uint8List data, String signature) async {
    try {
      final parts = signature.split(':');
      if (parts.length < 2 || parts[0].codeUnits.length != 4) return false;
      final kind = CryptoKind.fromString(parts[0]);
      if (kind != publicKey.kind) return false;
      final crypto = await _crypto(kind);
      return await crypto.verify(
        publicKey,
        data,
        Signature(
          kind: kind,
          value: BareSignature.fromString(parts.sublist(1).join(':')),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  PublicKey? _parsePublicKey(String value) {
    try {
      final parts = value.split(':');
      if (parts.length < 2 || parts[0].codeUnits.length != 4) return null;
      return PublicKey(
        kind: CryptoKind.fromString(parts[0]),
        value: BarePublicKey.fromString(parts.sublist(1).join(':')),
      );
    } catch (_) {
      return null;
    }
  }

  /// The pinned identity key for [address]. Pins it from the DHT record owner
  /// on first use; only the record owner can publish that contact's route, so
  /// the owner key is what authenticates their messages.
  Future<PublicKey?> _publicKeyFor(String address) async {
    final pinned = _contactPublicKeys[address];
    if (pinned != null) {
      final parsed = _parsePublicKey(pinned);
      if (parsed != null) return parsed;
    }
    final attempted = _keyLookupAttemptedAt[address];
    final now = DateTime.now();
    if (attempted != null && now.difference(attempted) < _keyLookupCooldown) {
      return null;
    }
    _keyLookupAttemptedAt[address] = now;
    try {
      final context = _routingContext;
      if (context == null) return null;
      final recordKey = RecordKey.fromString(address);
      final desc = await context.openDHTRecord(recordKey);
      final owner = desc.owner;
      await _pinContactKey(address, owner);
      return owner;
    } catch (e) {
      debugPrint('[Veilid] identity key lookup failed for ${_maskAddress(address)}: $e');
      return null;
    }
  }

  Future<void> _pinContactKey(String address, PublicKey owner) async {
    final value = owner.toString();
    if (_contactPublicKeys[address] == value) return;
    _contactPublicKeys[address] = value;
    await _persistContactKeys();
  }

  String _newNonce() {
    final bytes = List<int>.generate(12, (_) => _random.nextInt(256));
    return base64Url.encode(bytes);
  }

  /// Log-safe form of a contact address.
  String _maskAddress(String address) {
    final parts = address.split(':');
    if (parts.length >= 2 && parts[1].length > 8) {
      return '${parts[0]}:${parts[1].substring(0, 8)}…';
    }
    return address.length > 12 ? '${address.substring(0, 10)}…' : address;
  }

  /// Count a dropped message; log at most once per 30s so a flood cannot turn
  /// into a log storm (and so we never log coordinates or full addresses).
  void _reject(String reason, {String? from}) {
    _rejectedMessages++;
    final now = DateTime.now();
    if (now.difference(_lastRejectLog) < const Duration(seconds: 30)) return;
    _lastRejectLog = now;
    final who = from == null ? '' : ' from ${_maskAddress(from)}';
    debugPrint(
        '[Veilid] dropped $_rejectedMessages message(s); last reason: $reason$who');
    DiagnosticsLog.instance.log(
        'MSG', 'dropped: $reason$who (total $_rejectedMessages)');
  }

  /// Compare a new fix to the previous one and emit a movement alert on a
  /// moving <-> stationary transition.
  ///
  /// Raw per-fix speed is noisy (GPS jitter, a single big jump), so transitions
  /// are debounced: two consecutive samples are needed to declare movement
  /// (or one clearly-driving-speed sample), two to declare a stop, and each
  /// contact gets a cooldown between alerts.
  void _detectMovement(String address, Map<String, dynamic> prev, double lat,
      double lng, DateTime now) {
    final prevLat = (prev['lat'] as num?)?.toDouble();
    final prevLng = (prev['lng'] as num?)?.toDouble();
    final prevTs = prev['ts'];
    if (prevLat == null || prevLng == null || prevTs is! DateTime) return;
    final dt = now.difference(prevTs).inSeconds;
    if (dt <= 0) return;
    final meters = distanceMeters(prevLat, prevLng, lat, lng);
    final speed = meters / dt;
    final wasMoving = _contactMoving[address] ?? false;
    // A long gap (app asleep, reboot, sparse stationary updates) says nothing
    // about continuous movement. It does tell us the contact was not driving
    // quickly over that gap, so a moving contact can still be marked stopped.
    if (dt > 300) {
      _contactMovingStreak[address] = 0;
      if (wasMoving && speed < _moveExitMps) {
        _contactMoving[address] = false;
        _contactMovingSince[address] = now;
        _recordMovementAlert(address, now, false);
      }
      return;
    }

    // Hysteresis: harder to start than to keep going.
    final threshold = wasMoving ? _moveExitMps : _moveEnterMps;
    final saysMoving = speed >= threshold;
    if (saysMoving == wasMoving) {
      _contactMovingStreak[address] = 0;
      return;
    }

    final streak = (_contactMovingStreak[address] ?? 0) + 1;
    _contactMovingStreak[address] = streak;
    final needed = wasMoving ? _stopSamples : _startSamples;
    final instantStart = !wasMoving && speed >= _moveInstantMps;
    if (!instantStart && streak < needed) return;

    _contactMovingStreak[address] = 0;
    _contactMoving[address] = !wasMoving;
    _contactMovingSince[address] = now;
    _recordMovementAlert(address, now, !wasMoving);
  }

  void _recordMovementAlert(String address, DateTime at, bool moving) {
    _recentAlerts.insert(0, MovementAlert(address: address, at: at, moving: moving));
    if (_recentAlerts.length > 50) _recentAlerts.removeLast();
    _alertController.add(_recentAlerts.first);
  }

  /// Returns my identity keypair, persisted in Veilid's protected store so it
  /// survives restarts (Keystore-backed on real devices).
  ///
  /// Veilid's generateKeyPair mints a *fresh random* pair each call (it does
  /// not persist), so we store it ourselves; otherwise the writer keypair would
  /// stop matching our DHT record's owner after a restart.
  // Memoized so concurrent startup callers (the map, the contacts screen and
  // the route publisher) cannot each mint a keypair or a DHT record and leave
  // the losing record orphaned.
  Future<KeyPair>? _keyPairFuture;
  Future<RecordKey>? _recordKeyFuture;

  Future<KeyPair> _keyPairOrCreate() {
    if (_keyPair != null) return Future.value(_keyPair!);
    return _keyPairFuture ??= _loadOrCreateKeyPair().then((kp) {
      _keyPair = kp;
      return kp;
    }).whenComplete(() {
      if (_keyPair == null) _keyPairFuture = null;
    });
  }

  Future<KeyPair> _loadOrCreateKeyPair() async {
    final saved = await Veilid.instance.loadUserSecret(_myKeyPairSecretKey);
    if (saved != null && saved.isNotEmpty) {
      try {
        return KeyPair.fromString(utf8.decode(saved));
      } catch (_) {
        // Fall through and mint a fresh pair.
      }
    }
    final kp = await Veilid.instance.generateKeyPair(cryptoKindVLD0);
    await Veilid.instance.saveUserSecret(
      _myKeyPairSecretKey,
      Uint8List.fromList(utf8.encode(kp.toString())),
    );
    return kp;
  }

  /// Returns my stable address: the DHT record key I publish my current route
  /// to. Created once and persisted, so it survives restarts.
  Future<String> myAddress() async {
    await _ensureStarted();
    return (await _myRecordKeyOrCreate()).toString();
  }

  Future<RecordKey> _myRecordKeyOrCreate() {
    if (_myRecordKey != null) return Future.value(_myRecordKey!);
    return _recordKeyFuture ??= _loadOrCreateRecordKey().then((key) {
      _myRecordKey = key;
      return key;
    }).whenComplete(() {
      if (_myRecordKey == null) _recordKeyFuture = null;
    });
  }

  Future<RecordKey> _loadOrCreateRecordKey() async {
    final kp = await _keyPairOrCreate();
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_myRecordKeyPrefKey);
    if (saved != null && saved.isNotEmpty) {
      // A record can only be written by the keypair that owns it. If the
      // protected store changed (e.g. the hardware store became available
      // after a fallback), the saved record belongs to a key we no longer
      // have, and every publish would fail schema validation. Replace it.
      final savedOwner = prefs.getString(_myRecordOwnerPrefKey);
      final ownerMatches =
          savedOwner == null || savedOwner == kp.key.toString();
      if (ownerMatches) {
        try {
          _myRecordKey = RecordKey.fromString(saved);
          return _myRecordKey!;
        } catch (_) {
          // Fall through and recreate a fresh record.
        }
      } else {
        debugPrint(
            '[Veilid] saved address belongs to a previous identity key; creating a new address');
        await prefs.remove(_myRecordKeyPrefKey);
        await prefs.remove(_myRecordOwnerPrefKey);
      }
    }
    final context = _routingContext!;
    final desc = await context.createDHTRecord(
      cryptoKindVLD0,
      DHTSchema.dflt(oCnt: 2), // subkey 0 = route, subkey 1 = display name
      owner: kp,
    );
    _myRecordKey = desc.key;
    await prefs.setString(_myRecordKeyPrefKey, desc.key.toString());
    await prefs.setString(_myRecordOwnerPrefKey, kp.key.toString());
    return _myRecordKey!;
  }

  /// Allocate a fresh private route and publish its blob to my DHT record so
  /// contacts can reach me by looking up my stable address. Call on startup
  /// (and again if the route dies).
  Future<void> publishMyRoute() async {
    await _ensureStarted();
    // A route can only be allocated once the node is attached with a
    // PublicInternet network class (otherwise newPrivateRoute throws TryAgain).
    await Veilid.instance.waitForAttachmentCondition(
      timeout: const Duration(seconds: 30),
    );
    final route = await Veilid.instance.newPrivateRoute();
    _myRouteId = route.routeId.toString();
    final kp = await _keyPairOrCreate();
    final recordKey = await _myRecordKeyOrCreate();
    final context = _routingContext!;
    await context.openDHTRecord(recordKey, writer: kp);
    await context.setDHTValue(
      recordKey,
      0,
      route.blob,
      options: SetDHTValueOptions(writer: kp),
    );
    // Also publish the display name (subkey 1), if set.
    final name = await myName();
    if (name != null && name.isNotEmpty) {
      await context.setDHTValue(
        recordKey,
        1,
        Uint8List.fromList(utf8.encode(name)),
        options: SetDHTValueOptions(writer: kp),
      );
    }
    debugPrint('[Veilid] published route to DHT');
  }

  /// My display name (null until set). Published to my DHT record.
  Future<String?> myName() async {
    if (_myName != null) return _myName;
    final prefs = await SharedPreferences.getInstance();
    _myName = prefs.getString(_myNamePrefKey);
    return _myName;
  }

  /// Set my display name and publish it to my DHT record so contacts see it.
  Future<void> setMyName(String name) async {
    _myName = name.trim();
    final prefs = await SharedPreferences.getInstance();
    if (_myName!.isEmpty) {
      await prefs.remove(_myNamePrefKey);
    } else {
      await prefs.setString(_myNamePrefKey, _myName!);
    }
    // Publish to DHT (best-effort; it rides along with the route republish).
    try {
      await _ensureStarted();
      final recordKey = await _myRecordKeyOrCreate();
      final kp = await _keyPairOrCreate();
      final context = _routingContext!;
      await context.openDHTRecord(recordKey, writer: kp);
      await context.setDHTValue(
        recordKey,
        1,
        Uint8List.fromList(utf8.encode(_myName ?? '')),
        options: SetDHTValueOptions(writer: kp),
      );
    } catch (e) {
      debugPrint('[Veilid] publish name failed (non-fatal): $e');
    }
    // Profile messages update contacts immediately even before their next DHT
    // refresh check.
    unawaited(sendProfile());
  }

  /// The local display name I've assigned to a contact, or null.
  String? getContactName(String address) => _contactNames[address];

  /// Rename a contact locally (their published name is only a default).
  Future<void> setContactName(String address, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      _contactNames.remove(address);
      _contactNicknames.remove(address);
    } else {
      _contactNames[address] = trimmed;
      _contactNicknames.add(address);
    }
    await _persistContactNames();
    await _persistContactNicknames();
    _contactsChangedController.add(null);
    if (trimmed.isEmpty) unawaited(refreshContactNames());
  }

  Future<void> _persistContactNicknames() async {
    final prefs = await SharedPreferences.getInstance();
    if (_contactNicknames.isEmpty) {
      await prefs.remove(_contactNicknamesPrefKey);
    } else {
      await prefs.setStringList(
          _contactNicknamesPrefKey, _contactNicknames.toList());
    }
  }

  /// Re-reads each contact's published name. A locally set nickname always
  /// wins; otherwise the displayed name follows the published one.
  Future<void> refreshContactNames() async {
    if (_refreshingNames) return;
    _refreshingNames = true;
    try {
      await _ensureStarted();
      if (!_nicknamesMigrated) {
        _nicknamesMigrated = true;
        for (final address in List<String>.from(_contactAddresses)) {
          final stored = _contactNames[address];
          if (stored == null || stored.isEmpty) continue;
          try {
            final published =
                await _readContactName(address, forceRefresh: true);
            if (published == null ||
                published.isEmpty ||
                published != stored) {
              // Offline or different: preserve the local name as a nickname
              // rather than risk overwriting a user's choice.
              _contactNicknames.add(address);
            }
          } catch (_) {
            _contactNicknames.add(address);
          }
        }
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_nicknamesMigratedPrefKey, true);
        await _persistContactNicknames();
      }
      var changed = false;
      for (final address in List<String>.from(_contactAddresses)) {
        if (_contactNicknames.contains(address)) continue;
        try {
          final published =
              await _readContactName(address, forceRefresh: true);
          if (published == null || published.isEmpty) continue;
          if (_contactNames[address] != published) {
            _contactNames[address] = published;
            changed = true;
          }
        } catch (_) {
          // Offline contact: keep the last known name.
        }
      }
      if (changed) {
        await _persistContactNames();
        _contactsChangedController.add(null);
      }
    } finally {
      _refreshingNames = false;
    }
  }

  /// Look up a contact's current route blob from their DHT record and import
  /// it, returning the route id to send on.
  Future<RouteId> _importContactRoute(String address) async {
    final recordKey = RecordKey.fromString(address);
    final context = _routingContext!;
    final desc = await context.openDHTRecord(recordKey);
    // The record's owner is the contact's identity key: only they can write
    // the route blob we are about to import. Pin it so later messages can be
    // authenticated against it.
    await _pinContactKey(address, desc.owner);
    final value = await context.getDHTValue(recordKey, 0, forceRefresh: true);
    if (value == null || value.data.isEmpty) {
      throw StateError('Contact has no published route');
    }
    // Re-opening a record is in-place, so the handle is reused rather than
    // leaked. It is released when the contact is removed.
    return await Veilid.instance.importRemotePrivateRoute(value.data);
  }

  /// Add a contact by their stable address (a DHT record key string). Their
  /// published display name is used as the default local name.
  Future<void> addContact(String address) async {
    await _ensureStarted();
    final isNew = !_contactAddresses.contains(address);
    if (isNew) {
      _contactAddresses.add(address);
      await _persistContacts();
    }
    DiagnosticsLog.instance.log(
        'LINK', 'add ${_maskAddress(address)} new=$isNew');
    // Route resolution is best-effort. The contact still belongs in the list
    // when their node is parked or the DHT is briefly unavailable; the route
    // is resolved again on the next send.
    final started = DateTime.now();
    try {
      _contactRoutes[address] = await _importContactRoute(address);
      _contactRouteResolvedAt[address] = DateTime.now();
      DiagnosticsLog.instance.log(
          'LINK',
          'route resolved ${_maskAddress(address)} in '
              '${DateTime.now().difference(started).inMilliseconds}ms');
    } catch (e) {
      DiagnosticsLog.instance.log(
          'LINK', 'route resolve failed ${_maskAddress(address)}: $e');
    }
    // Pull the contact's published name as a default (best-effort).
    try {
      final name = await _readContactName(address, forceRefresh: true);
      if (name != null &&
          name.isNotEmpty &&
          !_contactNicknames.contains(address) &&
          _contactNames[address] != name) {
        _contactNames[address] = name;
        await _persistContactNames();
      }
    } catch (e) {
      DiagnosticsLog.instance.log(
          'LINK', 'name lookup failed ${_maskAddress(address)}: $e');
    }
    _contactsChangedController.add(null);
    unawaited(sendProfile(to: address));
  }

  Future<String?> _readContactName(String address,
      {bool forceRefresh = false}) async {
    final recordKey = RecordKey.fromString(address);
    final context = _routingContext!;
    await context.openDHTRecord(recordKey);
    final value =
        await context.getDHTValue(recordKey, 1, forceRefresh: forceRefresh);
    if (value == null || value.data.isEmpty) return null;
    return utf8.decode(value.data);
  }

  Future<void> _persistContactNames() async {
    final prefs = await SharedPreferences.getInstance();
    if (_contactNames.isEmpty) {
      await prefs.remove(_contactNamesPrefKey);
    } else {
      await prefs.setString(_contactNamesPrefKey, jsonEncode(_contactNames));
    }
  }

  Future<void> _persistContactLocations() async {
    final prefs = await SharedPreferences.getInstance();
    if (_contactLocations.isEmpty) {
      await prefs.remove(_contactLocationsPrefKey);
      return;
    }
    final raw = <String, dynamic>{};
    for (final e in _contactLocations.entries) {
      final loc = e.value;
      final ts = loc['ts'];
      raw[e.key] = <String, dynamic>{
        'lat': loc['lat'],
        'lng': loc['lng'],
        'accuracy': loc['accuracy'],
        'battery': loc['battery'],
        'charging': loc['charging'],
        'ts': ts is DateTime ? ts.toUtc().toIso8601String() : null,
      };
    }
    await prefs.setString(_contactLocationsPrefKey, jsonEncode(raw));
  }

  Future<void> _restoreContactLocations() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_contactLocationsPrefKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      var restored = 0;
      for (final e in map.entries) {
        if (!_contactAddresses.contains(e.key)) continue;
        final v = e.value;
        if (v is! Map<String, dynamic>) continue;
        final lat = (v['lat'] as num?)?.toDouble();
        final lng = (v['lng'] as num?)?.toDouble();
        if (lat == null || lng == null || !isFiniteLatLng(lat, lng)) continue;
        final ts =
            DateTime.tryParse(v['ts'] as String? ?? '') ?? DateTime.now();
        _contactLocations[e.key] = <String, dynamic>{
          'lat': lat,
          'lng': lng,
          'accuracy': v['accuracy'],
          'battery': v['battery'],
          'charging': v['charging'],
          'from': e.key,
          'ts': ts,
          'restored': true,
        };
        restored++;
      }
      if (restored > 0) {
        DiagnosticsLog.instance.log(
            'LOC', 'restored $restored last known position(s)');
      }
    } catch (e) {
      debugPrint('[Veilid] restore locations failed: $e');
    }
  }

  Future<String> _signText(String canonical) async {
    final keyPair = await _keyPairOrCreate();
    final crypto = await _crypto(keyPair.key.kind);
    final signature = await crypto.signWithKeyPair(
      keyPair,
      Uint8List.fromList(utf8.encode(canonical)),
    );
    return signature.toString();
  }

  /// Sends my current name/avatar to contacts (or one contact).
  Future<void> sendProfile({String? to}) async {
    await _ensureStarted();
    if (_parked) {
      await _whileParkedWindow(
          'profile window', () => _sendProfileNow(to: to));
      return;
    }
    await _sendProfileNow(to: to);
  }

  Future<void> _sendProfileNow({String? to}) async {
    final context = _routingContext;
    if (context == null) return;
    final from = await myAddress();
    final name = await myName();
    final avatar = AvatarStore.instance.mine;
    final avatarB64 = avatar == null ? null : base64Encode(avatar);
    final avatarHash = avatar == null
        ? ''
        : sha256.convert(avatar).toString();
    if (name == null && avatarB64 == null) return;
    final ts = DateTime.now().toUtc().toIso8601String();
    final nonce = _newNonce();
    final canonical = [
      'grid-profile-v1',
      from,
      ts,
      nonce,
      name ?? '',
      avatarHash,
    ].join('\n');
    final signature = await _signText(canonical);
    final payload = jsonEncode({
      'type': 'profile',
      'v': 1,
      'from': from,
      'ts': ts,
      'nonce': nonce,
      if (name != null) 'name': name,
      if (avatarB64 != null) 'avatar': avatarB64,
      'sig': signature,
    });
    final bytes = Uint8List.fromList(utf8.encode(payload));
    final targets = to != null
        ? <String>[to]
        : List<String>.from(_contactAddresses);
    for (final address in targets) {
      if (!_contactAddresses.contains(address)) continue;
      try {
        final routeId = await _routeFor(address);
        await context.appMessage(TargetRouteId(routeId: routeId), bytes);
      } catch (e) {
        debugPrint('[Veilid] profile send failed for ${_maskAddress(address)}: $e');
      }
    }
  }

  /// Sends a signed "link me back" request to the inviter.
  ///
  /// The request is retried (across parked windows and app restarts) until the
  /// inviter answers with a signed profile, so a node that is detached when the
  /// first attempt lands no longer breaks two-way linking.
  Future<void> sendLinkBack(String inviter, String token) async {
    if (token.isEmpty) return;
    // A new invite starts a fresh retry budget; only the same invite keeps
    // its original deadline.
    final sameInvite =
        _pendingLinkInviter == inviter && _pendingLinkToken == token;
    _pendingLinkInviter = inviter;
    _pendingLinkToken = token;
    if (!sameInvite || _pendingLinkSince == null) {
      _pendingLinkSince = DateTime.now();
    }
    _linkAttempts = 0;
    await _persistPendingLink();
    DiagnosticsLog.instance.log(
        'LINK', 'link-back queued for ${_maskAddress(inviter)}');
    await _flushPendingLink();
  }

  Future<void> _sendLinkBackNow(String inviter, String token) async {
    final context = _routingContext;
    if (context == null) throw StateError('Veilid is not started');
    final from = await myAddress();
    if (from == inviter) return;
    final name = await myName();
    final avatar = AvatarStore.instance.mine;
    final avatarB64 = avatar == null ? null : base64Encode(avatar);
    final avatarHash = avatar == null
        ? ''
        : sha256.convert(avatar).toString();
    final ts = DateTime.now().toUtc().toIso8601String();
    final nonce = _newNonce();
    final canonical = [
      'grid-link-v1',
      from,
      ts,
      nonce,
      token,
      name ?? '',
      avatarHash,
    ].join('\n');
    final signature = await _signText(canonical);
    final payload = jsonEncode({
      'type': 'link_request',
      'v': 1,
      'from': from,
      'ts': ts,
      'nonce': nonce,
      'token': token,
      if (name != null) 'name': name,
      if (avatarB64 != null) 'avatar': avatarB64,
      'sig': signature,
    });
    final routeId = await _routeFor(inviter);
    await context.appMessage(
      TargetRouteId(routeId: routeId),
      Uint8List.fromList(utf8.encode(payload)),
    );
    DiagnosticsLog.instance.log(
        'LINK', 'link-back delivered to ${_maskAddress(inviter)}');
  }

  Future<void> _persistPendingLink() async {
    final prefs = await SharedPreferences.getInstance();
    final inviter = _pendingLinkInviter;
    final token = _pendingLinkToken;
    if (inviter == null || token == null) {
      await prefs.remove(_pendingLinkInviterPrefKey);
      await prefs.remove(_pendingLinkTokenPrefKey);
      await prefs.remove(_pendingLinkSincePrefKey);
      return;
    }
    await prefs.setString(_pendingLinkInviterPrefKey, inviter);
    await prefs.setString(_pendingLinkTokenPrefKey, token);
    await prefs.setString(_pendingLinkSincePrefKey,
        (_pendingLinkSince ?? DateTime.now()).toUtc().toIso8601String());
  }

  Future<void> _loadPendingLink() async {
    final prefs = await SharedPreferences.getInstance();
    _pendingLinkInviter = prefs.getString(_pendingLinkInviterPrefKey);
    _pendingLinkToken = prefs.getString(_pendingLinkTokenPrefKey);
    _pendingLinkSince =
        DateTime.tryParse(prefs.getString(_pendingLinkSincePrefKey) ?? '');
    if (_pendingLinkInviter != null &&
        _pendingLinkToken != null &&
        _pendingLinkToken!.isNotEmpty) {
      DiagnosticsLog.instance.log('LINK',
          'pending link-back restored for ${_maskAddress(_pendingLinkInviter!)}');
    }
  }

  void _clearPendingLink(String reason) {
    if (_pendingLinkInviter == null) return;
    DiagnosticsLog.instance.log('LINK', 'link-back cleared ($reason)');
    _pendingLinkInviter = null;
    _pendingLinkToken = null;
    _pendingLinkSince = null;
    _linkAttempts = 0;
    _linkRetryTimer?.cancel();
    _linkRetryTimer = null;
    unawaited(_persistPendingLink());
  }

  void _scheduleLinkFlush() {
    if (_pendingLinkInviter == null) return;
    unawaited(Future<void>.delayed(
        const Duration(seconds: 1), _flushPendingLink));
  }

  Future<void> _flushPendingLink() async {
    final inviter = _pendingLinkInviter;
    final token = _pendingLinkToken;
    if (inviter == null || token == null || token.isEmpty) return;
    await _ensureStarted();
    _linkRetryTimer?.cancel();
    _linkRetryTimer = null;
    final since = _pendingLinkSince ?? DateTime.now();
    if (DateTime.now().difference(since) > const Duration(hours: 2)) {
      _clearPendingLink('timed out after 2h');
      return;
    }
    _linkAttempts++;
    DiagnosticsLog.instance.log('LINK',
        'link-back attempt $_linkAttempts for ${_maskAddress(inviter)}');
    var sent = false;
    try {
      if (_parked) {
        await _whileParkedWindow(
            'link window', () => _sendLinkBackNow(inviter, token));
      } else {
        await _sendLinkBackNow(inviter, token);
      }
      sent = true;
    } catch (e) {
      DiagnosticsLog.instance.log(
          'LINK', 'link-back attempt $_linkAttempts failed: $e');
    }
    if (_pendingLinkInviter == null) return;
    // Keep trying even after a "successful" send: the inviter may have been
    // detached when it arrived, and the send itself cannot tell us that.
    final delay = sent
        ? (_linkAttempts <= 3
            ? const Duration(seconds: 45)
            : const Duration(minutes: 3))
        : (_linkAttempts <= 2
            ? const Duration(seconds: 15)
            : const Duration(minutes: 1));
    DiagnosticsLog.instance.log(
        'LINK', 'link-back retry in ${delay.inSeconds}s');
    _linkRetryTimer = Timer(delay, () => unawaited(_flushPendingLink()));
  }

  Future<void> _handleProfile(Map<String, dynamic> payload) async {
    try {
      if (payload['v'] != 1) return;
      final from = payload['from'];
      if (from is! String || !_contactAddresses.contains(from)) return;
      final tsRaw = payload['ts'];
      final nonce = payload['nonce'];
      final signature = payload['sig'];
      if (tsRaw is! String || nonce is! String || signature is! String) return;
      final ts = DateTime.tryParse(tsRaw);
      if (ts == null ||
          DateTime.now().toUtc().difference(ts.toUtc()).abs() > _maxClockSkew) {
        return;
      }
      if (_seenNonces.contains(nonce)) return;
      final avatarB64 = payload['avatar'] is String ? payload['avatar'] as String : null;
      Uint8List? avatar;
      if (avatarB64 != null && avatarB64.isNotEmpty) {
        try {
          avatar = base64Decode(avatarB64);
        } catch (_) {
          return;
        }
        if (avatar.length > AvatarStore.maxBytes) return;
      }
      final name = payload['name'] is String ? payload['name'] as String : '';
      final avatarHash = avatar == null ? '' : sha256.convert(avatar).toString();
      final canonical = [
        'grid-profile-v1',
        from,
        tsRaw,
        nonce,
        name,
        avatarHash,
      ].join('\n');
      final key = await _publicKeyFor(from);
      if (key == null ||
          !await _verifySignature(
              key, Uint8List.fromList(utf8.encode(canonical)), signature)) {
        return;
      }
      _seenNonces.add(nonce);
      if (_seenNonces.length > 512) _seenNonces.remove(_seenNonces.first);
      DiagnosticsLog.instance.log(
          'LINK', 'profile from ${_maskAddress(from)} '
              'name=${name.isEmpty ? '(none)' : 'yes'} '
              'avatar=${avatar == null ? 'no' : 'yes'}');
      if (from == _pendingLinkInviter) {
        _clearPendingLink('profile received');
      }
      if (!_nicknamesMigrated) await refreshContactNames();
      if (name.isNotEmpty &&
          !_contactNicknames.contains(from) &&
          _contactNames[from] != name) {
        _contactNames[from] = name;
        await _persistContactNames();
        _contactsChangedController.add(null);
      }
      if (avatar != null) {
        await AvatarStore.instance.setContactAvatar(from, avatar);
      }
    } catch (e) {
      debugPrint('[Veilid] profile handling failed: $e');
    }
  }

  Future<void> _handleLinkRequest(Map<String, dynamic> payload) async {
    try {
      await _loadLinkBackToken();
      final token = _linkBackToken;
      if (token == null || token.isEmpty) {
        DiagnosticsLog.instance.log(
            'LINK', 'request rejected: this device has no active invite token');
        return;
      }
      if (payload['v'] != 1) {
        DiagnosticsLog.instance.log(
            'LINK', 'request rejected: unsupported version');
        return;
      }
      final from = payload['from'];
      if (from is! String ||
          from.isEmpty ||
          from == await myAddress()) {
        DiagnosticsLog.instance.log('LINK', 'request rejected: bad sender');
        return;
      }
      if (payload['token'] != token) {
        DiagnosticsLog.instance.log('LINK',
            'request rejected: token mismatch from ${_maskAddress(from)}');
        return;
      }
      final tsRaw = payload['ts'];
      final nonce = payload['nonce'];
      final signature = payload['sig'];
      if (tsRaw is! String ||
          nonce is! String ||
          signature is! String) {
        DiagnosticsLog.instance.log(
            'LINK', 'request rejected: missing signature fields');
        return;
      }
      final ts = DateTime.tryParse(tsRaw);
      if (ts == null ||
          DateTime.now().toUtc().difference(ts.toUtc()).abs() > _maxClockSkew) {
        DiagnosticsLog.instance.log('LINK',
            'request rejected: stale timestamp from ${_maskAddress(from)}');
        return;
      }
      if (_seenNonces.contains(nonce)) {
        DiagnosticsLog.instance.log('LINK',
            'request rejected: replay from ${_maskAddress(from)}');
        return;
      }
      final avatarB64 = payload['avatar'] is String ? payload['avatar'] as String : null;
      Uint8List? avatar;
      if (avatarB64 != null && avatarB64.isNotEmpty) {
        try {
          avatar = base64Decode(avatarB64);
        } catch (_) {
          return;
        }
        if (avatar.length > AvatarStore.maxBytes) return;
      }
      final name = payload['name'] is String ? payload['name'] as String : '';
      final avatarHash = avatar == null ? '' : sha256.convert(avatar).toString();
      final canonical = [
        'grid-link-v1',
        from,
        tsRaw,
        nonce,
        token,
        name,
        avatarHash,
      ].join('\n');
      final key = await _publicKeyFor(from);
      if (key == null) {
        DiagnosticsLog.instance.log('LINK',
            'request rejected: identity key unavailable for '
            '${_maskAddress(from)}');
        return;
      }
      if (!await _verifySignature(
          key, Uint8List.fromList(utf8.encode(canonical)), signature)) {
        DiagnosticsLog.instance.log('LINK',
            'request rejected: bad signature from ${_maskAddress(from)}');
        return;
      }
      _seenNonces.add(nonce);
      if (_seenNonces.length > 512) _seenNonces.remove(_seenNonces.first);
      DiagnosticsLog.instance.log(
          'LINK', 'request accepted from ${_maskAddress(from)} '
              'name=${name.isEmpty ? '(none)' : 'yes'} '
              'avatar=${avatar == null ? 'no' : 'yes'}');
      await addContact(from);
      if (avatar != null) {
        await AvatarStore.instance.setContactAvatar(from, avatar);
      }
      unawaited(sendProfile(to: from));
    } catch (e) {
      DiagnosticsLog.instance.log('LINK', 'link request handling failed: $e');
      debugPrint('[Veilid] link-back handling failed: $e');
    }
  }

  /// Sends [lat],[lng] to every non-paused contact. Caches each contact's
  /// route for a short TTL so continuous sharing doesn't re-hit the DHT on
  /// every fix; a stale/dead route is re-resolved after the TTL.
  Future<void> sendLocation(
    double lat,
    double lng, {
    double? accuracy,
    double? batteryLevel,
    bool? isCharging,
  }) async {
    // Never sign or transmit a GPS value that could crash a recipient.
    if (!isFiniteLatLng(lat, lng)) return;
    await _ensureStarted();
    if (_parked) {
      // A scheduled heartbeat should not leave the node attached all day.
      await _whileParkedWindow(
        'send window',
        () => _sendLocationNow(lat, lng,
            accuracy: accuracy,
            batteryLevel: batteryLevel,
            isCharging: isCharging),
      );
      return;
    }
    await _sendLocationNow(lat, lng,
        accuracy: accuracy,
        batteryLevel: batteryLevel,
        isCharging: isCharging);
  }

  Future<void> _sendLocationNow(
    double lat,
    double lng, {
    double? accuracy,
    double? batteryLevel,
    bool? isCharging,
  }) async {
    final context = _routingContext;
    // Snapshot the list: adds/removes can land while we await below.
    final addresses = List<String>.from(_contactAddresses);
    if (context == null || addresses.isEmpty) return;

    // Quantize to the precision the signature covers (sub-centimetre), so the
    // signed bytes and the transmitted value are identical.
    final lat6 = double.parse(lat.toStringAsFixed(6));
    final lng6 = double.parse(lng.toStringAsFixed(6));

    // Sign the fix. The signature is what proves to recipients that this
    // really is us and not anyone else who can reach their route.
    final from = await myAddress();
    final ts = DateTime.now().toUtc().toIso8601String();
    final nonce = _newNonce();
    final signature = await _signLocation(
      from: from,
      ts: ts,
      nonce: nonce,
      lat: lat6,
      lng: lng6,
      accuracy: accuracy,
    );
    // Battery is advisory UI state. It travels inside the encrypted,
    // authenticated route and is ignored by older clients; the location
    // signature covers position only.
    final batteryPercent = batteryLevel == null || !batteryLevel.isFinite
        ? null
        : (batteryLevel * 100).round().clamp(0, 100);
    final payload = jsonEncode({
      'type': 'location',
      'v': _locationProtocolVersion,
      'lat': lat6,
      'lng': lng6,
      'accuracy': accuracy,
      if (batteryPercent != null) 'battery': batteryPercent,
      if (isCharging != null) 'charging': isCharging,
      'from': from,
      'ts': ts,
      'nonce': nonce,
      'sig': signature,
    });
    final bytes = Uint8List.fromList(utf8.encode(payload));
    for (final address in addresses) {
      if (_pausedAddresses.contains(address)) continue;
      try {
        final routeId = await _routeFor(address);
        await context.appMessage(TargetRouteId(routeId: routeId), bytes);
      } catch (e) {
        // Clear the cache so the next send re-resolves a possibly-dead route.
        _contactRoutes.remove(address);
        _contactRouteResolvedAt.remove(address);
        debugPrint('[Veilid] sendLocation failed for ${_maskAddress(address)}: $e');
      }
    }
  }

  /// Cached route for [address], re-resolved every [_routeTtl].
  Future<RouteId> _routeFor(String address) async {
    final cached = _contactRoutes[address];
    final at = _contactRouteResolvedAt[address];
    if (cached != null &&
        at != null &&
        DateTime.now().difference(at) < _routeTtl) {
      return cached;
    }
    final routeId = await _importContactRoute(address);
    _contactRoutes[address] = routeId;
    _contactRouteResolvedAt[address] = DateTime.now();
    return routeId;
  }

  static const _routeTtl = Duration(minutes: 5);

  /// Whether sharing with [address] is paused.
  bool isContactPaused(String address) => _pausedAddresses.contains(address);

  /// Pause or resume sharing with [address].
  Future<void> setContactPaused(String address, bool paused) async {
    if (paused) {
      _pausedAddresses.add(address);
    } else {
      _pausedAddresses.remove(address);
    }
    await _persistPaused();
    _contactsChangedController.add(null);
  }

  /// Unlink a contact: stop sharing with them, forget their identity and
  /// published name, release the imported route, close their DHT handle, and
  /// delete their stored trail. After this, messages from them are rejected by
  /// the allowlist, and we no longer hold a working route to them.
  Future<void> removeContact(String address) async {
    final route = _contactRoutes.remove(address);
    _contactRouteResolvedAt.remove(address);
    _contactAddresses.remove(address);
    _pausedAddresses.remove(address);
    _contactNames.remove(address);
    _contactNicknames.remove(address);
    _contactPublicKeys.remove(address);
    _contactLocations.remove(address);
    _contactMoving.remove(address);
    _contactMovingStreak.remove(address);
    _contactMovingSince.remove(address);
    _lastAcceptedAt.remove(address);
    _keyLookupAttemptedAt.remove(address);

    if (address == _pendingLinkInviter) {
      _clearPendingLink('contact removed');
    }
    unawaited(_persistContactLocations());
    await AvatarStore.instance.removeContactAvatar(address);
    await _persistContacts();
    await _persistPaused();
    await _persistContactNames();
    await _persistContactNicknames();
    await _persistContactKeys();

    // Drop the imported route so the capability dies with the contact, and
    // release the DHT record handle we were holding open.
    if (route != null) {
      try {
        await Veilid.instance.releasePrivateRoute(route);
      } catch (e) {
        debugPrint('[Veilid] release route failed (non-fatal): $e');
      }
    }
    final context = _routingContext;
    if (context != null) {
      try {
        await context.closeDHTRecord(RecordKey.fromString(address));
      } catch (_) {
        // Not open (e.g. offline at startup) — nothing to release.
      }
    }

    _contactsChangedController.add(null);
  }

  /// Replace my rendezvous record with a brand-new address.
  ///
  /// The old address is emptied and deleted, so anyone holding it (a leaked
  /// QR, a former contact) can no longer resolve my route or reach me. The
  /// caller must share the new QR; existing contacts cannot send until they
  /// re-link. Returns the new address.
  Future<String> rotateAddress() async {
    await _ensureStarted();
    final context = _routingContext;
    if (context == null) throw StateError('Veilid is not started');
    final prefs = await SharedPreferences.getInstance();
    final oldKeyPair = await _keyPairOrCreate();
    final oldKey = _myRecordKey;

    if (oldKey != null) {
      // Clear the route blob so a cached resolution finds nothing, then
      // delete the record outright (owner-only).
      try {
        await context.openDHTRecord(oldKey, writer: oldKeyPair);
        await context.setDHTValue(
          oldKey,
          0,
          Uint8List(0),
          options: SetDHTValueOptions(writer: oldKeyPair),
        );
        await context.deleteDHTRecord(oldKey);
      } catch (e) {
        debugPrint('[Veilid] old address teardown failed: $e');
      }
      try {
        await context.closeDHTRecord(oldKey);
      } catch (_) {}
    }

    // Rotate the identity keypair as well. In this Veilid version the record
    // key is derived from the owner, so reusing the keypair would re-create
    // the *same* address with only a new encryption secret.
    final newKeyPair = await Veilid.instance.generateKeyPair(cryptoKindVLD0);
    await Veilid.instance.saveUserSecret(
      _myKeyPairSecretKey,
      Uint8List.fromList(utf8.encode(newKeyPair.toString())),
    );
    _keyPair = newKeyPair;

    _myRecordKey = null;
    _recordKeyFuture = null;
    _keyPairFuture = null;
    _myRouteId = null;
    await prefs.remove(_myRecordKeyPrefKey);
    await prefs.remove(_myRecordOwnerPrefKey);

    final newKey = await _myRecordKeyOrCreate();
    await publishMyRoute();
    return newKey.toString();
  }

  /// Contact addresses (DHT record key strings), as stored.
  List<String> get contactAddresses => List.unmodifiable(_contactAddresses);

}
