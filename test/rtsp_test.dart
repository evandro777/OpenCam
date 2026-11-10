import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencam/camera.dart';
import 'package:opencam/rtsp.dart';

void main() {
  test('digestAuth matches an independent md5 computation', () {
    expect(
      digestAuth(
        'admin',
        'secret',
        'IP Camera',
        'abc123',
        'rtsp://192.168.0.5:554/onvif2',
      ),
      contains('response="9d3ad7645a2748849362b9ce362ea3ed"'),
    );
  });

  group('checkRtsp', () {
    late ServerSocket srv;
    // Fake camera like Yoosee: no vendor URL (404), /onvif2 wants Digest.
    setUp(() async {
      srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      var conns = 0;
      srv.listen((s) {
        // Like Yoosee: the nonce only works on the connection that got it.
        final nonce = 'n${conns++}';
        s.cast<List<int>>().transform(utf8.decoder).listen((req) {
          final uri = req.split(' ')[1];
          String reply(String status, [String extra = '']) =>
              'RTSP/1.0 $status\r\nCSeq: 1\r\n$extra\r\n';
          if (!uri.endsWith('/onvif2')) {
            s.write(reply('404 Not Found'));
          } else if (req.contains(
            digestAuth('admin', 'right', 'cam', nonce, uri),
          )) {
            s.write(reply('200 OK'));
          } else {
            s.write(
              reply(
                '401 Unauthorized',
                'WWW-Authenticate: Digest realm="cam", nonce="$nonce"\r\n',
              ),
            );
          }
        });
      });
    });
    tearDown(() => srv.close());

    Camera cam(String pass) =>
        Camera(name: 'c', host: '127.0.0.1', user: 'admin', pass: pass);

    test('right password -> true, wrong -> false', () async {
      expect(await checkRtsp(cam('right'), port: srv.port), true);
      expect(await checkRtsp(cam('wrong'), port: srv.port), false);
    });

    test('nothing listening -> null', () async {
      final port = srv.port;
      await srv.close();
      expect(await checkRtsp(cam('right'), port: port), isNull);
    });
  });
}
