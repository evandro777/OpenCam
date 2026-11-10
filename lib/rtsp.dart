import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'camera.dart';

/// RFC 2617 Digest header (no qop, which is what IP cameras use).
String digestAuth(
  String user,
  String pass,
  String realm,
  String nonce,
  String uri,
) {
  String h(String s) => md5.convert(utf8.encode(s)).toString();
  final r = h('${h('$user:$realm:$pass')}:$nonce:${h('DESCRIBE:$uri')}');
  return 'Digest username="$user", realm="$realm", nonce="$nonce", '
      'uri="$uri", response="$r"';
}

/// DESCRIBE [uri], answering a Digest/Basic challenge on the SAME connection
/// (Yoosee ties the nonce to it and replies 400 on a new one). Returns the
/// final status, or null if the camera did not answer.
/// shortcut: response bodies are not skipped; fine while a 401 has none.
Future<int?> _describe(Camera cam, int port, String uri) async {
  Socket? s;
  try {
    s = await Socket.connect(
      cam.host,
      port,
      timeout: const Duration(seconds: 3),
    );
    final it = StreamIterator(
      s.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)),
    );
    var buf = '';
    Future<String> head(String auth) async {
      s!.write(
        'DESCRIBE $uri RTSP/1.0\r\nCSeq: ${auth.isEmpty ? 1 : 2}\r\n'
        'Accept: application/sdp\r\n'
        '${auth.isEmpty ? '' : 'Authorization: $auth\r\n'}\r\n',
      );
      while (!buf.contains('\r\n\r\n')) {
        if (!await it.moveNext()) return buf; // closed
        buf += it.current;
      }
      final h = buf.substring(0, buf.indexOf('\r\n\r\n') + 4);
      buf = buf.substring(h.length);
      return h;
    }

    int? status(String h) => int.tryParse(
      RegExp(r'^RTSP/1\.\d (\d+)').firstMatch(h)?.group(1) ?? '',
    );

    return await (() async {
      final first = await head('');
      final code = status(first);
      final m = code == 401
          ? RegExp(
              r'WWW-Authenticate:\s*(Digest|Basic)([^\r\n]*)',
              caseSensitive: false,
            ).firstMatch(first)
          : null;
      if (m == null) return code;
      String? field(String k) =>
          RegExp('$k="([^"]*)"').firstMatch(m.group(2)!)?.group(1);
      return status(
        await head(
          m.group(1)!.toLowerCase() == 'basic'
              ? 'Basic ${base64.encode(utf8.encode('${cam.user}:${cam.pass}'))}'
              : digestAuth(
                  cam.user,
                  cam.pass,
                  field('realm') ?? '',
                  field('nonce') ?? '',
                  uri,
                ),
        ),
      );
    })().timeout(const Duration(seconds: 6));
  } catch (_) {
    return null;
  } finally {
    s?.destroy();
  }
}

/// Does the stream accept [cam]'s user and password? Asks for the same URLs
/// the player uses (the vendor sub stream, else /onvif2) and wants a 200.
/// true = a stream opened, false = the camera answered but never allowed it,
/// null = nothing on the RTSP port.
Future<bool?> checkRtsp(Camera cam, {int port = 554}) async {
  var reached = false;
  for (final c in [
    cam.copyWith(sd: true, xm: true),
    cam.copyWith(sd: true, xm: false),
  ]) {
    final u = Uri.parse(c.url()).replace(port: port);
    // The login travels in a header, not in the request line.
    final uri = u.userInfo.isNotEmpty
        ? Uri(
            scheme: u.scheme,
            host: u.host,
            port: u.port,
            path: u.path,
          ).toString()
        : u.toString();
    final code = await _describe(cam, port, uri);
    if (code == null) continue;
    reached = true;
    if (code == 200) return true;
  }
  return reached ? false : null;
}

/// Does [host] answer on port 34567 (DVRIP)? Only Xiongmai / iCSee cameras do:
/// they get the vendor sub-stream URL, whose failure must not be taken for
/// "not an iCSee camera".
Future<bool> hasDvrip(String host) async {
  try {
    (await Socket.connect(
      host,
      34567,
      timeout: const Duration(seconds: 2),
    )).destroy();
    return true;
  } on Exception {
    return false;
  }
}
