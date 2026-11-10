import 'package:flutter/material.dart';

import 'camera.dart';
import 'events.dart' show alertKinds, alertTopics;
import 'rtsp.dart';
import 'scan.dart';
import 'session.dart' show CamProblem, forgetThumb;
import 'store.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({this.problems = const {}, super.key});

  /// What is wrong with a camera right now, by host (from the grid's sessions).
  final Map<String, CamProblem> problems;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  List<Camera> _cams = [];
  // Set when the saved list could not be read: adding is blocked, or saving
  // would overwrite what is stored.
  String? _loadError;

  @override
  void initState() {
    super.initState();
    loadCameras().then(
      (c) {
        if (mounted) setState(() => _cams = c);
      },
      onError: (Object e) {
        if (mounted) setState(() => _loadError = '$e');
      },
    );
  }

  /// [index] null = add. Returning without saving leaves the list untouched.
  Future<void> _edit(int? index) async {
    final old = index == null ? null : _cams[index];
    final name = TextEditingController(text: old?.name);
    final host = TextEditingController(text: old?.host);
    final user = TextEditingController(text: old?.user);
    final pass = TextEditingController(text: old?.pass);
    // Adding: look for cameras as soon as the dialog opens; typing stays free.
    Future<List<Found>>? scan = old == null ? scanCameras() : null;
    // Save checks the login first; force = the check could not tell, so a
    // second tap saves anyway.
    var checking = false, force = false;
    String? problem;

    final action = await showDialog<String>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(old == null ? 'Add camera' : 'Edit camera'),
          content: SingleChildScrollView(
            // Top padding: the outlined label of the first field floats above it.
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 16,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                TextField(
                  controller: host,
                  onChanged: (_) => force = false,
                  decoration: const InputDecoration(labelText: 'Host / IP'),
                ),
                TextField(
                  controller: user,
                  onChanged: (_) => force = false,
                  decoration: const InputDecoration(labelText: 'User'),
                ),
                TextField(
                  controller: pass,
                  obscureText: true,
                  onChanged: (_) => force = false,
                  decoration: const InputDecoration(labelText: 'Password'),
                ),
                if (problem != null)
                  Text(
                    problem!,
                    style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                  ),
                if (scan != null)
                  FutureBuilder<List<Found>>(
                    future: scan,
                    builder: (_, snap) {
                      final known = {for (final c in _cams) c.host};
                      final found = [
                        for (final f in snap.data ?? <Found>[])
                          if (!known.contains(f.ip)) f,
                      ];
                      final busy = snap.connectionState != ConnectionState.done;
                      final status = busy
                          ? 'Searching the network for cameras…'
                          : snap.hasError
                          ? 'Scan failed'
                          : found.isEmpty
                          ? 'No new cameras found'
                          : '${found.length} found, tap to use';
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              if (busy)
                                const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              if (busy) const SizedBox(width: 8),
                              Expanded(child: Text(status)),
                              if (!busy)
                                IconButton(
                                  tooltip: 'Scan again',
                                  icon: const Icon(Icons.refresh),
                                  // Block body: setState rejects a callback that returns a Future.
                                  onPressed: () => setD(() {
                                    scan = scanCameras();
                                  }),
                                ),
                            ],
                          ),
                          for (final f in found)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.videocam_outlined),
                              title: Text(f.name ?? f.hardware ?? f.ip),
                              subtitle: Text(
                                [
                                  f.ip,
                                  if (f.name != null) ?f.hardware,
                                  if (f.firmware != null) 'fw ${f.firmware}',
                                  if (!f.rtsp) 'no RTSP on 554',
                                ].join(' · '),
                              ),
                              selected: host.text == f.ip,
                              onTap: () => setD(() {
                                host.text = f.ip;
                                if (name.text.isEmpty && f.name != null) {
                                  name.text = f.name!;
                                }
                              }),
                            ),
                        ],
                      );
                    },
                  ),
              ],
            ),
          ),
          actions: [
            if (old != null)
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(ctx).colorScheme.error,
                ),
                onPressed: () async {
                  final yes = await showDialog<bool>(
                    context: ctx,
                    builder: (c) => AlertDialog(
                      title: Text('Delete ${old.name}?'),
                      content: const Text(
                        'The camera and its saved password are removed.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(c, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: Theme.of(c).colorScheme.error,
                          ),
                          onPressed: () => Navigator.pop(c, true),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                  if (yes == true && ctx.mounted) Navigator.pop(ctx, 'delete');
                },
                child: const Text('Delete'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: checking
                  ? null
                  : () async {
                      // The host identifies the camera (picture, alerts).
                      final h = host.text.trim();
                      final bad = h.isEmpty
                          ? 'Enter the camera\'s host / IP.'
                          : _cams.any((c) => c.host == h && !identical(c, old))
                          ? 'Another camera already uses this host / IP.'
                          : null;
                      if (bad != null) {
                        return setD(() {
                          problem = bad;
                        });
                      }
                      final same =
                          old != null &&
                          old.host == host.text.trim() &&
                          old.user == user.text.trim() &&
                          old.pass == pass.text;
                      if (same || force) return Navigator.pop(ctx, 'save');
                      setD(() {
                        checking = true;
                        problem = null;
                      });
                      final ok = await checkRtsp(
                        Camera(
                          name: '',
                          host: host.text.trim(),
                          user: user.text.trim(),
                          pass: pass.text,
                        ),
                      );
                      if (!ctx.mounted) return;
                      if (ok == true) return Navigator.pop(ctx, 'save');
                      setD(() {
                        checking = false;
                        // Nothing on the RTSP port: don't block, a second tap saves.
                        force = ok == null;
                        problem = ok == null
                            ? 'Could not check the login (no answer on RTSP port 554). '
                                  'Tap Save again to save anyway.'
                            : 'The video stream refused this login: wrong user or password?';
                      });
                    },
              child: Text(checking ? 'Checking…' : 'Save'),
            ),
          ],
        ),
      ),
    );
    // After the closing animation: the fields still listen to these until then.
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      for (final c in [name, host, user, pass]) {
        c.dispose();
      }
    });
    if (action == null) return;
    final newHost = host.text.trim(); // the controller is disposed soon

    final next = [..._cams];
    if (action == 'delete') {
      next.removeAt(index!);
    } else {
      final cam = Camera(
        name: name.text.trim().isEmpty ? newHost : name.text.trim(),
        host: newHost,
        user: user.text.trim(),
        pass: pass.text,
        // Toggled on the grid tiles, so an edit keeps them.
        udp: old?.udp ?? false,
        split: old?.split ?? false,
        keyframes: old?.keyframes ?? false,
        sd: old?.sd ?? true,
        xm: old?.xm ?? true,
        panInvert: old?.panInvert ?? false,
        ptzLens: old?.ptzLens ?? -1,
      );
      index == null ? next.add(cam) : next[index] = cam;
    }
    await saveCameras(next);
    // Its saved picture goes with it (or with the old IP of a moved camera).
    if (old != null && (action == 'delete' || old.host != newHost)) {
      await forgetThumb(old.host);
    }
    if (mounted) setState(() => _cams = next);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _loadError == null ? () => _edit(null) : null,
      icon: const Icon(Icons.add),
      label: const Text('Add camera'),
    ),
    body: ListView(
      // Room below the last row so the button never covers it.
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        ListTile(
          leading: const Icon(Icons.notifications_outlined),
          title: const Text('Alerts'),
          subtitle: const Text('Which events notify you'),
          onTap: _alertKinds,
        ),
        const Divider(height: 1),
        if (_loadError != null)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Cannot read the saved cameras: $_loadError',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          )
        else if (_cams.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(
              child: Text('No cameras yet. Tap Add camera to start.'),
            ),
          ),
        ...[
          for (final (i, c) in _cams.indexed)
            ListTile(
              leading: widget.problems[c.host] == null
                  ? const Icon(Icons.videocam_outlined)
                  : Icon(
                      Icons.error_outline,
                      color: Theme.of(context).colorScheme.error,
                    ),
              title: Text(c.name),
              subtitle: Text(
                [
                  c.host,
                  if (c.udp) 'UDP',
                  if (widget.problems[c.host] case final p?)
                    switch (p) {
                      CamProblem.refused => 'Login refused',
                      CamProblem.unreachable => 'No answer',
                      CamProblem.noPicture => 'No picture',
                    },
                ].join(' · '),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _edit(i),
            ),
        ],
      ],
    ),
  );

  Future<void> _alertKinds() => showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Alerts'),
      content: ValueListenableBuilder<Set<String>>(
        valueListenable: alertTopics,
        builder: (_, on, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (topic, label) in alertKinds)
              CheckboxListTile(
                title: Text(label),
                value: on.contains(topic),
                onChanged: (v) {
                  final next = {...on};
                  v == true ? next.add(topic) : next.remove(topic);
                  alertTopics.value = next;
                  saveAlertTopics(next);
                },
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
