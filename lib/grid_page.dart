import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'camera.dart';
import 'ptz.dart';
import 'session.dart';
import 'settings_page.dart';
import 'store.dart';

class GridPage extends StatefulWidget {
  const GridPage({super.key});

  @override
  State<GridPage> createState() => _GridPageState();
}

class _GridPageState extends State<GridPage> with WidgetsBindingObserver {
  List<CamSession> _sessions = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    final cams = await loadCameras();
    for (final s in _sessions) {
      s.dispose();
    }
    if (!mounted) return;
    setState(
      () => _sessions = [
        for (final c in cams)
          CamSession(
            c,
            onAutoChange: () {
              if (!mounted) return;
              setState(() {});
              saveCameras([for (final x in _sessions) x.cam]);
            },
          ),
      ],
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Desktop: minimized/hidden stops the streams (no network); just out of
    // focus changes nothing (reconnecting means ~3 s black on return).
    if (!Platform.isAndroid && !Platform.isIOS) {
      final hidden =
          state == AppLifecycleState.hidden ||
          state == AppLifecycleState.paused ||
          state == AppLifecycleState.detached;
      for (final s in _sessions) {
        if (hidden) {
          s.pause();
        } else {
          s.resume();
        }
      }
      return;
    }
    if (state == AppLifecycleState.paused) {
      for (final s in _sessions) {
        s.pause();
      }
    } else if (state == AppLifecycleState.resumed) {
      for (final s in _sessions) {
        s.resume();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final s in _sessions) {
      s.dispose();
    }
    super.dispose();
  }

  Future<void> _fullscreen(CamSession s, int? part) async {
    final others = _sessions.where((o) => o != s);
    for (final o in others) {
      o.pause(); // hidden behind fullscreen: stop decoding
    }
    // Same stream and connection as the tile: no reconnect, same quality.
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _FullPage(s, part, (c) => _toggle(s, c)),
      ),
    );
    for (final o in others) {
      o.resume();
    }
  }

  /// Split and the PTZ options only change the UI; saver mode only restarts
  /// the decoder; UDP / SD need a reconnect.
  void _toggle(CamSession s, Camera next) {
    setState(() {
      if (next.split != s.cam.split ||
          (next.keyframes == s.cam.keyframes &&
              next.udp == s.cam.udp &&
              next.sd == s.cam.sd)) {
        s.cam = next;
      } else if (next.udp == s.cam.udp && next.sd == s.cam.sd) {
        s.setKeyframes(next);
      } else {
        s.update(next);
      }
    });
    saveCameras([for (final x in _sessions) x.cam]);
  }

  Future<void> _settings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsPage()),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    // A split camera (CAM1) fills two cells from the same player.
    final cells = <Widget>[
      for (final s in _sessions)
        for (final part in s.cam.split ? [0, 1] : [null])
          _Cell(
            s,
            part,
            () => _fullscreen(s, part),
            () => setState(() {
              s.setMuted(!s.muted);
            }),
            (c) => _toggle(s, c),
          ),
    ];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Cameras'),
        actions: [
          IconButton(icon: const Icon(Icons.settings), onPressed: _settings),
        ],
      ),
      body: _sessions.isEmpty
          ? const Center(child: Text('No cameras. Add them in settings.'))
          : LayoutBuilder(
              builder: (_, box) => GridView.count(
                crossAxisCount: box.maxWidth > 600 ? 2 : 1,
                childAspectRatio: 16 / 9,
                mainAxisSpacing: 2,
                crossAxisSpacing: 2,
                children: cells,
              ),
            ),
    );
  }
}

/// The live picture, with the last frame of the old stream frozen on top of it
/// while the stream reconnects (instead of black). Both are drawn contained.
Widget _view(CamSession s) => Stack(
  fit: StackFit.expand,
  children: [
    // Keyed, so a swap reorders the videos without remounting the new one:
    // it has been rendering underneath, so no black gap.
    ValueListenableBuilder<List<VideoController>>(
      valueListenable: s.views,
      builder: (_, list, _) => Stack(
        fit: StackFit.expand,
        children: [
          for (final c in list)
            Video(key: ValueKey(c), controller: c, controls: NoVideoControls),
        ],
      ),
    ),
    ValueListenableBuilder<ui.Image?>(
      valueListenable: s.frozen,
      builder: (_, img, _) => img == null
          ? const SizedBox.shrink()
          : IgnorePointer(
              child: RawImage(image: img, fit: BoxFit.contain),
            ),
    ),
  ],
);

