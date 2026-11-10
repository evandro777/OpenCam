import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'camera.dart';

const _storage = FlutterSecureStorage();
const _key = 'cameras';

Future<List<Camera>> loadCameras() async {
  final s = await _storage.read(key: _key);
  if (s == null) return [];
  return [
    for (final e in jsonDecode(s) as List)
      Camera.fromJson(e as Map<String, dynamic>),
  ];
}

/// Alert topics the user turned on; null = never set (use the default).
Future<Set<String>?> loadAlertTopics() async {
  final s = await _storage.read(key: 'alertTopics');
  if (s == null) return null;
  return {for (final t in jsonDecode(s) as List) t as String};
}

Future<void> saveAlertTopics(Set<String> topics) =>
    _storage.write(key: 'alertTopics', value: jsonEncode(topics.toList()));

Future<void> saveCameras(List<Camera> cams) => _storage.write(
  key: _key,
  value: jsonEncode([for (final c in cams) c.toJson()]),
);
