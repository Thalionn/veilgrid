import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Same palette as the in-app fallback avatars, so a contact keeps the same
/// color in lists and on the map.
const List<Color> avatarPalette = <Color>[
  Color(0xFF00DBA4),
  Color(0xFF6DD3F5),
  Color(0xFFB79EFF),
  Color(0xFFF5B947),
  Color(0xFFFF8E72),
  Color(0xFF7DD181),
  Color(0xFFE879C1),
  Color(0xFF9DC3FF),
];

int _stableHash(String s) {
  var h = 5381;
  for (final code in s.codeUnits) {
    h = ((h << 5) + h + code) & 0x7fffffff;
  }
  return h;
}

Color avatarColorFor(String name) =>
    avatarPalette[_stableHash(name) % avatarPalette.length];

/// First [count] letters/digits of the name, uppercase. Punctuation and spaces
/// are skipped so record-key fallbacks still produce readable initials.
String initialsFor(String name, {int count = 3}) {
  final cleaned =
      name.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
  if (cleaned.isEmpty) return '?';
  final n = cleaned.length < count ? cleaned.length : count;
  return cleaned.substring(0, n).toUpperCase();
}

/// Renders a circular initial badge (with a white ring) as PNG bytes for use
/// as a MapLibre symbol image.
Future<Uint8List> renderInitialsBadge(String initials,
    {String? name}) async {
  const size = 128.0;
  final color = avatarColorFor(name ?? initials);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const center = Offset(size / 2, size / 2);
  canvas.drawCircle(center, size / 2, Paint()..color = color);
  canvas.drawCircle(
    center,
    size / 2 - 4,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..color = Colors.white,
  );
  final fontSize = switch (initials.length) {
    1 => 56.0,
    2 => 48.0,
    _ => 40.0,
  };
  final tp = TextPainter(
    text: TextSpan(
      text: initials,
      style: TextStyle(
        color: Colors.white,
        fontFamily: 'Geist',
        fontWeight: FontWeight.w700,
        fontSize: fontSize,
        letterSpacing: initials.length >= 3 ? -1.5 : -0.5,
      ),
    ),
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.center,
  )..layout();
  tp.paint(
    canvas,
    Offset((size - tp.width) / 2, (size - tp.height) / 2),
  );
  final image = await recorder
      .endRecording()
      .toImage(size.toInt(), size.toInt());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}
