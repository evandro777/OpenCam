import 'package:flutter_test/flutter_test.dart';
import 'package:opencamera/ptz.dart';

void main() {
  test('WS-Security digest is base64(sha1(nonce + created + password))', () {
    final h = wsse(
      'admin',
      'secret',
      List.generate(16, (i) => i),
      '2026-01-01T00:00:00Z',
    );
    // Expected value computed with Python's hashlib (same formula as tools/onvif_probe.py).
    expect(h, contains('>Zp5M/ztyvf9G14qXDvS2VCbwotA=<'));
    expect(h, contains('<Username>admin</Username>'));
  });

  test('escapes the username', () {
    expect(wsse('a&b', 'x', [1], 'now'), contains('<Username>a&amp;b<'));
  });

  test('reads the first profile token', () {
    expect(
      parseProfileToken('<trt:Profiles fixed="true" token="Profile_1"><x/>'),
      'Profile_1',
    );
    expect(parseProfileToken('<html/>'), isNull);
  });
}
