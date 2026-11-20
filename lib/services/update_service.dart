import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A published build that is newer than the one running.
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.buildNumber,
    required this.apkUrl,
    this.notes,
    this.pageUrl,
  });

  final String version;
  final int buildNumber;
  final String apkUrl;
  final String? notes;
  final String? pageUrl;
}

class UpdateException implements Exception {
  const UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Distribution without a store: builds are published as GitHub Releases.
///
/// Every release carries a `latest.json` asset:
/// ```json
/// {"version":"2.1.1","buildNumber":1001,"apk":"https://…","notes":"…","page":"…"}
/// ```
/// The app fetches it from the "latest release" URL, compares `buildNumber`
/// with its own, downloads the APK to the cache and hands it to the system
/// package installer. Nothing is installed silently — Android always shows
/// its own confirmation, and the first time also asks the user to allow
/// installs from Grid.
class UpdateService {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  /// Override at build time for testing (e.g. a local HTTP server):
  /// `flutter build apk --dart-define=UPDATE_BASE_URL=http://10.0.2.2:8099`
  static const String _baseUrl = String.fromEnvironment(
    'UPDATE_BASE_URL',
    defaultValue:
        'https://github.com/Thalionn/veilgrid/releases/latest/download',
  );

  static const MethodChannel _channel =
      MethodChannel('app.thalionn.veilgrid/updater');
  static const String _lastCheckKey = 'update_last_check_at';

  PackageInfo? _packageInfo;
  UpdateInfo? _cached;

  /// The last update found by a background check, if any.
  UpdateInfo? get availableUpdate => _cached;

  Future<PackageInfo> _current() async =>
      _packageInfo ??= await PackageInfo.fromPlatform();

  /// Fetch `latest.json` and return it only when it is newer than this build.
  /// Throws [UpdateException] on network/format errors so the UI can tell
  /// "no update" apart from "couldn't check".
  Future<UpdateInfo?> checkForUpdate() async {
    final current = await _current();
    return _fetchLatest(current);
  }

  /// Checks at most once per [minInterval]; used at startup.
  Future<UpdateInfo?> maybeCheck({
    Duration minInterval = const Duration(hours: 6),
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt(_lastCheckKey) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - last < minInterval.inMilliseconds) return _cached;

    try {
      final result = await checkForUpdate();
      _cached = result;
      await prefs.setInt(_lastCheckKey, now);
      return result;
    } catch (_) {
      // Offline or GitHub unreachable: stay quiet, retry next time.
      return null;
    }
  }

  Future<UpdateInfo?> _fetchLatest(PackageInfo current) async {
    final currentBuild = int.tryParse(current.buildNumber) ?? 0;

    http.Response response;
    try {
      response = await http.get(
        Uri.parse('$_baseUrl/latest.json'),
        headers: {
          'Cache-Control': 'no-cache',
          'Accept': 'application/json',
          'User-Agent': 'Grid/${current.version} (${current.buildNumber})',
        },
      ).timeout(const Duration(seconds: 12));
    } catch (_) {
      throw const UpdateException('Could not reach GitHub. Check your connection.');
    }
    if (response.statusCode != 200) {
      throw UpdateException(
          'No update information available (HTTP ${response.statusCode}).');
    }

    Map<String, dynamic> json;
    try {
      json = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw const UpdateException('Update information is malformed.');
    }

    final version = (json['version'] as String?)?.trim();
    final build = (json['buildNumber'] as num?)?.toInt() ?? 0;
    final apk = (json['apk'] as String?)?.trim();
    if (version == null || version.isEmpty || apk == null || apk.isEmpty) {
      throw const UpdateException('Update information is incomplete.');
    }
    if (build <= currentBuild && _compareVersions(version, current.version) <= 0) {
      return null;
    }

    return UpdateInfo(
      version: version,
      buildNumber: build,
      apkUrl: apk,
      notes: (json['notes'] as String?)?.trim(),
      pageUrl: (json['page'] as String?)?.trim(),
    );
  }

  /// Numeric semver comparison; returns >0 when [a] is newer than [b].
  int _compareVersions(String a, String b) {
    List<int> parts(String v) => v
        .split(RegExp(r'[^0-9]+'))
        .where((p) => p.isNotEmpty)
        .map((p) => int.tryParse(p) ?? 0)
        .toList();
    final pa = parts(a);
    final pb = parts(b);
    for (var i = 0; i < 3; i++) {
      final va = i < pa.length ? pa[i] : 0;
      final vb = i < pb.length ? pb[i] : 0;
      if (va != vb) return va.compareTo(vb);
    }
    return 0;
  }

  /// Download [info] into the app cache. Returns the APK path.
  Future<String> download(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/grid-${info.buildNumber}.apk');
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(info.apkUrl));
      request.headers['Accept'] = 'application/vnd.android.package-archive';
      final response =
          await client.send(request).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw UpdateException(
            'Download failed (HTTP ${response.statusCode}).');
      }
      final total = response.contentLength ?? 0;
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) onProgress?.call(received / total);
        }
      } finally {
        await sink.close();
      }
      if (received == 0) {
        await file.delete();
        throw const UpdateException('Downloaded file is empty.');
      }
      return file.path;
    } on UpdateException {
      rethrow;
    } catch (_) {
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }
      throw const UpdateException('Download failed. Check your connection.');
    } finally {
      client.close();
    }
  }

  /// Whether Android allows Grid to install packages (API 26+ setting).
  Future<bool> canInstall() async {
    try {
      return await _channel.invokeMethod<bool>('canInstall') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Opens the "Install unknown apps → Grid" system screen.
  Future<void> openInstallSettings() async {
    try {
      await _channel.invokeMethod('openInstallSettings');
    } catch (_) {}
  }

  /// Hand the downloaded APK to the system installer.
  Future<void> install(String apkPath) async {
    try {
      await _channel.invokeMethod('installApk', {'path': apkPath});
    } on PlatformException catch (e) {
      throw UpdateException(e.message ?? 'Could not start the installer.');
    }
  }
}
