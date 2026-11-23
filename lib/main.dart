import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:grid_frontend/styles/tokens.dart';
import 'package:grid_frontend/styles/grid_colors.dart';
import 'package:grid_frontend/services/theme_controller.dart';
import 'package:grid_frontend/services/units_controller.dart';
import 'package:grid_frontend/services/location_manager.dart';
import 'package:grid_frontend/services/location/location_dispatch.dart';
import 'package:grid_frontend/services/sharing_state_notifier.dart';
import 'package:grid_frontend/services/veilid_service.dart';
import 'package:grid_frontend/services/location/home_geofence_service.dart';
import 'package:grid_frontend/services/battery_guard.dart';
import 'package:grid_frontend/services/map_data_saver.dart';
import 'package:grid_frontend/services/places_service.dart';
import 'package:grid_frontend/services/place_alert_service.dart';
import 'package:grid_frontend/services/activity_store.dart';
import 'package:grid_frontend/screens/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Hydrate the persisted last fix before the first frame, so the map opens
  // on the user's location instead of a placeholder. This is only prefs and
  // listener setup (fast); hardware tracking starts after the UI is up.
  // Hydrate the small preference-backed controllers together. Theme and
  // units used to load lazily (or not at all), which caused a second theme
  // build on first frame and lost the saved choice across launches.
  await Future.wait([
    LocationManager.instance.initialize(),
    ThemeController.instance.load(),
    UnitsController.instance.load(),
  ]);
  runApp(const GridApp());
  _startLocation();
  _initSharing();
  _initPublish();
  // Non-critical listeners wait for the first frame so they cannot compete
  // with the map's initial layout and style load.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    BatteryGuard.instance.start();
    MapDataSaver.instance.start();
    unawaited(PlacesService.instance.load());
    unawaited(PlaceAlertService.instance.start());
    unawaited(ActivityStore.instance.start());
  });
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
    VeilidService.instance.sendLocation(
      update.latitude,
      update.longitude,
      accuracy: update.accuracy,
      batteryLevel: update.batteryLevel,
      isCharging: update.isCharging,
    );
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

  // ThemeData is immutable and only depends on the scheme, so build each one
  // once instead of rebuilding both on every theme-preference notification.
  static final ThemeData _lightTheme = _buildTheme(GridTokens.lightScheme());
  static final ThemeData _darkTheme = _buildTheme(GridTokens.darkScheme());

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeController.instance,
      builder: (context, _) => MaterialApp(
        title: 'Grid',
        debugShowCheckedModeBanner: false,
        theme: _lightTheme,
        darkTheme: _darkTheme,
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
