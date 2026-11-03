import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'grid_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: const GridPage(),
    ),
  );
}
