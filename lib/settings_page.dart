import 'package:flutter/material.dart';

import 'camera.dart';
import 'scan.dart';
import 'store.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  List<Camera> _cams = [];

  @override
  void initState() {
    super.initState();
    loadCameras().then((c) => setState(() => _cams = c));
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

    final action = await showDialog<String>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(old == null ? 'Add camera' : 'Edit camera'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                TextField(
                  controller: host,
                  decoration: const InputDecoration(labelText: 'Host / IP'),
                ),
                TextField(
                  controller: user,
                  decoration: const InputDecoration(labelText: 'User'),
                ),
                TextField(
                  controller: pass,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Password'),
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
                          const SizedBox(height: 16),
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
                                  onPressed: () =>
                                      setD(() => scan = scanCameras()),
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
                onPressed: () => Navigator.pop(ctx, 'delete'),
                child: const Text('Delete'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'save'),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (action == null) return;

    final next = [..._cams];
    if (action == 'delete') {
      next.removeAt(index!);
    } else {
      final cam = Camera(
        name: name.text.trim(),
        host: host.text.trim(),
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
    setState(() => _cams = next);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    floatingActionButton: FloatingActionButton(
      onPressed: () => _edit(null),
      child: const Icon(Icons.add),
    ),
    body: ListView(
      children: [
        for (final (i, c) in _cams.indexed)
          ListTile(
            title: Text(c.name),
            subtitle: Text('${c.host}${c.udp ? ' · UDP' : ''}'),
            onTap: () => _edit(i),
          ),
      ],
    ),
  );
}
