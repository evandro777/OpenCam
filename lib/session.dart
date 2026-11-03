import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'camera.dart';

/// One RTSP connection per camera: the grid and fullscreen share this player.
class CamSession {
  CamSession(this.cam, {this.onAutoChange}) {
    _bind(player);
    _timer = Timer.periodic(const Duration(seconds: 3), _tick);
    _open();
  }

  Camera cam;

  /// Called when the session changed [cam] by itself (SD fallback): save it.
  final void Function()? onAutoChange;

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
    final bytes = await (player.platform as NativePlayer)
        .screenshot(format: null, synchronized: false)
        .timeout(const Duration(milliseconds: 300), onTimeout: () => null);
    if (bytes == null || bytes.length % h != 0 || bytes.length ~/ h < w * 4) {
      return;
    }
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      bytes,
      w,
      h,
      ui.PixelFormat.bgra8888,
      done.complete,
      rowBytes: bytes.length ~/ h,
      targetWidth: min(w, 960), // a tile never needs more; keeps memory low
    );
    _setFrozen(await done.future);
  }

  Future<void> _open() async {
    _gen++;
    _armed = false;
    _viaPos = true;
    await _freeze();
    loading.value = true;
    _dead = false;
    _stale = 0;
    _lastPos = Duration.zero;
    final mpv = player.platform as NativePlayer;
    await _start(player);
    _armed = true;
    _logDecode(mpv);
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
      if (_closed) return;
      views.value = [controller];
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
      if (_closed) return;
      if (gen == _gen) {
        drop();
        _played = false; // lets the vendor-SD fallback in _tick judge it
        _open();
      }
      return;
    }
    if (_closed || gen != _gen) {
      if (!_closed) drop();
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

  // Temporary: shows which streams really use hardware decode.
  Future<void> _logDecode(NativePlayer mpv) async {
    await Future<void>.delayed(const Duration(seconds: 8));
    final hw = await mpv.getProperty('hwdec-current');
    final drops = await mpv.getProperty('decoder-frame-drop-count');
    debugPrint('${cam.name}: hwdec=$hw decoder-drops=$drops');
  }

  // mpv does not reconnect RTSP and a dead camera often just freezes the
  // frame, so watch the playback position instead of trusting error events.
  void _tick(Timer _) {
    if (_paused) return;
    final pos = player.state.position;
    if (pos != _lastPos) {
      _fails = 0;
      _played = true;
    }
    _stale = pos == _lastPos ? _stale + 1 : 0;
    _lastPos = pos;
    if (_skip > 0) {
      _skip--;
      return;
    }
    // Keyframes-only: the picture only moves once per keyframe interval, so
    // wait ~30 s (not ~9 s) before calling the stream dead.
    final limit = _saver ? 10 : 3;
    if (_dead || _stale >= limit) {
      _fails++;
      // The vendor SD URL never produced a frame: not an iCSee camera (e.g.
      // Yoosee). Fall back to the standard path and remember it.
      if (cam.sd && cam.xm && !_played && _fails >= 2) {
        cam = cam.copyWith(xm: false);
        _fails = 0;
        _skip = 0;
        onAutoChange?.call();
        _open();
        return;
      }
      _skip = _fails < 5 ? _fails : 5; // backoff, max ~15 s between tries
      _open();
    }
  }

  /// New options (UDP, keyframes) take effect by reconnecting this player.
  void update(Camera c) {
    cam = c;
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
    if (!_paused) return; // resume() came back while the frame was taken
    loading.value = true; // resume() then keeps this frozen frame
    player.stop();
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    _open();
  }

  void dispose() {
    _closed = true;
    _timer.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    ctl.dispose();
    views.dispose();
    loading.dispose();
    frozen.value?.dispose();
    frozen.dispose();
    player.dispose();
  }
}
