import 'dart:math' as math;
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

/// Pixel width of an encoded image (used to keep photo markers the same
/// rendered size as 128 px badges).
Future<int> imagePixelWidth(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final width = frame.image.width;
  frame.image.dispose();
  codec.dispose();
  return width;
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


class ClusterAvatar {
  const ClusterAvatar({
    required this.initials,
    required this.color,
    this.photo,
  });
  final String initials;
  final Color color;
  final Uint8List? photo;
}

/// Place icon with up to three member avatars above it and a count badge.
Future<Uint8List> renderPlaceCluster({
  required IconData placeIcon,
  required Color color,
  required List<ClusterAvatar> people,
}) async {
  const size = 192.0;
  const center = Offset(size / 2, size / 2);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  // Place circle.
  canvas.drawCircle(center, 64, Paint()..color = color);
  canvas.drawCircle(
    center,
    60,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..color = Colors.white,
  );
  final iconPainter = TextPainter(
    text: TextSpan(
      text: String.fromCharCode(placeIcon.codePoint),
      style: TextStyle(
        fontFamily: placeIcon.fontFamily,
        package: placeIcon.fontPackage,
        fontSize: 58,
        color: Colors.white,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  iconPainter.paint(
    canvas,
    Offset(center.dx - iconPainter.width / 2,
        center.dy - iconPainter.height / 2),
  );

  final shown = people.take(3).toList();
  const avatarSize = 54.0;
  const positions = <Offset>[
    Offset(96, 28),
    Offset(58, 40),
    Offset(134, 40),
  ];
  for (var i = 0; i < shown.length; i++) {
    final c = positions[i];
    final rect = Rect.fromCircle(center: c, radius: avatarSize / 2);
    final photo = shown[i].photo;
    if (photo != null) {
      final codec = await ui.instantiateImageCodec(photo);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      canvas.save();
      canvas.clipPath(Path()..addOval(rect));
      final scale = math.max(
        avatarSize / image.width,
        avatarSize / image.height,
      );
      final dw = image.width * scale;
      final dh = image.height * scale;
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromCenter(
            center: c, width: dw, height: dh),
        Paint(),
      );
      canvas.restore();
      image.dispose();
      codec.dispose();
    } else {
      canvas.drawCircle(c, avatarSize / 2, Paint()..color = shown[i].color);
      final tp = TextPainter(
        text: TextSpan(
          text: shown[i].initials,
          style: const TextStyle(
            color: Colors.white,
            fontFamily: 'Geist',
            fontWeight: FontWeight.w700,
            fontSize: 20,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
    }
    canvas.drawCircle(
      c,
      avatarSize / 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = Colors.white,
    );
  }

  if (people.length > 3) {
    final badge = Offset(size - 24, 24);
    canvas.drawCircle(badge, 20, Paint()..color = const Color(0xFF11161A));
    canvas.drawCircle(
      badge,
      20,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.white,
    );
    final tp = TextPainter(
      text: TextSpan(
        text: '+${people.length - 3}',
        style: const TextStyle(
            color: Colors.white, fontFamily: 'Geist', fontSize: 16),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, badge - Offset(tp.width / 2, tp.height / 2));
  }

  final out = await recorder
      .endRecording()
      .toImage(size.toInt(), size.toInt());
  final data = await out.toByteData(format: ui.ImageByteFormat.png);
  out.dispose();
  return data!.buffer.asUint8List();
}
