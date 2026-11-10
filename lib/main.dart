import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'grid_page.dart';
import 'notify.dart';

ThemeData _theme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF26A69A),
    brightness: Brightness.dark,
  ).copyWith(surface: Colors.black);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Colors.black,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.black,
      surfaceTintColor: Colors.transparent,
    ),
    listTileTheme: ListTileThemeData(
      selectedColor: scheme.primary,
      selectedTileColor: scheme.primary.withValues(alpha: 0.18),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await initNotifications();
  runApp(MaterialApp(theme: _theme(), home: const GridPage()));
}
