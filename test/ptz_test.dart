import 'package:flutter_test/flutter_test.dart';
import 'package:opencam/camera.dart';
import 'package:opencam/onvif.dart';
import 'package:opencam/ptz.dart';
import 'package:opencam/stream_export.dart';

void main() {
  test('maskPass hides only the password, even a one-digit one', () {
    final c = const Camera(
      name: 'c',
      host: '192.168.1.10',
      user: 'admin',
      pass: '1',
    );
    expect(
      maskPass(c.url()),
      'rtsp://192.168.1.10:554/user=admin&password=•••&channel=1&stream=1.sdp?',
    );
    expect(
      maskPass(c.copyWith(sd: false).url()),
      'rtsp://admin:•••@192.168.1.10:554/onvif1',
    );
  });

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

  test('parseProfiles gives one row per profile', () {
    const xml =
        '<trt:Profiles token="p1" fixed="true"><tt:Name>mainStream</tt:Name>'
        '<tt:VideoEncoderConfiguration><tt:Encoding>H264</tt:Encoding>'
        '<tt:Resolution><tt:Width>1920</tt:Width><tt:Height>1080</tt:Height>'
        '</tt:Resolution><tt:RateControl><tt:FrameRateLimit>25</tt:FrameRateLimit>'
        '<tt:BitrateLimit>2048</tt:BitrateLimit></tt:RateControl>'
        '<tt:H264><tt:GovLength>50</tt:GovLength></tt:H264>'
        '</tt:VideoEncoderConfiguration></trt:Profiles>'
        '<trt:Profiles token="p2"><tt:Name>subStream</tt:Name>'
        '<tt:Encoding>H264</tt:Encoding></trt:Profiles>';
    expect(parseProfiles(xml), [
      ('Stream mainStream', 'H264 · 1920×1080 · 25 fps · 2048 kbps · GOP 50'),
      ('Stream subStream', 'H264'),
    ]);
  });

  test('streamUrl puts the credentials into the camera URI', () {
    const cam = Camera(name: 'c', host: 'h', user: 'a', pass: 'p@ss');
    expect(
      streamUrl(cam, 'rtsp://h:554/onvif1'),
      'rtsp://a:p%40ss@h:554/onvif1',
    );
    expect(
      streamUrl(
        cam,
        'rtsp://h:554/user=x&amp;password=&amp;channel=1&amp;stream=0.sdp?',
      ),
      'rtsp://h:554/user=a&password=p%40ss&channel=1&stream=0.sdp?',
    );
  });

  test('playCommand quotes the URL and follows the transport', () {
    const tcp = Camera(name: 'c', host: 'h', user: 'a', pass: 'p');
    final udp = tcp.copyWith(udp: true);
    expect(
      playCommand(tcp, 'rtsp://h/x&y', 'mpv'),
      "mpv --rtsp-transport=tcp 'rtsp://h/x&y'",
    );
    expect(
      playCommand(udp, 'rtsp://h/x', 'ffplay'),
      "ffplay -rtsp_transport udp 'rtsp://h/x'",
    );
    expect(
      playCommand(tcp, 'rtsp://h/x', 'VLC'),
      "vlc --rtsp-tcp 'rtsp://h/x'",
    );
    expect(playCommand(udp, 'rtsp://h/x', 'VLC'), "vlc 'rtsp://h/x'");
    expect(
      playCommand(tcp, "rtsp://h/it's", 'mpv'),
      contains(r"'rtsp://h/it'\''s'"),
    );
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
