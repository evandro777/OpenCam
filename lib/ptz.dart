import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'camera.dart';

const _ns =
    'xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
    'xmlns:tds="http://www.onvif.org/ver10/device/wsdl" '
    'xmlns:trt="http://www.onvif.org/ver10/media/wsdl" '
    'xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl" '
    'xmlns:tt="http://www.onvif.org/ver10/schema"';

/// WS-Security UsernameToken header (password digest) for one ONVIF request.
String wsse(String user, String pass, List<int> nonce, String created) {
  final digest = base64.encode(
    sha1.convert([
      ...nonce,
      ...utf8.encode(created),
      ...utf8.encode(pass),
    ]).bytes,
  );
  final u = user
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  return '<Security xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">'
      '<UsernameToken><Username>$u</Username>'
      '<Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">$digest</Password>'
      '<Nonce>${base64.encode(nonce)}</Nonce>'
      '<Created xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">$created</Created>'
      '</UsernameToken></Security>';
}

String? parseProfileToken(String xml) =>
    RegExp(r'<(?:\w+:)?Profiles[^>]*token="([^"]+)"').firstMatch(xml)?.group(1);

/// ONVIF pan/tilt for one camera. Everything goes through one queue so a
/// quick tap's Stop can never overtake its ContinuousMove.
class Ptz {
  Ptz(this.cam);
  final Camera cam;

  /// Ports tried for ONVIF, same list as the scanner.
  static const _ports = [8899, 5000, 80, 8000, 8080];

  String? _url, _token;
  Future<void> _last = Future.value();
  Timer? _timer;

  /// True if the camera has an ONVIF PTZ service. shortcut: re-detected on
  /// every fullscreen open, upgrade by storing the port if that is slow.
  Future<bool> connect() async {
    final found = await Future.wait([for (final p in _ports) _tryPort(p)]);
    final hit = found.nonNulls.firstOrNull;
    _url = hit?.$1;
    _token = hit?.$2;
    return hit != null;
  }

  Future<(String, String)?> _tryPort(int port) async {
    try {
      final base = 'http://${cam.host}:$port/onvif/device_service';
      final caps = await _soap(
        base,
        '<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>',
      );
      // The camera may advertise another address: keep the path, reuse ours.
      final urls = [
        for (final m in RegExp(r'<(?:\w+:)?XAddr>([^<]+)<').allMatches(caps))
          m.group(1)!.replaceFirst(RegExp(r'//[^/]+'), '//${cam.host}:$port'),
      ];
      final media = urls.firstWhere((u) => u.toLowerCase().contains('media'));
      final ptz = urls.firstWhere((u) => u.toLowerCase().contains('ptz'));
      // GetNodes is not asked: CAM2 (Yoosee) drops it but moves fine. A profile
      // with a PTZ configuration is the sign of a PTZ camera.
      final profiles = await _soap(media, '<trt:GetProfiles/>');
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
        await _soap(url, body);
      } catch (e) {
        debugPrint('ptz: $e');
        if (fallback == null) return;
        try {
          await _soap(url, fallback);
        } catch (e) {
          debugPrint('ptz fallback: $e');
        }
      }
    });
  }

  Future<String> _soap(String url, String body) async {
    final rnd = Random.secure();
    final nonce = [for (var i = 0; i < 16; i++) rnd.nextInt(256)];
    final created =
        '${DateTime.now().toUtc().toIso8601String().split('.').first}Z';
    final xml =
        '<?xml version="1.0"?><s:Envelope $_ns><s:Header>'
        '${wsse(cam.user, cam.pass, nonce, created)}'
        '</s:Header><s:Body>$body</s:Body></s:Envelope>';
    final c = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 800);
    try {
      final req = await c.postUrl(Uri.parse(url));
      req.headers.contentType = ContentType('application', 'soap+xml');
      // Xiongmai's HTTP server rejects Dart's default chunked body.
      final bytes = utf8.encode(xml);
      req.contentLength = bytes.length;
      req.add(bytes);
      final res = await req.close().timeout(const Duration(seconds: 3));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200 || text.contains('Fault')) {
        throw HttpException('HTTP ${res.statusCode} $url');
      }
      return text;
    } finally {
      c.close(force: true);
    }
  }
}
