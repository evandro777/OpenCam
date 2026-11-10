import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'camera.dart';
import 'dvrip.dart';
import 'fmt.dart';

/// Clips recorded on the camera's SD card (iCSee / Xiongmai, over DVRIP).
class RecordingsPage extends StatefulWidget {
  const RecordingsPage(this.cam, {this.at, super.key});
  final Camera cam;

  /// Open on this moment's day and play the clip recorded then (an alert).
  final DateTime? at;

  @override
  State<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends State<RecordingsPage> {
  final _player = Player();
  late final _video = VideoController(_player);
  late DateTime _day = widget.at ?? DateTime.now();
  DateTime? _jump; // widget.at until the first listing has played it
  bool _clockFixed = false; // _jump is already on the camera's clock
  List<Clip>? _clips;
  bool? _motion; // list filter: null = all, true = motion only, false = regular
  final _scroll = ScrollController();
  static const _rowHeight = 48.0;
  String? _error;
  bool _refused = false; // the camera refused the login: no more tries
  Clip? _playing;
  int _gen = 0; // bumped by every play/stop: older async work gives up
  int _liveGen = -1; // _gen of the clip now playing; != _gen while stopping
  int _listGen = 0; // bumped by every day load: an older answer is dropped
  Dvrip? _dl;
  StreamSubscription<void>? _sub;
  HttpServer? _srv;

  // The clip's stripped video, growing while it downloads. It lives in a temp
  // file (a long HD clip is too big for memory on a phone). mpv reads it from
  // a loopback server; a seek reopens it at the I-frame before the target.
  late final Future<Directory> _tmp = Directory.systemTemp.createTemp(
    'opencam_',
  );
  // Random path prefix of the loopback server: other local apps can't guess it.
  final _token = base64Url.encode(
    List.generate(18, (_) => Random.secure().nextInt(256)),
  );
  File? _clipFile;
  RandomAccessFile? _out; // append handle of _clipFile
  int _len = 0; // bytes written so far
  bool _done = false;
  XmDemux? _demux;
  int _port = 0;
  // After a seek the stream restarts at an I-frame up to 3 s before the click:
  // play fast until this stream second, then go back to the chosen speed.
  double? _skipTo;
  int _baseFrame = 0; // download frame where the current stream starts
  // A click beyond what is downloaded restarts the download there, so the
  // buffer begins at clip second _segStart (camera clock, from the I-frames).
  double _segStart = 0;
  int _beginTs = 0; // camera clock at the clip's start, epoch seconds
  double? _pendingFrom; // clip second to reach once the new download plays
  double _total = 1; // clip length, seconds
  // A notifier: fullscreen is another route, the page's setState can't reach it.
  final _rateN = ValueNotifier(1.0);
  double get _rate => _rateN.value;
  bool _drag = false;
  final _pos = ValueNotifier(0.0); // seconds, drives the slider
  final _have = ValueNotifier(0.0); // seconds downloaded
  late final _subs = [
    _player.stream.position.listen((p) {
      final s = p.inMilliseconds / 1000;
      if (_skipTo != null && s >= _skipTo!) {
        _skipTo = null;
        _player.setRate(_rate);
      }
      final d = _demux;
      if (!_drag && d != null) {
        _pos.value = _segStart + (_baseFrame + s * d.fps) * _spf(d);
      }
    }),
    // The clip played to its end: go on with the next one of the day.
    _player.stream.completed.listen((done) {
      final shown = _shown;
      final i = _playing == null ? -1 : shown.indexOf(_playing!);
      if (done && _liveGen == _gen && i >= 0 && i + 1 < shown.length) {
        _play(shown[i + 1]);
      }
    }),
  ];

  @override
  void initState() {
    super.initState();
    _jump = widget.at;
    _subs; // start listening
    _load();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _tmp.then((d) => d.delete(recursive: true)).ignore();
    // stop() on a disposed player throws, so dispose only once _stop is done.
    _stop().whenComplete(_player.dispose);
    _scroll.dispose();
    super.dispose();
  }

  /// The clips the filter lets through.
  List<Clip> get _shown => [
    for (final c in _clips ?? const <Clip>[])
      if (_motion == null || c.motion == _motion) c,
  ];

  /// Scrolls the list so [c]'s row is on screen (centered), once the video
  /// pane has taken its space.
  Future<void> _reveal(Clip c) async {
    await WidgetsBinding.instance.endOfFrame;
    final i = _shown.indexOf(c);
    if (!mounted || i < 0 || !_scroll.hasClients) return;
    final p = _scroll.position;
    final y = i * _rowHeight;
    if (y >= p.pixels && y + _rowHeight <= p.pixels + p.viewportDimension) {
      return;
    }
    _scroll.animateTo(
      (y - (p.viewportDimension - _rowHeight) / 2).clamp(
        0.0,
        p.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  Future<void> _load() async {
    if (_refused) return; // the error stays on screen, no new login
    final gen = ++_listGen;
    setState(() {
      _clips = null;
      _error = null;
    });
    Dvrip? d;
    List<Clip>? clips;
    try {
      d = await Dvrip.open(widget.cam);
      // An alert carries the phone's time, the clips the camera's: move it
      // onto the camera's clock (once) before picking the day and the clip.
      final jump = _jump;
      if (jump != null && !_clockFixed) {
        _clockFixed = true;
        final cam = await d.time();
        // Not if a day arrow was tapped meanwhile: that newer load wins.
        if (cam != null && gen == _listGen) {
          _jump = jump.add(clockOffset(cam, DateTime.now()));
          _day = _jump!;
        }
      }
      clips = await d.clips(_day);
      if (mounted && gen == _listGen) setState(() => _clips = clips);
    } catch (e) {
      if (e is LoginRefused) _refused = true;
      if (mounted && gen == _listGen) setState(() => _error = '$e');
    } finally {
      d?.close();
    }
    // After the listing connection is closed: _play opens its own.
    final at = _jump;
    if (at == null || clips == null || !mounted || gen != _listGen) return;
    _jump = null;
    final c = clipAt(clips, at);
    if (c == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'No recording at ${hm(at)} (still being written, or not on the SD card)',
          ),
        ),
      );
      return;
    }
    final into = at.difference(DateTime.parse(c.begin)).inSeconds;
    await _play(c, from: max(0, into).toDouble());
  }

  Future<void> _stop() async {
    _gen++;
    _skipTo = null;
    final sub = _sub, dl = _dl, srv = _srv;
    _sub = _dl = _srv = null;
    await sub?.cancel();
    _out?.closeSync();
    _out = null;
    _clipFile?.delete().ignore(); // a reader still open keeps its data
    _clipFile = null;
    dl?.close();
    await srv?.close(force: true);
    await _player.stop();
  }

  /// Play [c] from its start, or from clip second [from] (the camera then
  /// sends it from an I-frame at or after that time, so ask a GOP early).
  Future<void> _play(Clip c, {double from = 0}) async {
    if (_refused) return;
    await _stop();
    final gen = _liveGen = _gen;
    setState(() {
      _playing = c;
      _error = null;
    });
    _reveal(c);
    try {
      final tmp = await _tmp;
      final dl = await Dvrip.open(widget.cam);
      // Only the newest play owns _dl: an older one must not overwrite it.
      if (gen != _gen) return dl.close();
      _dl = dl;
      _out = (_clipFile = File(
        '${tmp.path}/$gen.bin',
      )).openSync(mode: FileMode.write);
      final demux = _demux = XmDemux();
      _len = 0;
      _done = false;
      _baseFrame = 0;
      _segStart = 0;
      _pendingFrom = from > 0 ? from : null;
      _pos.value = _have.value = from;
      // The camera's clock fields read as UTC: only differences matter.
      final begin = DateTime.parse('${c.begin}Z');
      _beginTs = begin.millisecondsSinceEpoch ~/ 1000;
      _total = max(
        1,
        DateTime.parse('${c.end}Z').difference(begin).inSeconds,
      ).toDouble();
      final start = from > 0
          ? begin
                .add(Duration(seconds: min(from - 4, _total - 1).floor()))
                .toIso8601String()
                .substring(0, 19)
                .replaceFirst('T', ' ')
          : null;
      var started = false;
      _sub = dl
          .download(c, from: start)
          .listen(
            (chunk) {
              _append(demux.add(chunk));
              if (demux.iframes.isNotEmpty) {
                _segStart = demux.iframes.first.ts - _beginTs.toDouble();
              }
              _have.value = _segStart + demux.frames * _spf(demux);
              if (!started && demux.codec != null) {
                started = true;
                _open(gen, demux);
              }
            },
            onDone: () => _done = true,
            onError: (Object e) {
              _done = true;
              if (mounted && gen == _gen) setState(() => _error = '$e');
            },
          );
    } catch (e) {
      if (e is LoginRefused) _refused = true;
      if (mounted && gen == _gen) setState(() => _error = '$e');
    }
  }

  /// Serve the stripped video on localhost and let mpv read it as a raw
  /// stream (the picture starts while the clip is still downloading).
  Future<void> _open(int gen, XmDemux demux) async {
    final file = _clipFile;
    if (file == null) return;
    final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (gen != _gen) return srv.close(force: true);
    _srv = srv;
    _port = srv.port;
    srv.listen((req) async {
      if (req.uri.path != '/$_token') {
        req.response.statusCode = HttpStatus.forbidden;
        await req.response.close();
        return;
      }
      var pos = int.tryParse(req.uri.queryParameters['from'] ?? '') ?? 0;
      final res = req.response;
      RandomAccessFile? r;
      try {
        r = file.openSync();
        // Follow the growing file until the download ends. After a seek mpv
        // drops this connection, and the next write fails and ends the loop.
        while (gen == _gen) {
          final chunk = pos < _len
              ? (r..setPositionSync(pos)).readSync(min(_len - pos, 65536))
              : null;
          if (chunk != null && chunk.isNotEmpty) {
            res.add(chunk);
            pos += chunk.length;
            await res.flush();
          } else if (_done && pos >= _len) {
            break;
          } else {
            await Future<void>.delayed(const Duration(milliseconds: 40));
          }
        }
        await res.close();
      } catch (_) {
        // mpv closed the connection (seek or stop)
      } finally {
        r?.closeSync();
      }
    });
    final mpv = _player.platform as NativePlayer;
    await mpv.setProperty('demuxer-lavf-format', demux.codec!);
    await mpv.setProperty('demuxer-lavf-o', 'framerate=${demux.fps}');
    await _player.open(Media('http://127.0.0.1:$_port/$_token'));
    // Restarted by a seek: skip from the first I-frame to the clicked second.
    final p = _pendingFrom;
    _pendingFrom = null;
    await _applyGap(
      p == null ? 0 : (p - _segStart) / _spf(demux) / max(1, demux.fps),
    );
  }

  /// [gap] mpv seconds to skip: play at mpv's top speed (hidden) until there,
  /// then back to the chosen speed.
  Future<void> _applyGap(double gap) async {
    if (gap > 0.1) {
      _skipTo = gap;
      await _player.setRate(100);
    } else {
      await _player.setRate(_rate);
    }
  }

  void _append(Uint8List v) {
    _out?.writeFromSync(v);
    _len += v.length;
  }

  /// Clip seconds per video frame. The camera records ~12.5 fps but labels
  /// the stream 12, so a "5 min" clip holds 312 s of media: the slider (camera
  /// clock, like the time stamp in the picture) would drift from mpv's clock.
  /// The camera times of the I-frames give the true rate.
  /// shortcut: first-to-last I-frame (1 s resolution), a straight line.
  double _spf(XmDemux d) {
    final a = d.iframes;
    if (a.length < 4 || a.last.ts <= a.first.ts) return 1 / max(1, d.fps);
    return (a.last.ts - a.first.ts) / (a.last.frame - a.first.frame);
  }

  /// Jump to clip second [sec]. Inside what is downloaded, restart mpv's
  /// stream at the last I-frame before it; outside (the camera sends ~6x real
  /// time, so the end is not there yet) ask the camera for the clip from there.
  Future<void> _seek(double sec) async {
    final d = _demux, c = _playing;
    if (d == null || c == null) return;
    final spf = _spf(d);
    final have = _segStart + d.frames * spf;
    if (d.iframes.isEmpty || sec < _segStart - 3 || sec > have + 1) {
      return _play(c, from: sec);
    }
    final want = max(0, sec - _segStart) / spf; // download frame number
    final f = d.iframes.lastWhere(
      (i) => i.frame <= want,
      orElse: () => d.iframes.first,
    );
    _skipTo = null;
    _baseFrame = f.frame;
    _pos.value = _segStart + f.frame * spf;
    await _player.open(
      Media('http://127.0.0.1:$_port/$_token?from=${f.offset}'),
    );
    await _applyGap((min(want, d.frames.toDouble()) - f.frame) / d.fps);
  }

  static String _fmt(double s) =>
      '${s ~/ 60}:${(s % 60).floor().toString().padLeft(2, '0')}';

  static String _x(double r) => '${r == r.roundToDouble() ? r.toInt() : r}x';

  /// Bar over the video. It is the video's own controls, so fullscreen (which
  /// reopens the same Video in another route) keeps the slider and the speed.
  /// Pinned with Positioned: under Align the Material filled the whole video
  /// and the bar sat in the middle.
  /// Click = pause/play, double click = fullscreen on/off, Esc = leave
  /// fullscreen (the focus sits here from the start, also in the fullscreen
  /// route).
  Widget _controls(VideoState state) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () {
        if (state.isFullscreen()) state.exitFullscreen();
      },
    },
    child: Focus(
      autofocus: true,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _player.playOrPause,
        onDoubleTap: state.toggleFullscreen,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              // Fullscreen is another route but inherits the (dark) app theme.
              child: Material(color: Colors.black54, child: _bar(state)),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _bar(VideoState state) => Row(
    children: [
      StreamBuilder<bool>(
        stream: _player.stream.playing,
        initialData: true,
        builder: (_, s) => IconButton(
          icon: Icon(s.data! ? Icons.pause : Icons.play_arrow),
          tooltip: s.data! ? 'Pause' : 'Play',
          onPressed: _player.playOrPause,
        ),
      ),
      ValueListenableBuilder(
        valueListenable: _pos,
        builder: (_, pos, _) => ValueListenableBuilder(
          valueListenable: _have,
          builder: (_, have, _) => Expanded(
            child: Row(
              children: [
                Text(_fmt(pos)),
                Expanded(
                  child: Slider(
                    value: pos.clamp(0.0, _total),
                    max: _total,
                    secondaryTrackValue: have.clamp(0.0, _total),
                    onChangeStart: (_) => _drag = true,
                    onChanged: (v) => _pos.value = v,
                    onChangeEnd: (v) {
                      _drag = false;
                      _seek(v);
                    },
                  ),
                ),
                Text(_fmt(_total)),
              ],
            ),
          ),
        ),
      ),
      PopupMenuButton<double>(
        tooltip: 'Speed',
        initialValue: _rate,
        onSelected: (r) {
          _rateN.value = r;
          _player.setRate(r);
        },
        itemBuilder: (_) => [
          for (final r in const [0.5, 1.0, 2.0, 4.0, 8.0])
            PopupMenuItem(value: r, child: Text(_x(r))),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ValueListenableBuilder(
            valueListenable: _rateN,
            builder: (_, r, _) => Text(_x(r)),
          ),
        ),
      ),
      IconButton(
        icon: Icon(
          state.isFullscreen() ? Icons.fullscreen_exit : Icons.fullscreen,
        ),
        tooltip: 'Fullscreen',
        onPressed: state.toggleFullscreen,
      ),
    ],
  );

  static const _span = Duration(days: 365);

  bool get _atToday => !_day.isBefore(DateUtils.dateOnly(DateTime.now()));
  bool get _atOldest =>
      !_day.isAfter(DateUtils.dateOnly(DateTime.now().subtract(_span)));

  Future<void> _pickDay() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime.now().subtract(_span),
      // A camera clock ahead of the phone can put _day after now.
      lastDate: _day.isAfter(DateTime.now()) ? _day : DateTime.now(),
    );
    if (d != null) _setDay(d);
  }

  void _setDay(DateTime d) {
    _day = d;
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final day = ymd(_day);
    final clips = _clips;
    final shown = _shown;
    final size = MediaQuery.sizeOf(context);
    return Scaffold(
      appBar: AppBar(title: Text('${widget.cam.name} recordings')),
      body: Column(
        children: [
          if (_playing != null)
            // At most half the window, so the date row and the list always
            // fit. A split camera's stacked picture is tall: give it the half.
            SizedBox(
              height: widget.cam.split
                  ? size.height * 0.5
                  : min(size.width * 9 / 16, size.height * 0.5),
              child: Video(controller: _video, controls: _controls),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                tooltip: 'Previous day',
                onPressed: _atOldest
                    ? null
                    : () => _setDay(DateUtils.addDaysToDate(_day, -1)),
              ),
              TextButton.icon(
                onPressed: _pickDay,
                icon: const Icon(Icons.calendar_today, size: 18),
                label: Text(day),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                tooltip: 'Next day',
                onPressed: _atToday
                    ? null
                    : () => _setDay(DateUtils.addDaysToDate(_day, 1)),
              ),
            ],
          ),
          SegmentedButton<bool?>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: null, label: Text('All')),
              ButtonSegment(
                value: true,
                icon: Icon(Icons.directions_run),
                label: Text('Motion'),
              ),
              ButtonSegment(
                value: false,
                icon: Icon(Icons.schedule),
                label: Text('Regular'),
              ),
            ],
            selected: {_motion},
            onSelectionChanged: (s) => setState(() => _motion = s.first),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: clips == null
                ? Center(
                    child: _error == null
                        ? const CircularProgressIndicator()
                        : null,
                  )
                : clips.isEmpty
                ? const Center(child: Text('No recordings this day'))
                : shown.isEmpty
                ? Center(
                    child: Text(
                      'No ${_motion! ? 'motion' : 'regular'} clips this day',
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    // Same height for every row: _reveal finds a row by index.
                    itemExtent: _rowHeight,
                    itemCount: shown.length,
                    itemBuilder: (_, i) {
                      final c = shown[i];
                      // Bar on the left: the playing clip shows at a glance.
                      return DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(
                              width: 3,
                              color: c == _playing
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.transparent,
                            ),
                          ),
                        ),
                        child: ListTile(
                          dense: true,
                          selected: c == _playing,
                          leading: Icon(
                            c.motion ? Icons.directions_run : Icons.schedule,
                          ),
                          title: Text(
                            '${c.begin.substring(11)} – ${c.end.substring(11)}',
                            style: const TextStyle(
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                          trailing: c.motion ? const Text('motion') : null,
                          onTap: () => _play(c),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
