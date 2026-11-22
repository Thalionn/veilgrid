import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:grid_frontend/styles/tokens.dart';
import 'package:grid_frontend/styles/grid_colors.dart';
import 'package:grid_frontend/services/theme_controller.dart';
import 'package:grid_frontend/services/location_manager.dart';
import 'package:grid_frontend/services/location/location_dispatch.dart';
import 'package:grid_frontend/services/sharing_state_notifier.dart';
import 'package:grid_frontend/services/veilid_service.dart';
import 'package:grid_frontend/services/database_service.dart';
import 'package:grid_frontend/services/location/home_geofence_service.dart';
import 'package:grid_frontend/services/battery_guard.dart';
import 'package:grid_frontend/repositories/location_history_repository.dart';
import 'package:grid_frontend/screens/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Hydrate the persisted last fix before the first frame, so the map opens
  // on the user's location instead of a placeholder. This is only prefs and
  // listener setup (fast); hardware tracking starts after the UI is up.
  await LocationManager.instance.initialize();
  runApp(const GridApp());
  _startLocation();
  _initHistory();
  _initSharing();
  _initPublish();
  BatteryGuard.instance.start();
}

/// Best-effort location boot: start tracking so "Send location" has a real
/// fix. Fire-and-forget so it never blocks first frame or crashes boot.
Future<void> _startLocation() async {
  try {
    await LocationManager.instance.startTracking();
    // Start the home geofence once tracking is up (auto-pause at home).
    await HomeGeofenceService.instance.start();
  } catch (e) {
    debugPrint('[Location] start failed (non-fatal): $e');
  }
}

/// Wire the device-local location history repo into VeilidService so received
/// contact locations (and my own fixes) are recorded as trails. Construction is
/// cheap (the DB is opened lazily on first write).
void _initHistory() {
  final db = DatabaseService();
  final repo = LocationHistoryRepository(db);
  VeilidService.instance.attachHistoryRepo(repo);

  // Record my own trail from the location stream (the repo throttles points).
  LocationManager.instance.locationStream.listen((update) {
    VeilidService.instance.recordMyLocation(update.latitude, update.longitude);
  });
}

/// Continuously share my location through the dispatch policy.
///
/// [LocationDispatch] decides which fixes are worth sending based on activity,
/// movement, speed and the user's sharing mode, and it is the single place
/// that honours incognito/auto-pause. Sending every raw fix (plus a 30-second
/// timer re-sending an unchanged position) burned radio wakeups for no new
/// information.
void _initSharing() {
  final dispatch = LocationDispatch(SharingStateNotifier.instance);
  unawaited(dispatch.start());

  LocationManager.instance.locationStream.listen((update) {
    if (!dispatch.shouldPost(update)) return;
    VeilidService.instance.sendLocation(update.latitude, update.longitude,
        accuracy: update.accuracy);
  });
}

/// Publish my current route to my DHT record so contacts can resolve my
/// address. Retries transient failures (route allocation can fail while the
/// node is still attaching); route death is handled by VeilidService itself.
Future<void> _initPublish() async {
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      await VeilidService.instance.publishMyRoute();
      return;
    } catch (e) {
      debugPrint('[Veilid] publish attempt ${attempt + 1} failed: $e');
      await Future.delayed(const Duration(seconds: 5));
    }
  }
}

class GridApp extends StatelessWidget {
  const GridApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeController.instance,
      builder: (context, _) => MaterialApp(
        title: 'Grid',
        debugShowCheckedModeBanner: false,
        theme: _buildTheme(GridTokens.lightScheme()),
        darkTheme: _buildTheme(GridTokens.darkScheme()),
        themeMode: ThemeController.instance.mode,
        home: const HomeScreen(),
      ),
    );
  }
}

/// Build the app theme from a Grid-tokenized ColorScheme.
ThemeData _buildTheme(ColorScheme scheme) {
  final base = scheme.brightness == Brightness.dark
      ? ThemeData.dark(useMaterial3: true)
      : ThemeData.light(useMaterial3: true);

  final gridColors = scheme.brightness == Brightness.dark
      ? GridColors.dark()
      : GridColors.light();

  final textTheme = GoogleFonts.getTextTheme('Geist', base.textTheme).apply(
    bodyColor: scheme.onSurface,
    displayColor: scheme.onSurface,
  );

  return base.copyWith(
    extensions: <ThemeExtension<dynamic>>[gridColors],
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: GoogleFonts.getFont('Geist',
        color: scheme.onSurface,
        fontSize: 17,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.015,
      ),
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceVariant,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(GridTokens.rLg),
        side: BorderSide(color: scheme.outlineVariant, width: 1),
      ),
    ),
    dividerColor: scheme.outlineVariant,
    iconTheme: IconThemeData(color: scheme.onSurface),
    primaryIconTheme: IconThemeData(color: scheme.onPrimary),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 0,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        textStyle: GoogleFonts.getFont('Geist',
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.onSurface,
        minimumSize: const Size.fromHeight(52),
        side: BorderSide(color: scheme.outline, width: 1),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        textStyle: GoogleFonts.getFont('Geist',
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: scheme.primary,
        textStyle: GoogleFonts.getFont('Geist',
          fontSize: 15,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceVariant,
      hintStyle: GoogleFonts.getFont('Geist', color: gridColors.text3, fontSize: 15),
      labelStyle: GoogleFonts.getFont('Geist', color: gridColors.text2, fontSize: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(GridTokens.rMd),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(GridTokens.rMd),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(GridTokens.rMd),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: GoogleFonts.getFont('Geist', color: scheme.onInverseSurface),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(GridTokens.rMd),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(GridTokens.r2Xl),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(GridTokens.rXl),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.white
            : scheme.onSurface.withOpacity(0.5),
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : scheme.surfaceContainerHighest,
      ),
    ),
  );
}