/// One lens of a stacked two-lens picture (2304x2592, two 16:9 halves) in a
/// 16:9 box. Video draws it contained (width = height * 2304/2592), so scale it
/// up from the top or bottom edge until that width fills the box and clip to one
/// half. No second decode.
Widget _lens(CamSession s, int part) => LayoutBuilder(
  builder: (_, box) => ClipRect(
    child: Transform.scale(
      scale: box.maxWidth / (box.maxHeight * 2304 / 2592),
      alignment: part == 1 ? Alignment.bottomCenter : Alignment.topCenter,
      child: _view(s),
    ),
  ),
);

/// Spinner while a stream (re)connects; taps pass through.
class _Loading extends StatelessWidget {
  const _Loading(this.s);
  final CamSession s;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: s.loading,
    builder: (_, on, _) => on
        ? const IgnorePointer(
            child: Center(
              child: CircularProgressIndicator(color: Colors.white54),
            ),
          )
        : const SizedBox.shrink(),
  );
}

/// "HD" / "SD" from the height of the stream playing right now (a stacked
/// two-lens picture counts per lens). Hidden until the first frame size is known.
class _QualityBadge extends StatelessWidget {
  const _QualityBadge(this.s);
  final CamSession s;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<VideoController>(
    valueListenable: s.ctl,
    builder: (_, c, _) => StreamBuilder<int?>(
      key: ValueKey(c),
      initialData: c.player.state.height,
      stream: c.player.stream.height,
      builder: (_, snap) {
        var h = snap.data ?? 0;
        if (h == 0) return const SizedBox.shrink();
        if (s.cam.split) h ~/= 2;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            h >= 720 ? 'HD' : 'SD',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
      },
    ),
  );
}

Widget _opt(
  bool on,
  IconData off,
  IconData onIcon,
  String tip,
  VoidCallback f,
) => IconButton(
  isSelected: on,
  color: on ? Colors.white : Colors.white54,
  icon: Icon(off),
  selectedIcon: Icon(onIcon),
  tooltip: '$tip (${on ? 'on' : 'off'})',
  onPressed: f,
);

/// The per-camera option buttons, shared by the grid tile and fullscreen.
List<Widget> _options(CamSession s, void Function(Camera) onChange) => [
  _opt(
    s.cam.keyframes,
    Icons.eco_outlined,
    Icons.eco,
    'Saver mode: shows only keyframes, much less CPU. '
    'Turn off if the picture stays black',
    () => onChange(s.cam.copyWith(keyframes: !s.cam.keyframes)),
  ),
  _opt(
    s.cam.split,
    Icons.splitscreen_outlined,
    Icons.splitscreen,
    'Two lenses: show a stacked two-lens picture as two tiles',
    () => onChange(s.cam.copyWith(split: !s.cam.split)),
  ),
  _opt(
    s.cam.sd,
    Icons.sd_outlined,
    Icons.sd,
    'SD stream: much less CPU. Turn off for HD',
    () => onChange(s.cam.copyWith(sd: !s.cam.sd)),
  ),
  _opt(
    s.cam.udp,
    Icons.settings_ethernet,
    Icons.settings_ethernet,
    'Compatibility connection (UDP): turn on if the picture never loads',
    () => onChange(s.cam.copyWith(udp: !s.cam.udp)),
  ),
];

