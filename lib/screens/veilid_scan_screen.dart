import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';
import 'package:grid_frontend/services/invite_link.dart';
import 'package:grid_frontend/services/veilid_service.dart';

/// Adds a contact by scanning their QR (a Veilid private-route blob) or by
/// pasting the blob text directly.
class VeilidScanScreen extends StatefulWidget {
  const VeilidScanScreen({super.key});

  @override
  State<VeilidScanScreen> createState() => _VeilidScanScreenState();
}

class _VeilidScanScreenState extends State<VeilidScanScreen> {
  final GlobalKey _qrKey = GlobalKey(debugLabel: 'QR');
  final TextEditingController _textController = TextEditingController();
  QRViewController? _controller;
  bool? _permissionGranted;
  bool _handled = false;
  bool _importing = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _requestPermission();
  }

  Future<void> _requestPermission() async {
    final status = await Permission.camera.request();
    if (!mounted) return;
    setState(() => _permissionGranted = status.isGranted);
  }

  @override
  void dispose() {
    _textController.dispose();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _import(String code) async {
    if (code.trim().isEmpty) return;
    setState(() {
      _importing = true;
      _status = 'Importing contact…';
    });
    try {
      final invite = parseInvite(code);
      if (invite == null || invite.code.isEmpty) {
        throw const FormatException('Not a VeilGrid contact code');
      }
      await VeilidService.instance.addContact(invite.code);
      if (invite.twoWay && invite.token != null && invite.token!.isNotEmpty) {
        await VeilidService.instance.sendLinkBack(invite.code, invite.token!);
      }
      if (!mounted) return;
      setState(() => _status = 'Contact added ✓');
      await Future.delayed(const Duration(milliseconds: 900));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Failed: $e';
        _importing = false;
        _handled = false;
      });
    }
  }

  void _onScan(Barcode barcode) async {
    if (_handled) return;
    _handled = true;
    final code = barcode.code;
    if (code == null || code.isEmpty) {
      _handled = false;
      return;
    }
    await _import(code);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add contact')),
      body: Column(
        children: [
          Expanded(
            child: switch (_permissionGranted) {
              null => const Center(child: CircularProgressIndicator()),
              false => const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Camera permission is required to scan a QR. '
                      'You can paste a contact code below instead.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              _ => Stack(
                  children: [
                    QRView(
                      key: _qrKey,
                      onQRViewCreated: (controller) {
                        _controller = controller;
                        controller.scannedDataStream.listen(_onScan);
                      },
                    ),
                    if (_status != null)
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Container(
                          margin: const EdgeInsets.all(24),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.75),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            _status!,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                  ],
                ),
            },
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        isDense: true,
                        labelText: 'Paste contact code',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed:
                        _importing ? null : () => _import(_textController.text),
                    child: const Text('Add'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
