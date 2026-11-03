import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A device found on the network. [name]/[hardware] only come from ONVIF.
class Found {
  Found(this.ip, {this.name, this.hardware, this.rtsp = false});
  final String ip;
  String? name, hardware;
  bool rtsp;

  String get label => [
    ip,
    ?name,
    if (hardware != null && hardware != name) hardware!,
    if (!rtsp) 'no RTSP on 554',
  ].join(' · ');
}

/// Finds cameras on the local /24 network(s): ONVIF WS-Discovery (gives name
/// and model) merged with a TCP probe of the RTSP port (finds the non-ONVIF
/// ones). shortcut: /24 only and port 554 only (the app always uses 554),
/// upgrade for other subnets or ports.
Future<List<Found>> scanCameras() async {
  final addrs = [
    for (final n in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    ))
      for (final a in n.addresses) a.address,
  ];
  final byIp = <String, Found>{};
  Found at(String ip) => byIp.putIfAbsent(ip, () => Found(ip));

  final onvif = [for (final a in addrs) _discoverOnvif(a)];
  final prefixes = {for (final a in addrs) a.substring(0, a.lastIndexOf('.'))};
  final probes = [
    for (final p in prefixes)
      for (var i = 1; i < 255; i++) _probe('$p.$i'),
  ];

  for (final ip in await Future.wait(probes)) {
    if (ip != null) at(ip).rtsp = true;
  }
  for (final list in await Future.wait(onvif)) {
    for (final m in list) {
      final f = at(m.ip);
      f.name ??= m.name;
      f.hardware ??= m.hardware;
    }
  }
  // Cameras that ignore WS-Discovery (Xiongmai, Yoosee) still answer an
  // unauthenticated ONVIF GetDeviceInformation on their own port.
  await Future.wait([
    for (final f in byIp.values)
      if (f.rtsp && f.hardware == null)
        _deviceModel(f.ip).then((m) => f.hardware = m),
  ]);
  return byIp.values.toList()..sort((a, b) => _num(a.ip).compareTo(_num(b.ip)));
}

int _num(String ip) => ip.split('.').fold(0, (n, p) => n * 256 + int.parse(p));

Future<String?> _probe(String ip) async {
  try {
    final s = await Socket.connect(
      ip,
      554,
      timeout: const Duration(milliseconds: 800),
    );
    s.destroy();
    return ip;
  } catch (_) {
    return null; // closed, unreachable or timed out
  }
}

const _probeXml =
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" '
    'xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" '
    'xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" '
    'xmlns:dn="http://www.onvif.org/ver10/network/wsdl"><e:Header>'
    '<w:MessageID>uuid:6f1c3a52-0d1e-4b8e-9a53-1f2e3d4c5b6a</w:MessageID>'
    '<w:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>'
    '<w:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>'
    '</e:Header><e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types>'
    '</d:Probe></e:Body></e:Envelope>';

/// Multicast probe sent from one local address; replies come back unicast.
Future<List<Found>> _discoverOnvif(String local) async {
  final out = <Found>[];
  RawDatagramSocket? sock;
  try {
    sock = await RawDatagramSocket.bind(local, 0);
    sock.listen((e) {
      final d = e == RawSocketEvent.read ? sock!.receive() : null;
      final m = d == null
          ? null
          : parseProbeMatch(utf8.decode(d.data, allowMalformed: true));
      if (m != null) out.add(m);
    });
    sock.send(utf8.encode(_probeXml), InternetAddress('239.255.255.250'), 3702);
    await Future<void>.delayed(const Duration(seconds: 2));
  } catch (_) {
    // no multicast on this interface: the port probe still covers it
  } finally {
    sock?.close();
  }
  return out;
}

const _infoXml =
    '<?xml version="1.0"?><s:Envelope '
    'xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body>'
    '<GetDeviceInformation xmlns="http://www.onvif.org/ver10/device/wsdl"/>'
    '</s:Body></s:Envelope>';

/// ONVIF model of [ip]: first of the usual ONVIF ports that answers.
/// shortcut: fixed port list, upgrade when a camera uses another one.
Future<String?> _deviceModel(String ip) async {
  final r = await Future.wait([
    for (final p in [8899, 5000, 80, 8000, 8080]) _modelAt(ip, p),
  ]);
  return r.nonNulls.firstOrNull;
}

Future<String?> _modelAt(String ip, int port) async {
  final c = HttpClient()..connectionTimeout = const Duration(milliseconds: 800);
  try {
    final req = await c.post(ip, port, '/onvif/device_service');
    req.headers.contentType = ContentType('application', 'soap+xml');
    // Xiongmai's HTTP server rejects Dart's default chunked body.
    final body = utf8.encode(_infoXml);
    req.contentLength = body.length;
    req.add(body);
    final res = await req.close().timeout(const Duration(seconds: 3));
    return parseModel(await res.transform(utf8.decoder).join());
  } catch (_) {
    return null; // closed, not ONVIF, or wants credentials
  } finally {
    c.close(force: true);
  }
}

String? parseModel(String xml) =>
    RegExp(r'<(?:\w+:)?Model>([^<]+)<').firstMatch(xml)?.group(1);

/// The device's IP, name and model from a WS-Discovery ProbeMatches reply.
Found? parseProbeMatch(String xml) {
  final xaddrs = RegExp(r'<[\w:]*XAddrs>([^<]*)<').firstMatch(xml)?.group(1);
  final host = xaddrs == null
      ? null
      : Uri.tryParse(xaddrs.trim().split(RegExp(r'\s+')).first)?.host;
  if (host == null || host.isEmpty) return null;
  final scopes =
      RegExp(r'<[\w:]*Scopes>([^<]*)<').firstMatch(xml)?.group(1) ?? '';
  String? scope(String key) {
    final m = RegExp('onvif://www.onvif.org/$key/(\\S+)').firstMatch(scopes);
    return m == null ? null : Uri.decodeComponent(m.group(1)!);
  }

  return Found(host, name: scope('name'), hardware: scope('hardware'));
}
