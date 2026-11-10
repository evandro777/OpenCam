import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'camera.dart';
import 'fmt.dart';

/// One recording on the camera's SD card. Times are the camera's own clock.
typedef Clip = ({String name, String begin, String end, bool motion});

/// The clip that was recording at [t] (local time, like the camera's clock),
/// else the first one starting within 2 min after it: an alert can come just
/// before its clip opens. null = nothing recorded there.
Clip? clipAt(List<Clip> clips, DateTime t) {
  Clip? next;
  for (final c in clips) {
    final b = DateTime.parse(c.begin);
    if (!t.isBefore(b) && t.isBefore(DateTime.parse(c.end))) return c;
    if (b.isAfter(t) &&
        b.difference(t) <= const Duration(minutes: 2) &&
        (next == null || b.isBefore(DateTime.parse(next.begin)))) {
      next = c;
    }
  }
  return next;
}

/// How far the camera's clock is ahead of the phone's (negative = behind),
/// whole seconds: a phone moment + this = the same moment on the camera's
/// clock, where its clips are named.
Duration clockOffset(DateTime camera, DateTime phone) =>
    Duration(seconds: camera.difference(phone).inSeconds);

/// Xiongmai "sofia" password hash: MD5, then each byte pair summed into
/// 62 letters/digits.
String sofiaHash(String pass) {
  const chars =
      '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  final d = md5.convert(utf8.encode(pass)).bytes;
  return String.fromCharCodes([
    for (var i = 0; i < d.length; i += 2)
      chars.codeUnitAt((d[i] + d[i + 1]) % 62),
  ]);
}

/// The camera answered the DVRIP login but refused it. Trying again only
/// risks locking the IP (code 205), so callers stop until something changes.
class LoginRefused implements Exception {
  LoginRefused(this.message);
  final String message;

  @override
  String toString() => message;
}

/// DVRIP (port 34567) session of Xiongmai / iCSee cameras, enough to list and
/// download SD-card recordings. One connection per operation: no keep-alive.
class Dvrip {
  Dvrip._(this._sock) {
    _sock.listen(
      _onData,
      onDone: _pk.close,
      onError: (Object e) {
        _pk.addError(e);
        _pk.close();
      },
    );
  }

  final Socket _sock;
  final _pk = StreamController<(int, Uint8List)>();
  late final _it = StreamIterator(_pk.stream);
  Uint8List _b = Uint8List(0);
  int _session = 0, _seq = 0;

  /// Connects and logs in; throws a readable message on failure, and a
  /// [LoginRefused] when the camera answered but did not accept the login.
  static Future<Dvrip> open(Camera cam, {int port = 34567}) async {
    final Socket s;
    try {
      s = await Socket.connect(
        cam.host,
        port,
        timeout: const Duration(seconds: 4),
      );
    } on Exception {
      throw 'No recordings access: port 34567 is closed (not an iCSee camera?)';
    }
    final d = Dvrip._(s);
    try {
      final r = await d._call(1000, {
        'EncryptType': 'MD5',
        'LoginType': 'DVRIP-Web',
        'PassWord': sofiaHash(cam.pass),
        'UserName': cam.user,
      });
      final ret = r['Ret'];
      if (ret != 100 && ret != 515) {
        throw LoginRefused(switch (ret) {
          205 =>
            'The camera locked this IP (login code 205). Set a password '
                'on the camera and use it here.',
          203 => 'Wrong password for the camera (login code 203).',
          _ => 'Login refused (code $ret).',
        });
      }
      d._session = int.parse(r['SessionID'] as String);
      return d;
    } catch (_) {
      d.close();
      rethrow;
    }
  }

  void close() => _sock.destroy();

  void _onData(Uint8List chunk) {
    _b =
        (BytesBuilder(copy: false)
              ..add(_b)
              ..add(chunk))
            .takeBytes();
    while (_b.length >= 20) {
      final h = ByteData.sublistView(_b);
      final len = h.getUint32(16, Endian.little);
      if (_b.length < 20 + len) return;
      _pk.add((
        h.getUint16(14, Endian.little),
        Uint8List.sublistView(_b, 20, 20 + len),
      ));
      _b = Uint8List.sublistView(_b, 20 + len);
    }
  }

  void _send(int msg, Map<String, dynamic> body) {
    if (_session != 0) {
      body['SessionID'] = '0x${_session.toRadixString(16).padLeft(8, '0')}';
    }
    final json = [...utf8.encode(jsonEncode(body)), 0x0a, 0x00];
    final h = ByteData(20)
      ..setUint8(0, 0xff)
      ..setUint32(4, _session, Endian.little)
      ..setUint32(8, _seq++, Endian.little)
      ..setUint16(14, msg, Endian.little)
      ..setUint32(16, json.length, Endian.little);
    _sock.add([...h.buffer.asUint8List(), ...json]);
  }

  Future<(int, Uint8List)> _next() async {
    if (!await _it.moveNext().timeout(const Duration(seconds: 8))) {
      throw 'Camera closed the connection';
    }
    return _it.current;
  }

  Future<Map<String, dynamic>> _call(int msg, Map<String, dynamic> body) async {
    _send(msg, body);
    final (_, d) = await _next();
    // The camera ends its JSON with "\n\0".
    final text = utf8
        .decode(d, allowMalformed: true)
        .replaceAll(RegExp(r'[\x00\n]+$'), '');
    return jsonDecode(text) as Map<String, dynamic>;
  }

  /// The camera's clock as a wall-clock reading (OPTimeQuery); null if the
  /// camera's answer has no time.
  Future<DateTime?> time() async {
    final r = await _call(1452, {'Name': 'OPTimeQuery'});
    return DateTime.tryParse('${r['OPTimeQuery']}');
  }

