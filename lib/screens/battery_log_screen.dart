import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import 'package:grid_frontend/services/diagnostics_log.dart';
import 'package:grid_frontend/services/location_manager.dart';
import 'package:grid_frontend/styles/grid_colors.dart';

/// In-app tracking diagnostics: preset changes, activity, GPS fixes, sends and
/// battery level. Entries live in memory and never leave the device unless the
/// user explicitly shares them.
class BatteryLogScreen extends StatefulWidget {
  const BatteryLogScreen({super.key});

  @override
  State<BatteryLogScreen> createState() => _BatteryLogScreenState();
}

class _BatteryLogScreenState extends State<BatteryLogScreen> {
  @override
  void initState() {
    super.initState();
    DiagnosticsLog.instance.addListener(_onChanged);
    LocationManager.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    DiagnosticsLog.instance.removeListener(_onChanged);
    LocationManager.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _share() async {
    final text = DiagnosticsLog.instance.exportText();
    if (text.isEmpty) return;
    await SharePlus.instance.share(ShareParams(
      text: text,
      subject: 'VeilGrid battery diagnostics',
    ));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.gridColors;
    final log = DiagnosticsLog.instance;
    final entries = log.entries;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Battery diagnostics'),
        actions: [
          IconButton(
            tooltip: 'Copy log',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: entries.isEmpty
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: log.exportText()));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Log copied')),
                    );
                  },
          ),
          IconButton(
            tooltip: 'Share log',
            icon: const Icon(Icons.ios_share),
            onPressed: entries.isEmpty ? null : _share,
          ),
          IconButton(
            tooltip: 'Clear log',
            icon: const Icon(Icons.delete_outline),
            onPressed: entries.isEmpty ? null : log.clear,
          ),
        ],
      ),
      body: Column(
        children: [
          SwitchListTile(
            title: const Text('Detailed battery log'),
            subtitle: Text(
                '${entries.length} events · on this device only'),
            value: log.enabled,
            onChanged: (v) => log.setEnabled(v),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Row(
              children: [
                Expanded(
                  child: _stat(
                    context,
                    'Activity',
                    LocationManager.instance.diagnosticActivity,
                  ),
                ),
                Expanded(
                  child: _stat(
                    context,
                    'Preset',
                    LocationManager.instance.diagnosticPreset,
                  ),
                ),
                Expanded(
                  child: _stat(
                    context,
                    'Forced still',
                    LocationManager.instance.diagnosticForcedStill
                        ? 'yes'
                        : 'no',
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        log.enabled
                            ? 'Waiting for tracking events…'
                            : 'Detailed logging is off.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: c.text3),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    itemCount: entries.length,
                    itemBuilder: (context, i) {
                      final e = entries[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: e.format().substring(0, 8),
                                style: TextStyle(color: c.text3),
                              ),
                              TextSpan(
                                text: ' ${e.tag.padRight(9)} ',
                                style: TextStyle(
                                  color: _tagColor(e.tag, c),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              TextSpan(
                                text: e.message,
                                style: TextStyle(color: c.text2),
                              ),
                            ],
                          ),
                          style: const TextStyle(
                            fontFamily: 'Geist Mono',
                            fontSize: 10.5,
                            height: 1.35,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _stat(BuildContext context, String label, String value) {
    final c = context.gridColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(),
            style: TextStyle(
                fontSize: 9,
                letterSpacing: 0.5,
                color: c.text3)),
        const SizedBox(height: 2),
        Text(value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: c.text)),
      ],
    );
  }

  Color _tagColor(String tag, GridColors c) => switch (tag) {
        'FIX' => c.text3,
        'PRESET' => c.mint,
        'ACTIVITY' => c.amber,
        'STILL' => c.walking,
        'SPEED' => c.walking,
        'SEND' => c.mintDim,
        'BATTERY' => c.amber,
        _ => c.text2,
      };
}
