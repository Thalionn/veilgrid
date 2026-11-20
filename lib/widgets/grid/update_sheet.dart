import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:grid_frontend/services/update_service.dart';
import 'package:grid_frontend/styles/grid_colors.dart';
import 'package:grid_frontend/widgets/grid/grid_sheet.dart';

/// Bottom sheet for an available GitHub release: download the APK and hand it
/// to Android's package installer.
class UpdateSheet extends StatefulWidget {
  const UpdateSheet({super.key, required this.info});

  final UpdateInfo info;

  @override
  State<UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<UpdateSheet> {
  bool _downloading = false;
  double _progress = 0;
  String? _apkPath;
  String? _error;
  String _current = '';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((p) {
      if (!mounted) return;
      setState(() => _current = '${p.version} (${p.buildNumber})');
    });
  }

  Future<void> _start() async {
    setState(() => _error = null);

    // Android needs "install unknown apps" for Grid. If it is off, there is no
    // point downloading yet — send the user to the setting.
    if (!await UpdateService.instance.canInstall()) {
      await UpdateService.instance.openInstallSettings();
      if (!mounted) return;
      setState(() => _error =
          'Allow "Install unknown apps" for Grid, then tap Install again.');
      return;
    }

    if (_apkPath == null) {
      setState(() {
        _downloading = true;
        _progress = 0;
      });
      try {
        final path = await UpdateService.instance.download(
          widget.info,
          onProgress: (p) {
            if (mounted) setState(() => _progress = p.clamp(0.0, 1.0));
          },
        );
        if (!mounted) return;
        setState(() {
          _apkPath = path;
          _downloading = false;
        });
      } on UpdateException catch (e) {
        if (!mounted) return;
        setState(() {
          _downloading = false;
          _error = e.message;
        });
        return;
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _downloading = false;
          _error = 'Download failed. Check your connection and try again.';
        });
        return;
      }
    }

    try {
      await UpdateService.instance.install(_apkPath!);
    } on UpdateException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.gridColors;
    final notes = widget.info.notes;

    return GridSheetContainer(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GridSheetHeader(
              title: 'Update available',
              subtitle:
                  'VeilGrid ${widget.info.version} (${widget.info.buildNumber})',
              onClose: () => Navigator.of(context).pop(),
            ),
            const SizedBox(height: 12),
            Text(
              _current.isEmpty ? ' ' : 'You are on $_current',
              style: TextStyle(fontSize: 12, color: c.text3),
            ),
            if (notes != null && notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: SingleChildScrollView(
                  child: Text(notes,
                      style: TextStyle(fontSize: 13, color: c.text2)),
                ),
              ),
            ],
            if (_downloading) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _progress == 0 ? null : _progress),
              const SizedBox(height: 6),
              Text(
                'Downloading… ${(_progress * 100).round()}%',
                style: TextStyle(fontSize: 11, color: c.text3),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(fontSize: 12, color: c.danger)),
            ],
            const SizedBox(height: 16),
            Text(
              'Updates come from GitHub Releases. Android will ask you to '
              'confirm the install.',
              style: TextStyle(fontSize: 11, color: c.text3),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed:
                        _downloading ? null : () => Navigator.of(context).pop(),
                    child: const Text('Not now'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: _downloading ? null : _start,
                    child: Text(
                      _apkPath == null ? 'Download & install' : 'Install',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