  static String _t(DateTime d, String hms) => '${ymd(d)} $hms';

  /// All clips of [day]. The camera answers 64 at a time, so keep asking from
  /// the last begin time and drop the repeated boundary clip.
  Future<List<Clip>> clips(DateTime day) async {
    final end = _t(day, '23:59:59');
    var begin = _t(day, '00:00:00');
    final seen = <String>{};
    final out = <Clip>[];
    while (true) {
      final r = await _call(1440, {
        'Name': 'OPFileQuery',
        'OPFileQuery': {
          'BeginTime': begin,
          'EndTime': end,
          'Channel': 0,
          'DriverTypeMask': '0x0000FFFF',
          'Event': '*',
          'Type': 'h264',
          'StreamType': '0x00000000',
        },
      });
      final q = (r['OPFileQuery'] as List?) ?? const [];
      var fresh = 0;
      for (final f in q) {
        final name = f['FileName'] as String;
        if (!seen.add(name)) continue;
        fresh++;
        out.add((
          name: name,
          begin: f['BeginTime'] as String,
          end: f['EndTime'] as String,
          motion: name.contains('[M]'),
        ));
      }
      if (q.length < 64 || fresh == 0) return out;
      begin = q.last['BeginTime'] as String;
    }
  }

  Map<String, dynamic> _play(String action, Clip c, String start) => {
    'Name': 'OPPlayBack',
    'OPPlayBack': {
      'Action': action,
      'Parameter': {
        'PlayMode': 'ByName',
        'FileName': c.name,
        'StreamType': 0,
        'Value': 0,
        'TransMode': 'TCP',
      },
      'StartTime': start,
      'EndTime': c.end,
    },
  };

  /// Raw recording bytes (camera frame format, see [XmDemux]). The camera
  /// starts at the first I-frame at or after [from] (camera clock,
  /// "yyyy-MM-dd HH:mm:ss"; default the clip's start). Cancel the subscription
  /// to stop.
  Stream<Uint8List> download(Clip c, {String? from}) async* {
    final start = from ?? c.begin;
    await _call(1424, _play('Claim', c, start));
    _send(1420, _play('DownloadStart', c, start));
    try {
      while (true) {
        final (_, d) = await _next();
        if (d.isEmpty) return; // zero-length packet = end of file
        yield d;
      }
    } finally {
      try {
        _send(1420, _play('DownloadStop', c, start));
      } catch (_) {} // socket already gone
    }
  }
}

/// Strips the camera's frame headers from a recording and keeps the video
/// (Annex-B H.264/H.265). Frames: 00 00 01 + F9 info / FA audio (8-byte
/// header, u16 length at 6), FC I-frame (16-byte header, u32 length at 12,
/// codec in byte 4's low nibble, fps in byte 5), FD P-frame (8-byte header,
/// u32 length at 4).
class XmDemux {
  /// 'h264' or 'hevc' once the first I-frame has been seen.
  String? codec;
  int fps = 0;
  Uint8List _buf = Uint8List(0);

  /// Video frames seen so far, and where each I-frame starts in the stripped
  /// output (byte offset, frame number): a stream cut at one of these plays,
  /// which is how seeking works.
  int frames = 0;
  int _out = 0;

  /// [ts] is the camera's clock at that I-frame (epoch seconds, camera-local).
  final iframes = <({int offset, int frame, int ts})>[];

  /// Feed a chunk (any size); returns the video bytes completed by it.
  Uint8List add(List<int> chunk) {
    _buf =
        (BytesBuilder(copy: false)
              ..add(_buf)
              ..add(chunk))
            .takeBytes();
    final out = BytesBuilder(copy: false);
    while (_buf.length >= 4) {
      final t = _buf[3];
      if (_buf[0] != 0 ||
          _buf[1] != 0 ||
          _buf[2] != 1 ||
          t < 0xf9 ||
          t > 0xfd) {
        _buf = Uint8List.sublistView(
          _buf,
          1,
        ); // lost sync: look for the next frame
        continue;
      }
      final head = t == 0xfc ? 16 : 8;
      if (_buf.length < head) break;
      final h = ByteData.sublistView(_buf);
      final len = switch (t) {
        0xfc => h.getUint32(12, Endian.little),
        0xfd => h.getUint32(4, Endian.little),
        _ => h.getUint16(6, Endian.little),
      };
      if (len > 16 << 20) {
        _buf = Uint8List.sublistView(_buf, 1); // implausible: false start code
        continue;
      }
      if (_buf.length < head + len) break;
      if (t == 0xfc || t == 0xfd) {
        if (t == 0xfc && codec == null) {
          codec = switch (_buf[4] & 0x0f) {
            2 => 'h264',
            3 => 'hevc',
            _ => null,
          };
          fps = _buf[5];
        }
        if (t == 0xfc) {
          // Packed time: year-2000:6, month:4, day:5, hour:5, minute:6, second:6.
          final v = h.getUint32(8, Endian.little);
          final ts =
              DateTime.utc(
                2000 + (v >> 26),
                (v >> 22) & 15,
                (v >> 17) & 31,
                (v >> 12) & 31,
                (v >> 6) & 63,
                v & 63,
              ).millisecondsSinceEpoch ~/
              1000;
          iframes.add((offset: _out, frame: frames, ts: ts));
        }
        frames++;
        _out += len;
        out.add(Uint8List.sublistView(_buf, head, head + len));
      }
      _buf = Uint8List.sublistView(_buf, head + len);
    }
    return out.takeBytes();
  }
}
