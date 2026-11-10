import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import 'camera.dart';
import 'events.dart';
import 'pixels.dart';
import 'rtsp.dart';
import 'watchdog.dart';

/// Why a camera shows no picture (see [CamSession.problem]).
enum CamProblem {
  /// The camera answered but rejected the user or password.
  refused,

  /// Nothing answers on the RTSP port: off, wrong IP or not on this network.
  unreachable,

  /// The login works, but no video arrives.
  noPicture,
}

/// The saved last picture of the camera at [host].
Future<File> thumbFile(String host) async {
  final dir = await getApplicationSupportDirectory();
  final name = host.replaceAll(RegExp(r'[^\w.-]'), '_');
  return File('${dir.path}/thumb_$name.png');
}

/// Removes the saved picture of [host] (camera deleted or moved to another IP).
Future<void> forgetThumb(String host) async {
  try {
    final f = await thumbFile(host);
    if (await f.exists()) await f.delete();
  } catch (e) {
    debugPrint('cannot delete picture of $host: $e');
  }
}

/// One RTSP connection per camera: the grid and fullscreen share this player.
class CamSession {
  CamSession(this.cam, {this.onAutoChange}) : events = CamEvents(cam) {
    _bind(player);
    _timer = Timer.periodic(const Duration(seconds: 3), _tick);
    _init();
  }

  /// Last picture, kept on disk per camera host so the next launch shows it
  /// at once (no connection) instead of a spinner.
  Future<File> get _file => thumbFile(cam.host);

  Future<void> _init() async {
    // Heal a saved "no vendor SD address" that was a wrong guess (the camera
    // was busy at startup): such a camera showed HD with SD turned on.
    if (cam.sd && !cam.xm && await hasDvrip(cam.host) && !_closed) {
      cam = cam.copyWith(xm: true);
      onAutoChange?.call();
    }
    try {
      final f = await _file;
      if (await f.exists()) {
        final codec = await ui.instantiateImageCodec(await f.readAsBytes());
        final img = (await codec.getNextFrame()).image;
        codec.dispose();
        // A blank thumbnail saved by an older run: drop it and reconnect.
        final px = await img.toByteData();
        if (px != null && isBlank(px.buffer.asUint8List())) {
          await f.delete();
        } else if (!_closed) {
          _paused = true; // same state as after _snapshot's pause()
          _setFrozen(img);
          loading.value = false;
          if (!stopped.value) resume(); // play was pressed while reading
          return;
        }
        img.dispose();
      }
    } catch (e) {
      debugPrint('${cam.name}: saved picture unreadable: $e');
    }
    if (!_closed) _snapshot();
  }

  Future<void> _save(ui.Image img) async {
    try {
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      if (png != null) {
        await (await _file).writeAsBytes(png.buffer.asUint8List());
      }
    } catch (e) {
      debugPrint('${cam.name}: cannot save picture: $e');
    }
  }

  Camera cam;

  /// User-level off: the app starts like this, no stream, the tile shows its
  /// last picture and a play button. pause()/resume() (fullscreen, minimize,
  /// Android background) are the transient mechanism and never start a
  /// stopped camera.
  final stopped = ValueNotifier(true);

  /// Called when the session changed [cam] by itself (SD fallback): save it.
  final void Function()? onAutoChange;

  /// Motion / tamper alerts. The grid starts and stops it (see GridPage).
  final CamEvents events;

  /// The current picture source. Replaced by [_swap]; widgets listen to it.
  final ctl = ValueNotifier(_make(Player()));
  VideoController get controller => ctl.value;
  Player get player => ctl.value.player;

  static VideoController _make(Player p) => VideoController(
    p,
    configuration: const VideoControllerConfiguration(hwdec: 'auto-safe'),
  );

  /// Videos to mount, bottom to top; two only while a [_swap] is in flight.
  late final views = ValueNotifier([controller]);

  final _subs = <StreamSubscription<dynamic>>[];
  int _gen = 0; // bumped by every (re)open: a pending _swap then gives up

