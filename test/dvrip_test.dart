import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencam/camera.dart';
import 'package:opencam/dvrip.dart';
import 'package:opencam/fmt.dart';

/// [sec]: second field of the camera clock in an I-frame, 2026-11-06 04:10:SS.
Uint8List _frame(
  int type,
  List<int> payload, {
  int codec = 3,
  int fps = 12,
  int sec = 0,
}) {
  final n = payload.length;
  final t = ((26 << 26) | (11 << 22) | (6 << 17) | (4 << 12) | (10 << 6) | sec);
  final le = [t & 255, (t >> 8) & 255, (t >> 16) & 255, (t >> 24) & 255];
  final le32 = [n & 255, (n >> 8) & 255, (n >> 16) & 255, 0];
  return Uint8List.fromList([
    0,
    0,
    1,
    type,
    if (type == 0xfc) ...[0x50 | codec, fps, 0, 0, ...le, ...le32],
    if (type == 0xfd) ...le32,
    if (type == 0xf9 || type == 0xfa) ...[0, 0, n & 255, n >> 8],
    ...payload,
  ]);
}

void main() {
  test('sofiaHash matches python-dvr', () {
    expect(sofiaHash(''), 'tlJwpbo6');
    expect(sofiaHash('abc'), 'LkM7s2Ht');
  });

  test('XmDemux keeps only video, whatever the chunking', () {
    final data = [
      ..._frame(0xf9, List.filled(8, 0)),
      ..._frame(0xfc, [0, 0, 0, 1, 0x40, 1]),
      ..._frame(0xfa, [9, 9, 9]),
      ..._frame(0xfd, [0, 0, 0, 1, 0x02]),
      ..._frame(0xfc, [0, 0, 0, 1, 0x40, 2], sec: 3),
    ];
    const want = [0, 0, 0, 1, 0x40, 1, 0, 0, 0, 1, 0x02, 0, 0, 0, 1, 0x40, 2];
    for (final step in [1, 3, 7, data.length]) {
      final d = XmDemux();
      final got = <int>[];
      for (var i = 0; i < data.length; i += step) {
        got.addAll(d.add(data.sublist(i, (i + step).clamp(0, data.length))));
      }
      expect(got, want, reason: 'chunk size $step');
      expect(d.codec, 'hevc');
      expect(d.fps, 12);
      // Seeking restarts the stream at these: byte offset in the output, frame no.
      expect(d.frames, 3);
      final t0 =
          DateTime.utc(2026, 11, 6, 4, 10).millisecondsSinceEpoch ~/ 1000;
      expect(d.iframes, [
        (offset: 0, frame: 0, ts: t0),
        (offset: 11, frame: 2, ts: t0 + 3),
      ]);
    }
  });

  test('clockOffset moves a phone time onto the camera clock', () {
    final phone = DateTime(2026, 11, 9, 22, 30);
    final camera = DateTime(2026, 11, 10, 6, 30, 7); // 8 h ahead, past midnight
    final off = clockOffset(camera, phone);
    expect(off, const Duration(hours: 8, seconds: 7));
    expect(phone.add(off).day, 10);
    expect(clockOffset(DateTime(2026, 11, 9, 20), phone).isNegative, isTrue);
  });

  test('clipAt finds the clip at a time, or the next one within 2 min', () {
    Clip c(String b, String e) => (name: b, begin: b, end: e, motion: true);
    final clips = [
      c('2026-11-09 10:00:00', '2026-11-09 10:05:00'),
      c('2026-11-09 10:10:00', '2026-11-09 10:15:00'),
    ];
    Clip? at(String t) => clipAt(clips, DateTime.parse(t));
    expect(at('2026-11-09 10:02:00'), clips[0]);
    expect(at('2026-11-09 10:10:00'), clips[1]); // begin is inside
    expect(at('2026-11-09 10:08:30'), clips[1]); // 90 s before it starts
    expect(
      at('2026-11-09 10:05:00'),
      isNull,
    ); // end is outside, next is 5 min on
    expect(at('2026-11-09 10:07:00'), isNull); // 3 min before the next clip
    expect(at('2026-11-09 11:00:00'), isNull);
  });

  group('Dvrip over a fake camera', () {
    late ServerSocket srv;
    final begins = <String>[]; // BeginTime of every OPFileQuery received
    String t(int i) => '2026-11-09 ${two(i ~/ 60)}:${two(i % 60)}:00';
    Map<String, dynamic> clip(int i) => {
      'FileName': '/idea0/$i.h264',
      'BeginTime': t(i),
      'EndTime': t(i + 1),
    };

    // Answers the login, then 64 clips, then the boundary clip again plus 2.
    setUp(() async {
      begins.clear();
      srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      srv.listen((s) {
        var buf = <int>[];
        s.listen((chunk) {
          buf = [...buf, ...chunk];
          while (buf.length >= 20) {
            final len = ByteData.sublistView(Uint8List.fromList(buf))
                .getUint32(16, Endian.little);
            if (buf.length < 20 + len) return;
            final body = jsonDecode(
              utf8.decode(buf.sublist(20, 20 + len - 2)),
            ) as Map<String, dynamic>;
            buf = buf.sublist(20 + len);
            final Map<String, dynamic> reply;
            if (body['UserName'] != null) {
              reply = {'Ret': 100, 'SessionID': '0x00000001'};
            } else {
              final b = (body['OPFileQuery'] as Map)['BeginTime'] as String;
              begins.add(b);
              reply = {
                'Ret': 100,
                'OPFileQuery': [
                  if (begins.length == 1)
                    for (var i = 0; i < 64; i++) clip(i),
                  if (begins.length == 2)
                    for (var i = 63; i < 66; i++) clip(i),
                ],
              };
            }
            final json = [...utf8.encode(jsonEncode(reply)), 0x0a, 0x00];
            final h = ByteData(20)
              ..setUint8(0, 0xff)
              ..setUint32(16, json.length, Endian.little);
            s.add([...h.buffer.asUint8List(), ...json]);
          }
        });
      });
    });
    tearDown(() => srv.close());

    Camera cam() =>
        const Camera(name: 'c', host: '127.0.0.1', user: 'admin', pass: 'x');

    test('clips() pages by 64 and drops the repeated boundary clip', () async {
      final d = await Dvrip.open(cam(), port: srv.port);
      final clips = await d.clips(DateTime(2026, 11, 9));
      d.close();
      expect(clips, hasLength(66));
      expect(clips.map((c) => c.name).toSet(), hasLength(66));
      expect(clips.last.name, '/idea0/65.h264');
      // The second question starts at the last clip of the first answer.
      expect(begins, ['2026-11-09 00:00:00', t(63)]);
    });
  });
}