class _Cell extends StatelessWidget {
  const _Cell(this.s, this.part, this.onTap, this.onMute, this.onChange);
  final CamSession s;
  final int? part; // null = whole picture, 0 = top half, 1 = bottom half
  final VoidCallback onTap, onMute;
  final void Function(Camera) onChange;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (part == null) _view(s) else _lens(s, part!),
          _Loading(s),
          Positioned(top: 6, left: 6, child: _QualityBadge(s)),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            // Swallow taps in the gaps so they don't open fullscreen.
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              child: Container(
                color: Colors.black54,
                padding: const EdgeInsets.only(left: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        s.cam.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    // One player feeds both halves: options only on the top one.
                    if (part != 1) ..._options(s, onChange),
                    IconButton(
                      color: Colors.white,
                      icon: Icon(s.muted ? Icons.volume_off : Icons.volume_up),
                      onPressed: onMute,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FullPage extends StatefulWidget {
  const _FullPage(this.s, this.part, this.onChange);
  final CamSession s;
  final int? part; // tapped half of a split camera, null = normal camera
  final void Function(Camera) onChange;

  @override
  State<_FullPage> createState() => _FullPageState();
}

class _FullPageState extends State<_FullPage> {
  // A split camera opens zoomed on the tapped lens; the button shows it all.
  late bool _zoomed = widget.part != null;

  late final _ptz = Ptz(widget.s.cam);
  bool _canMove = false;
  // Android Home mid-move: dispose does not run then.
  late final _life = AppLifecycleListener(onHide: _ptz.stop);

  @override
  void initState() {
    super.initState();
    _ptz.connect().then((ok) {
      if (mounted) setState(() => _canMove = ok);
    });
  }

  @override
  void dispose() {
    _life.dispose();
    _ptz.stop();
    super.dispose();
  }

  void _setCam(Camera c) {
    widget.onChange(c);
    setState(() {}); // the grid refreshes itself
  }

  // Hold = move, release = stop. With two fingers down, the first release
  // stops both.
  Widget _arrow(IconData icon, String tip, double x, double y) => Listener(
    onPointerDown: (_) => _ptz.move(widget.s.cam.panInvert ? -x : x, y),
    onPointerUp: (_) => _ptz.stop(),
    onPointerCancel: (_) => _ptz.stop(),
    child: Tooltip(
      message: tip,
      child: Container(
        width: 56,
        height: 56,
        decoration: const BoxDecoration(
          color: Colors.black45,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 32),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      title: Text(widget.s.cam.name),
      actions: [
        if (widget.part != null)
          IconButton(
            icon: Icon(_zoomed ? Icons.zoom_out_map : Icons.zoom_in_map),
            tooltip: _zoomed ? 'Show the whole picture' : 'Zoom on this lens',
            onPressed: () => setState(() => _zoomed = !_zoomed),
          ),
        ..._options(widget.s, (c) {
          widget.onChange(c);
          setState(() {}); // refresh the icons here, the grid refreshes itself
        }),
        IconButton(
          icon: Icon(widget.s.muted ? Icons.volume_off : Icons.volume_up),
          onPressed: () => setState(() => widget.s.setMuted(!widget.s.muted)),
        ),
      ],
    ),
    body: Stack(
      fit: StackFit.expand,
      children: [
        if (_zoomed)
          Center(
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: _lens(widget.s, widget.part!),
            ),
          )
        else
          _view(widget.s),
        _Loading(widget.s),
        Positioned(top: 8, left: 8, child: _QualityBadge(widget.s)),
        // Split cameras: only the moving lens (if known) gets arrows when
        // zoomed on a lens. Vertically centered on the right: the bottom edge
        // belongs to the video's own control bar.
        if (_canMove &&
            (widget.s.cam.ptzLens < 0 ||
                !_zoomed ||
                widget.part == widget.s.cam.ptzLens))
          Positioned(
            right: 16,
            top: 0,
            bottom: 0,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _arrow(Icons.keyboard_arrow_up, 'Tilt up', 0, 0.5),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _arrow(Icons.keyboard_arrow_left, 'Pan left', -0.5, 0),
                      const SizedBox(width: 56),
                      _arrow(Icons.keyboard_arrow_right, 'Pan right', 0.5, 0),
                    ],
                  ),
                  _arrow(Icons.keyboard_arrow_down, 'Tilt down', 0, -0.5),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _opt(
                        widget.s.cam.panInvert,
                        Icons.swap_horiz,
                        Icons.swap_horiz,
                        'Invert left/right: turn on if the camera pans the wrong way',
                        () => _setCam(
                          widget.s.cam.copyWith(
                            panInvert: !widget.s.cam.panInvert,
                          ),
                        ),
                      ),
                      if (widget.s.cam.split)
                        IconButton(
                          color: Colors.white,
                          tooltip:
                              'Lens that moves: ${const ['unknown', 'top', 'bottom'][widget.s.cam.ptzLens + 1]}'
                              ' (tap to change)',
                          icon: Icon(
                            const [
                              Icons.unfold_more,
                              Icons.vertical_align_top,
                              Icons.vertical_align_bottom,
                            ][widget.s.cam.ptzLens + 1],
                          ),
                          // unknown -> top -> bottom -> unknown
                          onPressed: () => _setCam(
                            widget.s.cam.copyWith(
                              ptzLens: (widget.s.cam.ptzLens + 2) % 3 - 1,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
