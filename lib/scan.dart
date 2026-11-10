import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'camera.dart';
import 'onvif.dart';

/// A device found on the network. [name]/[hardware] only come from ONVIF.
class Found {
  Found(this.ip, {this.name, this.hardware, this.rtsp = false});
  final String ip;
  String? name, hardware, firmware;
  bool rtsp;
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
      if (isLanInterface(n.name))
        for (final a in n.addresses) a.address,
  ];
  final byIp = <String, Found>{};
  Found at(String ip) => byIp.putIfAbsent(ip, () => Found(ip));

  final onvif = [for (final a in addrs) _discoverOnvif(a)];
  final prefixes = {for (final a in addrs) a.substring(0, a.lastIndexOf('.'))};
  // Two sweeps: a connect to a host whose ARP entry or Wi-Fi radio is asleep
  // can time out the first time, so the second sweep retries the misses.
  for (var pass = 0; pass < 2; pass++) {
    final todo = [
      for (final p in prefixes)
        for (var i = 1; i < 255; i++)
          if (byIp['$p.$i']?.rtsp != true) '$p.$i',
    ];
    // Batches: hundreds of sockets at once can hit the open-file limit, and a
    // failed connect would read as "closed".
    for (var i = 0; i < todo.length; i += 64) {
      final batch = todo.skip(i).take(64);
      for (final ip in await Future.wait([for (final a in batch) _probe(a)])) {
        if (ip != null) at(ip).rtsp = true;
      }
    }
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
        _deviceInfo(f.ip).then((x) {
          if (x == null) return;
          f.hardware = infoTag(x, 'Model');
          f.firmware = infoTag(x, 'FirmwareVersion');
        }),
  ]);
  return byIp.values.toList()..sort((a, b) => _num(a.ip).compareTo(_num(b.ip)));
}

/// False for cellular, VPN, container and virtual networks: a camera is not
/// there, and sweeping a carrier's range is slow and rude. Judged by name
/// (not by address range: carriers use 10/8, Docker sits in 172.16/12).
bool isLanInterface(String name) => !RegExp(
  r'^(v4-|rmnet|ccmni|pdp|docker|br-|veth|virbr|vbox|vmnet|tun|tap|wg|ppp|tailscale|zt)',
  caseSensitive: false,
).hasMatch(name);

int _num(String ip) => ip.split('.').fold(0, (n, p) => n * 256 + int.parse(p));

Future<String?> _probe(String ip) async {
  try {
    final s = await Socket.connect(
      ip,
      554,
      timeout: const Duration(milliseconds: 1500),
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

/// GetDeviceInformation reply of [ip]: first of the usual ONVIF ports that answers.
/// shortcut: fixed port list, upgrade when a camera uses another one.
Future<String?> _deviceInfo(String ip) async {
  final anon = Camera(name: '', host: ip, user: '', pass: '');
  // A port that is closed, not ONVIF, or wants credentials counts as no answer.
  return firstOnvif<String>((p) async {
    final x = await onvifSoap(
      anon,
      'http://$ip:$p/onvif/device_service',
      '<tds:GetDeviceInformation/>',
      auth: false,
    );
    return infoTag(x, 'Model') == null ? null : x;
  });
}

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
