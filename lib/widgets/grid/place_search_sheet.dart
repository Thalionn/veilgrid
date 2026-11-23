import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';

import 'package:grid_frontend/services/geocoding_service.dart';
import 'package:grid_frontend/styles/grid_colors.dart';
import 'package:grid_frontend/widgets/grid/grid_sheet.dart';

/// What the sheet returns: a coordinate to create a place at, plus a name the
/// user can accept or edit.
class PlaceSelection {
  const PlaceSelection({
    required this.latitude,
    required this.longitude,
    this.suggestedName,
  });

  final double latitude;
  final double longitude;
  final String? suggestedName;
}

/// Bottom sheet for adding a place by searching an address/place name, or by
/// using the current position. Pops a [PlaceSelection].
class PlaceSearchSheet extends StatefulWidget {
  const PlaceSearchSheet({super.key, this.myLocation, this.title = 'Add a place'});

  final LatLng? myLocation;
  final String title;

  @override
  State<PlaceSearchSheet> createState() => _PlaceSearchSheetState();
}

class _PlaceSearchSheetState extends State<PlaceSearchSheet> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  int _requestSeq = 0;

  List<GeoSearchResult> _results = const [];
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();
    if (query.length < 3) {
      _requestSeq++; // cancel any in-flight result
      setState(() {
        _results = const [];
        _loading = false;
        _error = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 450), () => _search(query));
  }

  Future<void> _search(String query) async {
    final seq = ++_requestSeq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await GeocodingService.instance.search(query);
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    } on GeoSearchException catch (e) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _loading = false;
        _error = 'Search failed. Check your connection and try again.';
      });
    }
  }

  void _select(PlaceSelection selection) {
    Navigator.of(context).pop(selection);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.gridColors;
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    final height = (MediaQuery.of(context).size.height - viewInsets) * 0.75;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: SizedBox(
        height: height,
        child: GridSheetContainer(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: GridSheetHeader(
                  title: widget.title,
                  onClose: () => Navigator.of(context).pop(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onChanged: _onChanged,
                  onSubmitted: (v) {
                    _debounce?.cancel();
                    if (v.trim().length >= 3) _search(v.trim());
                  },
                  decoration: InputDecoration(
                    hintText: 'Search an address or place',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _controller.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _controller.clear();
                              _onChanged('');
                            },
                          ),
                  ),
                ),
              ),
              Expanded(child: _body(c)),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Text(
                  'Search by OpenStreetMap · only what you type is sent',
                  style: GoogleFonts.getFont('Geist',
                      fontSize: 11, color: c.text3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(GridColors c) {
    final me = widget.myLocation;
    final children = <Widget>[];

    if (me != null) {
      children.add(ListTile(
        leading: Icon(Icons.my_location, color: c.mint, size: 20),
        title: const Text('Use my current location'),
        subtitle: Text(
          '${me.latitude.toStringAsFixed(4)}, ${me.longitude.toStringAsFixed(4)}',
          style: TextStyle(fontSize: 11, color: c.text3),
        ),
        onTap: () => _select(PlaceSelection(
          latitude: me.latitude,
          longitude: me.longitude,
        )),
      ));
      children.add(Divider(height: 1, color: c.hairline));
    }

    if (_loading) {
      children.add(const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ));
    } else if (_error != null) {
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        child: Text(_error!, style: TextStyle(color: c.text2)),
      ));
    } else if (_controller.text.trim().length < 3) {
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        child: Text(
          'Type at least 3 characters to search for a street address, '
          'neighbourhood, business or landmark.',
          style: TextStyle(color: c.text3, fontSize: 13),
        ),
      ));
    } else if (_results.isEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        child: Text('No matches for "${_controller.text.trim()}".',
            style: TextStyle(color: c.text3)),
      ));
    } else {
      children.add(Expanded(
        child: ListView.separated(
          padding: const EdgeInsets.only(bottom: 8),
          itemCount: _results.length,
          separatorBuilder: (_, __) => Divider(height: 1, color: c.hairline),
          itemBuilder: (context, i) {
            final r = _results[i];
            return ListTile(
              leading: Icon(Icons.place_outlined, color: c.mint, size: 20),
              title: Text(r.label, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                r.address,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: c.text3),
              ),
              onTap: () => _select(PlaceSelection(
                latitude: r.latitude,
                longitude: r.longitude,
                suggestedName: r.label,
              )),
            );
          },
        ),
      ));
    }

    return Column(
      mainAxisSize: MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}
