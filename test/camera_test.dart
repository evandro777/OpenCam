import 'package:flutter_test/flutter_test.dart';
import 'package:opencamera/camera.dart';

void main() {
  test('special characters in credentials survive in the RTSP URL', () {
    const cam = Camera(
      name: 'c',
      host: '192.168.0.117',
      user: 'u@x',
      pass: 'p@:/#?%1',
      sd: false,
    );
    final uri = Uri.parse(cam.url());
    expect(uri.host, '192.168.0.117');
    expect(uri.port, 554);
    expect(uri.path, '/onvif1');
    final parts = uri.userInfo.split(':');
    expect(Uri.decodeComponent(parts[0]), 'u@x');
    expect(Uri.decodeComponent(parts[1]), 'p@:/#?%1');
  });

  test('xm + sd uses the vendor sub stream', () {
    const cam = Camera(
      name: 'c',
      host: '192.168.0.117',
      user: 'u@x',
      pass: 'p&=1',
      xm: true,
    );
    expect(
      cam.url(),
      'rtsp://192.168.0.117:554/user=u%40x&password=p%26%3D1'
      '&channel=1&stream=1.sdp?',
    );
  });

  test('sd off plays the main stream, non-xm sd uses /onvif2', () {
    const base = Camera(name: 'c', host: 'h', user: 'u', pass: 'p');
    expect(Uri.parse(base.copyWith(sd: false).url()).path, '/onvif1');
    expect(Uri.parse(base.copyWith(xm: false).url()).path, '/onvif2');
  });

  test('json round trip keeps flags', () {
    const cam = Camera(
      name: 'c',
      host: 'h',
      user: 'u',
      pass: 'p',
      udp: true,
      split: true,
      xm: true,
    );
    final back = Camera.fromJson(cam.toJson());
    expect(back.udp && back.split && back.xm, true);
  });
}
