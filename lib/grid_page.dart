import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:media_kit_video/media_kit_video.dart';

import 'alerts_page.dart';
import 'camera.dart';
import 'events.dart';
import 'notify.dart';
import 'onvif.dart';
import 'ptz.dart';
import 'recordings_page.dart';
import 'session.dart';
import 'settings_page.dart';
import 'store.dart';
import 'stream_export.dart';

class GridPage extends StatefulWidget {
  const GridPage({super.key});

  @override
  State<GridPage> createState() => _GridPageState();
}

class _GridPageState extends State<GridPage> with WidgetsBindingObserver {
  List<CamSession> _sessions = [];
  late final StreamSubscription<String> _taps;
  bool _inSettings = false, _autoChanged = false; // see onAutoChange

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _taps = notificationTaps.stream.listen(_openPayload);
    _startup();
  }

  Future<void> _startup() async {
    try {
      alertTopics.value = await loadAlertTopics() ?? alertTopics.value;
      await loadAlertLog();
      await _load();
    } catch (e) {
      // Keyring locked or missing, or damaged data: say so instead of an
      // empty grid that looks like "no cameras".
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cannot read the saved cameras: $e')),
        );
      }
      return;
    }
    final p = await launchPayload(); // the app was started by a notification
    if (p != null) _openPayload(p);
  }

  /// A tapped notification: its payload is the alert's time in ms.
  void _openPayload(String p) {
    final a = alertLog.value
        .where((a) => '${a.at.millisecondsSinceEpoch}' == p)
        .firstOrNull;
    if (a != null && mounted) _openAlert(a);
  }

  /// Plays the recording of [a] on its camera (live view pauses meanwhile).
  Future<void> _openAlert(Alert a) async {
    final s = _sessions.where((s) => s.cam.host == a.host).firstOrNull;
    if (s == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${a.cam} is no longer in the camera list')),
      );
      return;
    }
    s.pause();
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => RecordingsPage(s.cam, at: a.at)),
    );
    s.resume();
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
              // Settings has its own copy of the list: saving ours now could
              // overwrite what is being edited there. Saved when it closes.
              if (_inSettings) {
                _autoChanged = true;
              } else {
                saveCameras([for (final x in _sessions) x.cam]);
              }
            },
          ),
      ],
    );
    for (final s in _sessions) {
      s.events.start();
    }
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
        s.events.stop(); // no background service: events only while visible
      }
    } else if (state == AppLifecycleState.resumed) {
      for (final s in _sessions) {
        s.resume();
        s.events.start();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _taps.cancel();
    for (final s in _sessions) {
      s.dispose();
    }
    super.dispose();
  }

  Future<void> _fullscreen(CamSession s, int? part) async {
    // A stopped camera plays only while it is open alone, then goes back to
    // its thumbnail (the grid keeps it stopped).
    final wasStopped = s.stopped.value;
    if (wasStopped) s.start();
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
    if (wasStopped) s.stop();
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
    String sig(List<Camera> l) => jsonEncode([for (final c in l) c.toJson()]);
    final before = sig([for (final s in _sessions) s.cam]);
    _inSettings = true;
    _autoChanged = false;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          problems: {for (final s in _sessions) s.cam.host: ?s.problem.value},
        ),
      ),
    );
    _inSettings = false;
    // Unchanged list: keep the running streams instead of reconnecting all.
    // A list Settings changed wins over a session's own change (that one is
    // found again after the reload).
    if (sig(await loadCameras()) != before) {
      _load();
    } else if (_autoChanged) {
      saveCameras([for (final x in _sessions) x.cam]);
    }
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
          if (_sessions.isNotEmpty)
            ListenableBuilder(
              listenable: Listenable.merge([
                for (final s in _sessions) s.stopped,
              ]),
              builder: (_, _) {
                final anyStopped = _sessions.any((s) => s.stopped.value);
                return IconButton(
                  icon: Icon(
                    anyStopped ? Icons.play_circle : Icons.stop_circle,
                  ),
                  tooltip: anyStopped ? 'Play all' : 'Stop all',
                  onPressed: () {
                    for (final s in _sessions) {
                      anyStopped ? s.start() : s.stop();
                    }
                  },
                );
              },
            ),
          IconButton(
            icon: const Icon(Icons.notifications),
            tooltip: 'Alerts',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => AlertsPage(onOpen: _openAlert)),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: _settings,
          ),
        ],
      ),
      body: _sessions.isEmpty
          ? Center(
              child: FilledButton.icon(
                onPressed: _settings,
                icon: const Icon(Icons.add),
                label: const Text('Add a camera'),
              ),
            )
          // Grey gaps: letterboxed video is black too, so tiles would merge.
          : ColoredBox(
              color: const Color(0xFF1C1C1C),
              child: LayoutBuilder(
                builder: (_, box) => GridView.count(
                  crossAxisCount: box.maxWidth > 600 ? 2 : 1,
                  childAspectRatio: 16 / 9,
                  mainAxisSpacing: 3,
                  crossAxisSpacing: 3,
                  children: cells,
                ),
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

/// Spinner while a stream (re)connects, the play button when it is stopped,
/// and under them in words why it does not play (login refused, no answer...).
/// The picture's taps pass through, only the play button takes one.
class _Loading extends StatelessWidget {
  const _Loading(this.s);
  final CamSession s;

  static String _text(CamProblem p, String host) => switch (p) {
    CamProblem.refused =>
      'Login refused. Update the user and password in Settings.',
    CamProblem.unreachable =>
      'No answer from $host. Is the camera on and on this network?',
    CamProblem.noPicture => 'Connected, but no picture. Try UDP or turn off Saver mode in the options.',
  };

  static IconData _icon(CamProblem p) => switch (p) {
    CamProblem.refused => Icons.lock_outline,
    CamProblem.unreachable => Icons.wifi_off,
    CamProblem.noPicture => Icons.videocam_off_outlined,
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([s.loading, s.stopped, s.problem]),
    builder: (_, _) {
      final p = s.problem.value;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (s.loading.value)
              const IgnorePointer(
                child: CircularProgressIndicator(color: Colors.white54),
              )
            // Stopped: this small button plays it here in the grid; a tap on
            // the picture elsewhere opens the camera alone.
            else if (s.stopped.value)
              IconButton(
                iconSize: 32,
                color: Colors.white,
                style: IconButton.styleFrom(backgroundColor: Colors.black54),
                icon: const Icon(Icons.play_arrow),
                tooltip: p == null ? 'Play here' : 'Try again',
                onPressed: s.start,
              ),
            if (p != null)
              IgnorePointer(
                child: Container(
                  margin: const EdgeInsets.all(8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 8,
                    children: [
                      Icon(_icon(p), size: 16, color: Colors.white70),
                      Flexible(
                        child: Text(
                          _text(p, s.cam.host),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    },
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

/// Toggle button with a tinted chip when on (the PTZ panel's invert switch).
Widget _opt(
  bool on,
  IconData off,
  IconData onIcon,
  String tip,
  VoidCallback f,
) => Builder(
  builder: (context) => IconButton(
    isSelected: on,
    visualDensity: VisualDensity.compact,
    // On = tinted chip, off = dim icon.
    style: IconButton.styleFrom(
      backgroundColor: on
          ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.35)
          : null,
    ),
    color: on ? Colors.white : Colors.white54,
    icon: Icon(off),
    selectedIcon: Icon(onIcon),
    tooltip: '$tip (${on ? 'on' : 'off'})',
    onPressed: f,
  ),
);

/// The per-camera setup switches, one menu in fullscreen. Each says what it
/// does in its own words, so no long-press on a tooltip is needed.
Widget _optionsMenu(CamSession s, void Function(Camera) onChange) {
  final c = s.cam;
  PopupMenuEntry<void> item(bool on, String title, String hint, Camera next) =>
      CheckedPopupMenuItem<void>(
        checked: on,
        onTap: () => onChange(next),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title),
            Text(
              hint,
              style: const TextStyle(fontSize: 12, color: Colors.white60),
            ),
          ],
        ),
      );
  return PopupMenuButton<void>(
    icon: const Icon(Icons.tune),
    tooltip: 'Camera options',
    itemBuilder: (_) => [
      item(
        c.keyframes,
        'Saver mode',
        'Shows only keyframes, much less CPU. Turn off if the picture stays black',
        c.copyWith(keyframes: !c.keyframes),
      ),
      item(
        c.split,
        'Two lenses',
        'Show a stacked two-lens picture as two tiles',
        c.copyWith(split: !c.split),
      ),
      item(
        c.sd,
        'SD stream',
        'Much less CPU. Turn off for HD',
        c.copyWith(sd: !c.sd),
      ),
      item(
        c.udp,
        'Compatibility connection (UDP)',
        'Turn on if the picture never loads',
        c.copyWith(udp: !c.udp),
      ),
    ],
  );
}

/// Last camera alert on the tile; tap to dismiss (it also fades after a minute).
class _AlertBadge extends StatelessWidget {
  const _AlertBadge(this.alert);
  final ValueNotifier<String?> alert;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String?>(
    valueListenable: alert,
    builder: (_, text, _) => text == null
        ? const SizedBox.shrink()
        : GestureDetector(
            onTap: () => alert.value = null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.red.shade700,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                text,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
  );
}

class _Cell extends StatelessWidget {
  const _Cell(this.s, this.part, this.onTap, this.onMute, this.onChange);
  final CamSession s;
  final int? part; // null = whole picture, 0 = top half, 1 = bottom half
  final VoidCallback onTap, onMute;
  final void Function(Camera) onChange;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: GestureDetector(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (part == null) _view(s) else _lens(s, part!),
            _Loading(s),
            Positioned(top: 6, left: 6, child: _QualityBadge(s)),
            Positioned(top: 6, right: 6, child: _AlertBadge(s.events.alert)),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              // Swallow taps in the gaps so they don't open fullscreen.
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black87],
                    ),
                  ),
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
                      if (part != 1) _optionsMenu(s, onChange),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        color: Colors.white,
                        icon: Icon(
                          s.muted ? Icons.volume_off : Icons.volume_up,
                        ),
                        tooltip: s.muted ? 'Unmute' : 'Mute',
                        onPressed: onMute,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A PTZ arrow that lights up while held, so the hold is visibly registered.
class _Arrow extends StatefulWidget {
  const _Arrow(this.icon, this.tip, this.onDown, this.onUp);
  final IconData icon;
  final String tip;
  final VoidCallback onDown, onUp;

  @override
  State<_Arrow> createState() => _ArrowState();
}

class _ArrowState extends State<_Arrow> {
  bool _down = false;

  void _press(bool down) {
    setState(() => _down = down);
    down ? widget.onDown() : widget.onUp();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => _press(true),
    onPointerUp: (_) => _press(false),
    onPointerCancel: (_) => _press(false),
    child: Tooltip(
      message: widget.tip,
      child: Semantics(
        button: true,
        label: widget.tip,
        excludeSemantics: true,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: _down
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.7)
                : Colors.black54,
            shape: BoxShape.circle,
          ),
          child: Icon(widget.icon, color: Colors.white, size: 32),
        ),
      ),
    ),
  );
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

  // Live view stops while a clip plays: no two decodes at once.
  Future<void> _recordings() async {
    widget.s.pause();
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => RecordingsPage(widget.s.cam)),
    );
    widget.s.resume();
  }

  void _info() {
    final cam = widget.s.cam;
    final url = cam.pass.isEmpty ? cam.url() : maskPass(cam.url());
    final fixed = <(String, String)>[
      ('Name', cam.name),
      ('IP', cam.host),
      ('RTSP URL', url),
      ('Transport', cam.udp ? 'UDP' : 'TCP'),
      ('Grid stream', cam.sd ? 'SD' : 'HD'),
      ('Camera-specific SD address', cam.xm ? 'yes' : 'no'),
    ];
    final live = widget.s.streamInfo(), onvif = onvifInfo(cam);
    // Once, not in the builder: a new Future per rebuild resets the dialog.
    final both = (live, onvif).wait;
    showDialog<void>(
      context: context,
      builder: (_) => FutureBuilder<(List<(String, String)>, OnvifInfo)>(
        future: both,
        builder: (ctx, snap) {
          final data = snap.data;
          final rest = [...?data?.$1, ...?data?.$2.rows];
          Widget table(List<(String, String)> rows) => Table(
            columnWidths: const {0: IntrinsicColumnWidth()},
            children: [
              for (final (k, v) in rows)
                TableRow(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(0, 4, 16, 4),
                      child: Text(
                        k,
                        style: TextStyle(color: Theme.of(ctx).hintColor),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: SelectableText(v),
                    ),
                  ],
                ),
            ],
          );
          return AlertDialog(
            title: const Text('Camera info'),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    table(fixed),
                    // What the camera itself reports, apart from the app's settings.
                    if (rest.isNotEmpty) ...[
                      const Divider(height: 24),
                      table(rest),
                    ],
                    if (data == null)
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: LinearProgressIndicator(),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                // Cameras without ONVIF still export the app's own HD/SD URLs.
                onPressed: data == null
                    ? null
                    : () => _export(cam, [
                        ...data.$2.streams,
                        if (data.$2.streams.isEmpty)
                          for (final (n, sd) in [('HD', false), ('SD', true)])
                            (n, cam.copyWith(sd: sd).url()),
                      ]),
                child: const Text('Export command'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Pick a stream and a player, copy the resulting shell line. The password
  /// is hidden on screen but is in the copied line.
  void _export(Camera cam, List<(String, String)> streams) {
    var stream = 0, player = players.first;
    showDialog<void>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) {
          final cmd = playCommand(cam, streams[stream].$2, player);
          final shown = cam.pass.isEmpty ? cmd : maskPass(cmd);
          return AlertDialog(
            title: const Text('Export command'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownMenu<int>(
                    expandedInsets: EdgeInsets.zero,
                    label: const Text('Stream'),
                    initialSelection: stream,
                    requestFocusOnTap: false,
                    inputDecorationTheme: const InputDecorationTheme(
                      border: OutlineInputBorder(),
                    ),
                    dropdownMenuEntries: [
                      for (var i = 0; i < streams.length; i++)
                        DropdownMenuEntry(value: i, label: streams[i].$1),
                    ],
                    onSelected: (v) => setD(() => stream = v ?? stream),
                  ),
                  const SizedBox(height: 16),
                  DropdownMenu<String>(
                    expandedInsets: EdgeInsets.zero,
                    label: const Text('Player'),
                    initialSelection: player,
                    requestFocusOnTap: false,
                    inputDecorationTheme: const InputDecorationTheme(
                      border: OutlineInputBorder(),
                    ),
                    dropdownMenuEntries: [
                      for (final p in players)
                        DropdownMenuEntry(value: p, label: p),
                    ],
                    onSelected: (v) => setD(() => player = v ?? player),
                  ),
                  const SizedBox(height: 16),
                  SelectableText(shown),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: cmd));
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Command copied')),
                  );
                },
                child: const Text('Copy'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _setCam(Camera c) {
    widget.onChange(c);
    setState(() {}); // the grid refreshes itself
  }

  // Hold = move, release = stop. With two fingers down, the first release
  // stops both.
  Widget _arrow(IconData icon, String tip, double x, double y) => _Arrow(
    icon,
    tip,
    () => _ptz.move(widget.s.cam.panInvert ? -x : x, y),
    _ptz.stop,
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
        IconButton(
          icon: const Icon(Icons.info_outline),
          tooltip: 'Camera info',
          onPressed: _info,
        ),
        IconButton(
          icon: const Icon(Icons.video_library),
          tooltip: 'Recordings',
          onPressed: _recordings,
        ),
        _optionsMenu(widget.s, _setCam),
        IconButton(
          icon: Icon(widget.s.muted ? Icons.volume_off : Icons.volume_up),
          tooltip: widget.s.muted ? 'Unmute' : 'Mute',
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
