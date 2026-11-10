import 'dart:async';

import 'package:flutter/foundation.dart';

import 'camera.dart';
import 'onvif.dart';

String? parseProfileToken(String xml) =>
    RegExp(r'<(?:\w+:)?Profiles[^>]*token="([^"]+)"').firstMatch(xml)?.group(1);

/// ONVIF pan/tilt for one camera. Everything goes through one queue so a
/// quick tap's Stop can never overtake its ContinuousMove.
class Ptz {
  Ptz(this.cam);
  final Camera cam;

  String? _url, _token;
  Future<void> _last = Future.value();
  Timer? _timer;

  /// True if the camera has an ONVIF PTZ service. shortcut: re-detected on
  /// every fullscreen open, upgrade by storing the port if that is slow.
  Future<bool> connect() async {
    final hit = await firstOnvif(_tryPort);
    _url = hit?.$1;
    _token = hit?.$2;
    return hit != null;
  }

  Future<(String, String)?> _tryPort(int port) async {
    try {
      final urls = await onvifServices(cam, port);
      final media = urls.firstWhere((u) => u.toLowerCase().contains('media'));
      final ptz = urls.firstWhere((u) => u.toLowerCase().contains('ptz'));
      // GetNodes is not asked: CAM2 (Yoosee) drops it but moves fine. A profile
      // with a PTZ configuration is the sign of a PTZ camera.
      final profiles = await onvifSoap(cam, media, '<trt:GetProfiles/>');
      final token = parseProfileToken(profiles);
      if (token == null || !profiles.contains('PTZConfiguration')) return null;
      return (ptz, token);
    } catch (_) {
      return null; // closed, not ONVIF, wrong credentials or no PTZ
    }
  }

  /// Pan [x] / tilt [y] in -1..1 until [stop] (or 10 s, in case the release
  /// is lost).
  void move(double x, double y) {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 10), stop);
    _send(_move(x, y));
  }

  String _move(double x, double y) =>
      '<tptz:ContinuousMove><tptz:ProfileToken>$_token</tptz:ProfileToken>'
      '<tptz:Velocity><tt:PanTilt x="$x" y="$y"/></tptz:Velocity>'
      '</tptz:ContinuousMove>';

  /// CAM2 drops the connection on Stop but obeys a zero-speed move, so that is
  /// the fallback.
  void stop() {
    _timer?.cancel();
    _send(
      '<tptz:Stop><tptz:ProfileToken>$_token</tptz:ProfileToken>'
      '<tptz:PanTilt>true</tptz:PanTilt><tptz:Zoom>false</tptz:Zoom></tptz:Stop>',
      fallback: _move(0, 0),
    );
  }

  void _send(String body, {String? fallback}) {
    final url = _url;
    if (url == null) return;
    _last = _last.then((_) async {
      try {
        await onvifSoap(cam, url, body);
      } catch (e) {
        debugPrint('ptz: $e');
        if (fallback == null) return;
        try {
          await onvifSoap(cam, url, fallback);
        } catch (e) {
          debugPrint('ptz fallback: $e');
        }
      }
    });
  }
}
