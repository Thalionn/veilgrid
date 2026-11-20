import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// A place returned by forward geocoding (address or place-name search).
class GeoSearchResult {
  const GeoSearchResult({
    required this.label,
    required this.address,
    required this.latitude,
    required this.longitude,
  });

  /// Short name for the place ("Eiffel Tower", "123 Main St").
  final String label;

  /// Full display name from the geocoder.
  final String address;

  final double latitude;
  final double longitude;
}

class GeoSearchException implements Exception {
  const GeoSearchException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Forward geocoding for the "add a place" flow.
///
/// Uses OpenStreetMap's Nominatim. Only the text the user types is sent — no
/// coordinates, identity or contact data. Nominatim's usage policy asks for an
/// identifying User-Agent and at most one request per second, both enforced
/// here.
class GeocodingService {
  GeocodingService._();
  static final GeocodingService instance = GeocodingService._();

  static const String _host = 'nominatim.openstreetmap.org';
  static const String _userAgent =
      'VeilGrid/2.2 (peer-to-peer location sharing; https://github.com/Thalionn/veilgrid)';
  static const Duration _minInterval = Duration(milliseconds: 1100);

  DateTime? _lastRequestAt;
  Future<void> _queue = Future<void>.value();

  /// Search for [query]. Returns matches in relevance order, or an empty list
  /// when nothing matched. Throws [GeoSearchException] on network/HTTP errors.
  Future<List<GeoSearchResult>> search(String query, {int limit = 6}) {
    final trimmed = query.trim();
    if (trimmed.length < 3) return Future.value(const []);

    // Serialize calls so a burst of keystrokes cannot exceed the rate limit.
    final completer = Completer<List<GeoSearchResult>>();
    _queue = _queue.then((_) async {
      try {
        await _respectRateLimit();
        final uri = Uri.https(_host, '/search', {
          'format': 'jsonv2',
          'q': trimmed,
          'limit': '$limit',
          'addressdetails': '1',
          'accept-language': 'en',
        });
        final response = await http.get(
          uri,
          headers: {
            'User-Agent': _userAgent,
            'Accept': 'application/json',
          },
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode != 200) {
          throw GeoSearchException(
              'Search is unavailable right now (HTTP ${response.statusCode}).');
        }
        completer.complete(_parse(response.body));
      } catch (e) {
        if (!completer.isCompleted) {
          completer.completeError(e is GeoSearchException
              ? e
              : const GeoSearchException(
                  'Could not reach the search service. Check your connection.'));
        }
      }
    });
    return completer.future;
  }

  Future<void> _respectRateLimit() async {
    final last = _lastRequestAt;
    if (last != null) {
      final elapsed = DateTime.now().difference(last);
      if (elapsed < _minInterval) {
        await Future<void>.delayed(_minInterval - elapsed);
      }
    }
    _lastRequestAt = DateTime.now();
  }

  List<GeoSearchResult> _parse(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! List) return const [];
    final results = <GeoSearchResult>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final lat = double.tryParse('${item['lat']}');
      final lng = double.tryParse('${item['lon']}');
      if (lat == null || lng == null) continue;
      final display = (item['display_name'] as String?)?.trim() ?? '';
      final name = (item['name'] as String?)?.trim() ?? '';
      final label = name.isNotEmpty
          ? name
          : (display.isNotEmpty ? display.split(',').first.trim() : 'Place');
      results.add(GeoSearchResult(
        label: label,
        address: display,
        latitude: lat,
        longitude: lng,
      ));
    }
    return results;
  }
}
