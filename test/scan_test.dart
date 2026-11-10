import 'package:flutter_test/flutter_test.dart';
import 'package:opencam/onvif.dart';
import 'package:opencam/scan.dart';

void main() {
  test('cellular, VPN and container interfaces are not swept', () {
    for (final n in ['rmnet_data0', 'docker0', 'br-1a2b', 'tun0', 'wg0']) {
      expect(isLanInterface(n), isFalse, reason: n);
    }
    for (final n in ['wlan0', 'eth0', 'enp3s0', 'wlp2s0']) {
      expect(isLanInterface(n), isTrue, reason: n);
    }
  });

  test('parses a WS-Discovery reply into ip, name and model', () {
    const xml =
        '<s:Envelope><s:Body><d:ProbeMatches><d:ProbeMatch>'
        '<d:Scopes>onvif://www.onvif.org/name/Front%20Door '
        'onvif://www.onvif.org/hardware/IPC-123</d:Scopes>'
        '<d:XAddrs>http://192.168.1.50:80/onvif/device_service</d:XAddrs>'
        '</d:ProbeMatch></d:ProbeMatches></s:Body></s:Envelope>';
    final f = parseProbeMatch(xml)!;
    expect(f.ip, '192.168.1.50');
    expect(f.name, 'Front Door');
    expect(f.hardware, 'IPC-123');
  });

  test('reads model and firmware from GetDeviceInformation', () {
    const xml =
        '<tds:Model>XM533_X3-WQ-B_8M</tds:Model>'
        '<tds:FirmwareVersion>V5.00.R02</tds:FirmwareVersion>';
    expect(infoTag(xml, 'Model'), 'XM533_X3-WQ-B_8M');
    expect(infoTag(xml, 'FirmwareVersion'), 'V5.00.R02');
    expect(infoTag('<html>404</html>', 'Model'), isNull);
  });

  test('ignores replies without XAddrs', () {
    expect(parseProbeMatch('<x/>'), isNull);
  });
}