  void _bind(Player p) {
    for (final s in _subs) {
      s.cancel();
    }
    p.setVolume(muted ? 0 : 100);
    _subs
      ..add(p.stream.error.listen((_) => _dead = true))
      ..add(p.stream.completed.listen((c) => _dead = _dead || c))
      // First picture of the new stream: drop the spinner and the frozen frame.
      // _armed ignores events still coming from the old stream.
      ..add(
        p.stream.position.listen((d) {
          if (_armed && _viaPos && d > Duration.zero) _live();
        }),
      )
      // A decoder restart keeps the position ticking but unsets the video
      // params until its first new frame, so that is its signal.
      ..add(
        p.stream.videoParams.listen((v) {
          if (_armed && v.dw is int) _live();
        }),
      );
  }

  /// True from (re)connect until the first new picture; shows a spinner.
  final loading = ValueNotifier(true);

  /// Last picture of the old stream, shown instead of black while [loading].
  final frozen = ValueNotifier<ui.Image?>(null);

  bool muted = true;
  bool _paused = false, _dead = false, _played = false;
  bool _armed = false, _viaPos = true; // see the listeners in the constructor
  bool _closed = false;

  /// Decode keyframes only: the camera's saver mode.
  bool get _saver => cam.keyframes;
  Duration _lastPos = Duration.zero;
  int _stale = 0, _fails = 0, _skip = 0;
  late final Timer _timer;

  void _live() {
    _pics++;
    _diagnosed = false;
    problem.value = null;
    loading.value = false;
    _setFrozen(null);
  }

  void _setFrozen(ui.Image? img) {
    if (_closed) {
      img?.dispose(); // a freeze that finished after dispose()
      return;
    }
    final old = frozen.value;
    frozen.value = img;
    // Not while the old one may still be painted this frame.
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  /// Keep mpv's current picture to show while the stream reconnects. Skipped
  /// while already loading (a retry would just grab the same stale frame) and
  /// on any failure: the previous frozen frame then stays.
  Future<void> _freeze() async {
    if (loading.value) return;
    final w = player.state.width, h = player.state.height;
    if (w == null || h == null || w == 0 || h == 0) return;
    // The unsynchronized grab can come back all zeros (nothing rendered yet):
    // try again waiting for a real frame, and never keep a blank one.
    Uint8List? bytes;
    for (final sync in [false, true]) {
      bytes = await (player.platform as NativePlayer)
          .screenshot(format: null, synchronized: sync)
          .timeout(const Duration(milliseconds: 500), onTimeout: () => null);
      if (bytes != null && !isBlank(bytes)) break;
      bytes = null;
    }
    if (bytes == null || bytes.length % h != 0 || bytes.length ~/ h < w * 4) {
      return;
    }
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      opaque(bytes),
      w,
      h,
      ui.PixelFormat.bgra8888,
      done.complete,
      rowBytes: bytes.length ~/ h,
      targetWidth: min(w, 960), // a tile never needs more; keeps memory low
    );
    final img = await done.future;
    await _save(img); // pause() awaits this: it runs on minimize/quit too
    _setFrozen(img);
  }

  Future<void> _open() async {
    _gen++;
    _armed = false;
    _viaPos = true;
    await _freeze();
    if (_closed) return; // disposed while the frame was taken
    loading.value = true;
    _dead = false;
    _stale = 0;
    _lastPos = Duration.zero;
    await _start(player);
    _armed = true;
  }

  /// Connect [p] to the current camera URL with the live-view options.
  Future<void> _start(Player p) async {
    final mpv = p.platform as NativePlayer;
    await mpv.setProperty(
      'demuxer-lavf-o',
      'rtsp_transport=${cam.udp ? 'udp' : 'tcp'}',
    );
    // Small buffers: live view only, no seeking back.
    await mpv.setProperty('cache', 'no');
    await mpv.setProperty('demuxer-max-bytes', '2MiB');
    await mpv.setProperty('demuxer-readahead-secs', '0');
    await mpv.setProperty('vd-lavc-skipframe', _saver ? 'nonkey' : 'default');
    // Software decode only: skip the deblocking filter on the small grid tile.
    await mpv.setProperty('vd-lavc-skiploopfilter', cam.sd ? 'all' : 'default');
    await mpv.setProperty('aid', muted ? 'no' : 'auto'); // skip audio decode
    await p.open(Media(cam.url()));
  }

