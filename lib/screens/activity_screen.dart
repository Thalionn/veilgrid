import 'dart:async';

import 'package:flutter/material.dart';

import 'package:grid_frontend/models/place.dart';
import 'package:grid_frontend/services/activity_store.dart';
import 'package:grid_frontend/services/veilid_service.dart';
import 'package:grid_frontend/styles/grid_colors.dart';
import 'package:grid_frontend/utilities/time_ago_formatter.dart';
import 'package:grid_frontend/widgets/contact_detail_sheet.dart';
import 'package:grid_frontend/widgets/grid/tab_active.dart';

enum _ActivityFilter { all, arrivals, departures, movement }

/// Activity tab: place arrivals/departures and movement, filterable by
/// contact and kind. Persisted across launches by [ActivityStore].
class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  final Set<String> _people = {};
  _ActivityFilter _filter = _ActivityFilter.all;
  StreamSubscription<void>? _contactsSub;
  bool _active = true;

  @override
  void initState() {
    super.initState();
    ActivityStore.instance.addListener(_onChanged);
    _contactsSub = VeilidService.instance.contactsChanged.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = TabActive.of(context);
    if (active != _active) {
      _active = active;
      if (_active) setState(() {});
    }
  }

  @override
  void dispose() {
    ActivityStore.instance.removeListener(_onChanged);
    _contactsSub?.cancel();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  List<ContactActivity> get _filtered {
    Iterable<ContactActivity> events = ActivityStore.instance.events;
    if (_people.isNotEmpty) {
      events = events.where((e) => _people.contains(e.address));
    }
    switch (_filter) {
      case _ActivityFilter.all:
        break;
      case _ActivityFilter.arrivals:
        events = events.where((e) => e.kind == ActivityKind.arrived);
        break;
      case _ActivityFilter.departures:
        events = events.where((e) => e.kind == ActivityKind.left);
        break;
      case _ActivityFilter.movement:
        events = events.where((e) =>
            e.kind == ActivityKind.startedMoving ||
            e.kind == ActivityKind.stopped);
        break;
    }
    return events.toList();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.gridColors;
    final contacts = VeilidService.instance.contactAddresses;
    final events = _filtered;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity'),
        actions: [
          PopupMenuButton<_ActivityFilter>(
            icon: const Icon(Icons.filter_list),
            tooltip: 'Filter activity',
            initialValue: _filter,
            onSelected: (f) => setState(() => _filter = f),
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: _ActivityFilter.all, child: Text('All activity')),
              PopupMenuItem(
                  value: _ActivityFilter.arrivals, child: Text('Arrivals')),
              PopupMenuItem(
                  value: _ActivityFilter.departures, child: Text('Departures')),
              PopupMenuItem(
                  value: _ActivityFilter.movement, child: Text('Movement')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (contacts.isNotEmpty)
            SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                children: [
                  ChoiceChip(
                    label: const Text('Everyone'),
                    selected: _people.isEmpty,
                    onSelected: (_) => setState(_people.clear),
                  ),
                  for (final address in contacts) ...[
                    const SizedBox(width: 8),
                    FilterChip(
                      label: Text(_name(address)),
                      selected: _people.contains(address),
                      onSelected: (on) => setState(() {
                        if (on) {
                          _people.add(address);
                        } else {
                          _people.remove(address);
                        }
                      }),
                    ),
                  ],
                ],
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: events.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'No activity yet. Place arrivals, departures and '
                        'movement will appear here.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: c.text3, fontSize: 13),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: events.length,
                    separatorBuilder: (_, __) =>
                        Divider(height: 1, color: c.hairline),
                    itemBuilder: (context, i) => _tile(context, events[i]),
                  ),
          ),
        ],
      ),
    );
  }

  String _name(String address) {
    final n = VeilidService.instance.getContactName(address);
    if (n != null && n.isNotEmpty) return n;
    final parts = address.split(':');
    final key = parts.length >= 2 ? parts[1] : address;
    return key.length > 12 ? '${key.substring(0, 10)}…' : key;
  }

  Widget _tile(BuildContext context, ContactActivity e) {
    final c = context.gridColors;
    final name = _name(e.address);
    final (icon, color, text) = switch (e.kind) {
      ActivityKind.startedMoving => (
          Icons.directions_run,
          c.mint,
          '$name started moving'
        ),
      ActivityKind.stopped => (
          Icons.pause_circle_outline,
          c.text3,
          '$name stopped'
        ),
      ActivityKind.arrived => (
          Icons.place,
          c.mint,
          '$name arrived at ${e.placeName ?? 'a place'}'
        ),
      ActivityKind.left => (
          Icons.directions_walk,
          c.text3,
          '$name left ${e.placeName ?? 'a place'}'
        ),
    };
    final linked = VeilidService.instance.contactAddresses.contains(e.address);
    return ListTile(
      leading: Icon(icon, color: color, size: 20),
      title: Text(text),
      subtitle: Text(
        TimeAgoFormatter.format(e.at.toIso8601String()),
        style: TextStyle(fontSize: 11, color: c.text3),
      ),
      trailing: linked
          ? Icon(Icons.chevron_right, size: 18, color: c.text3)
          : null,
      onTap: linked
          ? () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (_) => ContactDetailSheet(address: e.address),
              )
          : null,
    );
  }
}
