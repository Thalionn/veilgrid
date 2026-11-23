import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class PlaceIconOption {
  const PlaceIconOption(this.id, this.label, this.icon);
  final String id;
  final String label;
  final IconData icon;
}

const List<PlaceIconOption> placeIconOptions = [
  PlaceIconOption('place', 'Place', Icons.place),
  PlaceIconOption('home', 'Home', Icons.home),
  PlaceIconOption('work', 'Work', Icons.work),
  PlaceIconOption('school', 'School', Icons.school),
  PlaceIconOption('gym', 'Gym', Icons.fitness_center),
  PlaceIconOption('store', 'Store', Icons.local_grocery_store),
  PlaceIconOption('food', 'Food', Icons.restaurant),
  PlaceIconOption('cafe', 'Cafe', Icons.local_cafe),
  PlaceIconOption('medical', 'Medical', Icons.local_hospital),
  PlaceIconOption('park', 'Park', Icons.park),
  PlaceIconOption('sports', 'Sports', Icons.sports_soccer),
  PlaceIconOption('family', 'Family', Icons.child_care),
  PlaceIconOption('pets', 'Pets', Icons.pets),
  PlaceIconOption('worship', 'Worship', Icons.church),
  PlaceIconOption('shopping', 'Shopping', Icons.shopping_bag),
  PlaceIconOption('car', 'Car', Icons.directions_car),
];

PlaceIconOption placeIconFor(String? id) {
  for (final o in placeIconOptions) {
    if (o.id == id) return o;
  }
  return placeIconOptions.first;
}

/// Renders a circular place marker with the chosen Material icon.
Future<Uint8List> renderPlaceMarker(String iconId, Color color) async {
  const size = 128.0;
  final option = placeIconFor(iconId);
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
  final tp = TextPainter(
    text: TextSpan(
      text: String.fromCharCode(option.icon.codePoint),
      style: TextStyle(
        fontFamily: option.icon.fontFamily,
        package: option.icon.fontPackage,
        fontSize: 64,
        color: Colors.white,
      ),
    ),
    textDirection: TextDirection.ltr,
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

class PlaceIconPicker extends StatelessWidget {
  const PlaceIconPicker({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final option in placeIconOptions)
          Semantics(
            label: option.label,
            button: true,
            selected: selected == option.id,
            child: InkWell(
            onTap: () => onSelected(option.id),
            borderRadius: BorderRadius.circular(20),
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected == option.id
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest,
                border: Border.all(
                  color: selected == option.id
                      ? scheme.primary
                      : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Icon(
                option.icon,
                size: 20,
                color: selected == option.id
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
          ),
      ],
    );
  }
}