  /// Make-before-break: connect a second player in the background and switch
  /// the picture to it at its first frame, so the old stream keeps playing
  /// meanwhile. If it does not come up, fall back to the plain reconnect.
  Future<void> _swap() async {
    final gen = ++_gen;
    final p = Player();
    final c = _make(p);
    final oldC = controller, old = oldC.player;
    // Mounted under the old picture so it renders (and is not black) at swap.
    views.value = [c, oldC];
    loading.value = true; // spinner over the still-playing old picture
    void drop() {
      if (_closed) {
        p.dispose(); // views is gone with the session; the player must not stay
        return;
      }
      // Only this swap's video: a newer swap may have mounted its own.
      views.value = [
        for (final v in views.value)
          if (v != c) v,
      ];
      // Not while the widget may still be painting it this frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => p.dispose());
    }

    // media_kit's waitUntilFirstFrameRendered only means "size known", not a
    // drawn picture: wait for the first decoded frame, then let it reach the
    // mounted texture.
    final decoded = p.stream.videoParams
        .firstWhere((v) => v.dw is int)
        .then((_) {}, onError: (_) {}); // disposed before a frame: timeout wins
    try {
      await _start(p);
      await decoded.timeout(const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    } catch (_) {
      drop();
      if (!_closed && gen == _gen) {
        _played = false; // lets the vendor-SD fallback in _tick judge it
        _open();
      }
      return;
    }
    if (_closed || gen != _gen) {
      drop();
      return;
    }
    _bind(p);
    _armed = false;
    _dead = false;
    _stale = 0;
    _fails = 0;
    _skip = 0;
    _lastPos = Duration.zero;
    ctl.value = c;
    loading.value = false;
    views.value = [oldC, c]; // c on top
    WidgetsBinding.instance.addPostFrameCallback((_) {
      views.value = [c];
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    });
  }

  /// What mpv reports about the stream playing now; unknown values are left out.
  Future<List<(String, String)>> streamInfo() async {
    final mpv = player.platform as NativePlayer;
    Future<String> get(String k) async {
      try {
        return await mpv.getProperty(k);
      } catch (_) {
        return '';
      }
    }

    final w = await get('video-params/w'), h = await get('video-params/h');
    final fps = await get('container-fps');
    final bps = int.tryParse(await get('video-bitrate'));
    final rate = await get('audio-params/samplerate');
    final rows = <(String, String)>[
      ('Video codec', await get('video-codec')),
      ('Video size', w.isEmpty || h.isEmpty ? '' : '$w×$h'),
      ('Frame rate', fps.isEmpty ? '' : '$fps fps'),
      ('Video bitrate', bps == null ? '' : '${bps ~/ 1000} kbps'),
      ('Hardware decode', await get('hwdec-current')),
      ('Audio codec', await get('audio-codec-name')),
      ('Audio rate', rate.isEmpty ? '' : '$rate Hz'),
      ('Dropped frames', await get('decoder-frame-drop-count')),
    ];
    return [
      for (final r in rows)
        if (r.$2.isNotEmpty) r,
    ];
  }

  // mpv does not reconnect RTSP and a dead camera often just freezes the
  // frame, so watch the playback position instead of trusting error events.
  void _tick(Timer _) {
    if (_paused) return;
    final pos = player.state.position;
    final r = watchStep((
      moved: pos != _lastPos,
      stale: _stale,
      skip: _skip,
      fails: _fails,
      played: _played,
      dead: _dead,
      saver: _saver,
      diagnosing: _diagnosing,
      diagnosed: _diagnosed,
      vendorSd: cam.sd && cam.xm,
      icsee: _icsee,
    ));
    _lastPos = pos;
    _stale = r.stale;
    _skip = r.skip;
    _fails = r.fails;
    _played = r.played;
    switch (r.act) {
      case WatchAct.none:
        break;
      case WatchAct.diagnose:
        _diagnose(); // a wrong login stops all tries (they can lock the IP)
      case WatchAct.dropVendorSd:
        // Not an iCSee camera (e.g. Yoosee): use the standard path and
        // remember it.
        cam = cam.copyWith(xm: false);
        onAutoChange?.call();
        _open();
      case WatchAct.reopen:
        _open();
    }
  }

  /// Startup: connect just long enough to get one picture (the tile's
  /// thumbnail), then stop. If the user pressed play meanwhile, keep playing.
  Future<void> _snapshot() async {
    final first = Completer<void>();
    void seen() {
      if (!loading.value && !first.isCompleted) first.complete();
    }

    loading.addListener(seen);
    _open();
    await first.future.timeout(const Duration(seconds: 12), onTimeout: () {});
    if (_closed) return; // disposed while waiting: the notifiers are gone
    loading.removeListener(seen);
    if (loading.value) _diagnose(); // no picture in time: say why
    if (!stopped.value) return;
    await Future<void>.delayed(
      const Duration(milliseconds: 300),
    ); // let it draw
    if (!_closed && stopped.value) await pause();
  }

  /// Why the camera shows no picture, shown on its tile; null = nothing wrong.
  final problem = ValueNotifier<CamProblem?>(null);
  bool _diagnosed = false, _diagnosing = false;
  bool _icsee = false; // DVRIP port open, set by _diagnose
  int _pics = 0; // pictures shown so far: a change means the camera is fine

  /// One login check per failure streak (at most 2 login attempts), not a
  /// retry loop. A refused login also stops playing until the user presses
  /// play or fixes the camera in Settings.
  Future<void> _diagnose() async {
    if (_closed || _diagnosed) return;
    _diagnosed = _diagnosing = true;
    final seen = _pics;
    if (cam.sd && cam.xm) _icsee = await hasDvrip(cam.host);
    final ok = await checkRtsp(cam);
    _diagnosing = false;
    if (_closed || _pics != seen) return; // a picture came meanwhile
    if (ok == false) {
      problem.value = CamProblem.refused;
      _refuse();
    } else if (ok == null) {
      problem.value = CamProblem.unreachable;
    } else if (!_played) {
      problem.value = CamProblem.noPicture;
    }
  }

  void _refuse() {
    stopped.value = true;
    _paused = true; // the watchdog stays quiet
    _gen++; // cancels a pending _swap
    _armed = false;
    loading.value = false;
    player.stop();
  }

  Future<void> start() async {
    problem.value = null;
    _diagnosed = false;
    stopped.value = false;
    resume();
  }

  Future<void> stop() async {
    if (stopped.value) return;
    stopped.value = true;
    await pause(); // the last picture becomes the thumbnail
  }

  /// New options (UDP, keyframes) take effect by reconnecting this player.
  void update(Camera c) {
    cam = c;
    _diagnosed = false;
    if (stopped.value) return; // applied when it starts
    if (!_paused && !loading.value) {
      _swap();
      return;
    }
    _played = false;
    _fails = 0;
    _skip = 0;
    _open();
  }

  /// Saver mode only changes the decoder: restart it (vid no/auto) and keep the
  /// RTSP connection, so no handshake. mpv ignores the option on a live decoder.
  Future<void> setKeyframes(Camera c) {
    cam = c;
    return _restartDecoder();
  }

  Future<void> _restartDecoder() async {
    if (_paused) return; // the next _open() reads the current mode
    _armed = false;
    _viaPos = false;
    await _freeze();
    loading.value = true;
    _stale = 0;
    final mpv = player.platform as NativePlayer;
    await mpv.setProperty('vd-lavc-skipframe', _saver ? 'nonkey' : 'default');
    await mpv.setProperty('vid', 'no');
    await mpv.setProperty('vid', 'auto');
    _armed = true;
  }

  void setMuted(bool m) {
    muted = m;
    player.setVolume(m ? 0 : 100);
    (player.platform as NativePlayer).setProperty('aid', m ? 'no' : 'auto');
  }

  Future<void> pause() async {
    if (_paused) return;
    _paused = true;
    _gen++; // cancels a pending _swap
    _armed = false;
    await _freeze();
    // resume() came back while the frame was taken, or the session was disposed.
    if (!_paused || _closed) return;
    // resume() then keeps this frozen frame; a stopped tile shows play, not
    // the spinner.
    loading.value = !stopped.value;
    player.stop();
  }

  void resume() {
    if (stopped.value || !_paused) return;
    _paused = false;
    _open();
  }

  void dispose() {
    _closed = true;
    _timer.cancel();
    events.dispose();
    for (final s in _subs) {
      s.cancel();
    }
    ctl.dispose();
    views.dispose();
    loading.dispose();
    stopped.dispose();
    problem.dispose();
    frozen.value?.dispose();
    frozen.dispose();
    player.dispose();
  }
}
