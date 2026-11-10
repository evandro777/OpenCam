import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'camera.dart';
import 'stream_export.dart' show streamUrl;

/// Ports tried for ONVIF, by the scanner, PTZ, events and camera info.
const onvifPorts = [8899, 5000, 80, 8000, 8080];

/// Runs [f] on every ONVIF port at once; the first non-null answer, in port
/// order. A port whose call throws (closed, not ONVIF, wrong login) counts as
/// no answer.
Future<T?> firstOnvif<T extends Object>(
  Future<T?> Function(int port) f,
) async => (await Future.wait([
  for (final p in onvifPorts) f(p).then<T?>((v) => v, onError: (_) => null),
])).nonNulls.firstOrNull;

const _ns =
    'xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
    'xmlns:tds="http://www.onvif.org/ver10/device/wsdl" '
    'xmlns:trt="http://www.onvif.org/ver10/media/wsdl" '
    'xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl" '
    'xmlns:tev="http://www.onvif.org/ver10/events/wsdl" '
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

String? infoTag(String xml, String tag) =>
    RegExp('<(?:\\w+:)?$tag>([^<]+)<').firstMatch(xml)?.group(1);

/// Service URLs the camera advertises on ONVIF [port].
Future<List<String>> onvifServices(Camera cam, int port) async {
  final caps = await onvifSoap(
    cam,
    'http://${cam.host}:$port/onvif/device_service',
    '<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>',
  );
  // The camera may advertise another address: keep the path, reuse ours.
  return [
    for (final m in RegExp(r'<(?:\w+:)?XAddr>([^<]+)<').allMatches(caps))
      m.group(1)!.replaceFirst(RegExp(r'//[^/]+'), '//${cam.host}:$port'),
  ];
}

/// One ONVIF request; throws on a non-200 reply or a Fault. [auth] false sends
/// no login header (the unauthenticated GetDeviceInformation of the scanner).
Future<String> onvifSoap(
  Camera cam,
  String url,
  String body, {
  Duration timeout = const Duration(seconds: 3),
  bool auth = true,
}) async {
  final rnd = Random.secure();
  final nonce = [for (var i = 0; i < 16; i++) rnd.nextInt(256)];
  final created =
      '${DateTime.now().toUtc().toIso8601String().split('.').first}Z';
  // No Header element at all without login: some servers are picky.
  final header = auth
      ? '<s:Header>${wsse(cam.user, cam.pass, nonce, created)}</s:Header>'
      : '';
  final xml =
      '<?xml version="1.0"?><s:Envelope $_ns>$header'
      '<s:Body>$body</s:Body></s:Envelope>';
  final c = HttpClient()..connectionTimeout = const Duration(milliseconds: 800);
  try {
    final req = await c.postUrl(Uri.parse(url));
    req.headers.contentType = ContentType('application', 'soap+xml');
    // Xiongmai's HTTP server rejects Dart's default chunked body.
    final bytes = utf8.encode(xml);
    req.contentLength = bytes.length;
    req.add(bytes);
    final res = await req.close().timeout(timeout);
    final text = await res.transform(utf8.decoder).join().timeout(timeout);
    if (res.statusCode != 200 || text.contains('Fault')) {
      throw HttpException('HTTP ${res.statusCode} $url');
    }
    return text;
  } finally {
    c.close(force: true);
  }
}

/// One row per ONVIF media profile: codec, size, fps, bitrate, GOP.
List<(String, String)> parseProfiles(String xml) {
  String? tag(String s, String t) => infoTag(s, t);
  return [
    for (final p in xml.split(RegExp(r'<(?:\w+:)?Profiles\s')).skip(1))
      (
        'Stream ${RegExp('<(?:\\w+:)?Name>([^<]+)<').firstMatch(p)?.group(1) ?? ''}'
            .trim(),
        [
          tag(p, 'Encoding'),
          if (tag(p, 'Width') != null && tag(p, 'Height') != null)
            '${tag(p, 'Width')}×${tag(p, 'Height')}',
          if (tag(p, 'FrameRateLimit') != null)
            '${tag(p, 'FrameRateLimit')} fps',
          if (tag(p, 'BitrateLimit') != null) '${tag(p, 'BitrateLimit')} kbps',
          if (tag(p, 'GovLength') != null) 'GOP ${tag(p, 'GovLength')}',
        ].nonNulls.join(' · '),
      ),
  ];
}

/// Info rows, plus the playable streams as (profile name, URL with login).
typedef OnvifInfo = ({
  List<(String, String)> rows,
  List<(String, String)> streams,
});

/// Everything ONVIF tells about [cam] (needs the camera password). Parts the
/// camera refuses are left out.
Future<OnvifInfo> onvifInfo(Camera cam) async {
  final hit = await firstOnvif<(int, String)>(
    (p) async => (
      p,
      await onvifSoap(
        cam,
        'http://${cam.host}:$p/onvif/device_service',
        '<tds:GetDeviceInformation/>',
      ),
    ),
  );
  if (hit == null) {
    return (
      rows: [('ONVIF', 'no answer or wrong password')],
      streams: <(String, String)>[],
    );
  }
  final streams = <(String, String)>[];
  final (port, info) = hit;
  final out = <(String, String)>[
    for (final (label, tag) in const [
      ('Manufacturer', 'Manufacturer'),
      ('Model', 'Model'),
      ('Firmware', 'FirmwareVersion'),
      ('Serial', 'SerialNumber'),
      ('Hardware ID', 'HardwareId'),
    ])
      if (infoTag(info, tag) case final v?) (label, v),
  ];
  try {
    final net = await onvifSoap(
      cam,
      'http://${cam.host}:$port/onvif/device_service',
      '<tds:GetNetworkInterfaces/>',
    );
    if (infoTag(net, 'HwAddress') case final v?) out.add(('MAC', v));
    if (infoTag(net, 'DHCP') case final v?) out.add(('DHCP', v));
  } catch (_) {}
  try {
    final media = (await onvifServices(
      cam,
      port,
    )).firstWhere((u) => u.toLowerCase().contains('media'));
    final xml = await onvifSoap(cam, media, '<trt:GetProfiles/>');
    final tokens = [
      for (final m in RegExp(
        r'<(?:\w+:)?Profiles[^>]*token="([^"]+)"',
      ).allMatches(xml))
        m.group(1)!,
    ];
    final rows = parseProfiles(xml); // same order as [tokens]
    for (var i = 0; i < rows.length; i++) {
      out.add(rows[i]);
      if (i >= tokens.length) continue;
      try {
        final reply = await onvifSoap(
          cam,
          media,
          '<trt:GetStreamUri><trt:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream>'
          '<tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport>'
          '</trt:StreamSetup><trt:ProfileToken>${tokens[i]}</trt:ProfileToken>'
          '</trt:GetStreamUri>',
        );
        if (infoTag(reply, 'Uri') case final uri?) {
          // Name + codec, so a JPEG snapshot profile is recognisable.
          final codec = rows[i].$2.split(' · ').first;
          streams.add((
            '${rows[i].$1.replaceFirst('Stream ', '')} ($codec)',
            streamUrl(cam, uri),
          ));
        }
      } catch (_) {} // this profile has no URI: keep its info row only
    }
  } catch (_) {}
  return (rows: out, streams: streams);
}
