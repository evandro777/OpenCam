import 'package:flutter_test/flutter_test.dart';
import 'package:opencam/scan.dart';

void main() {
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

  test('reads the model from GetDeviceInformation', () {
    expect(
      parseModel('<tds:Model>XM533_X3-WQ-B_8M</tds:Model>'),
      'XM533_X3-WQ-B_8M',
    );
    expect(parseModel('<html>404</html>'), isNull);
  });

  test('ignores replies without XAddrs', () {
    expect(parseProbeMatch('<x/>'), isNull);
  });
}
