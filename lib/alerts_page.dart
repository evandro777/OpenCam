import 'package:flutter/material.dart';

import 'events.dart';
import 'fmt.dart';

/// "2026-11-09 16:04:33"
String alertTime(DateTime t) => '${ymd(t)} ${hm(t)}:${two(t.second)}';

/// Every alert shown so far, newest first, filtered by camera and type.
/// Tapping one calls [onOpen].
class AlertsPage extends StatefulWidget {
  const AlertsPage({super.key, required this.onOpen});
  final void Function(Alert) onOpen;

  @override
  State<AlertsPage> createState() => _AlertsPageState();
}

class _AlertsPageState extends State<AlertsPage> {
  String? _host, _topic; // null = all

  /// A filter for [label], choosing among [items] (value, text).
  Widget _filter(
    String label,
    String? value,
    Map<String, String> items,
    ValueChanged<String?> onChanged,
  ) => Expanded(
    child: DropdownButton<String?>(
      isExpanded: true,
      // A choice that left the log (cleared) falls back to "All".
      value: items.containsKey(value) ? value : null,
      hint: Text(label),
      items: [
        DropdownMenuItem(child: Text('$label: all')),
        for (final e in items.entries)
          DropdownMenuItem(value: e.key, child: Text(e.value)),
      ],
      onChanged: onChanged,
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Alerts'),
      actions: [
        IconButton(
          icon: const Icon(Icons.delete_sweep),
          tooltip: 'Clear',
          onPressed: clearAlertLog,
        ),
      ],
    ),
    body: ValueListenableBuilder<List<Alert>>(
      valueListenable: alertLog,
      builder: (_, log, _) {
        final cams = {for (final a in log) a.host: a.cam};
        final types = {for (final a in log) a.topic: alertName(a.topic)};
        final shown = [
          for (final a in log)
            if ((_host == null || a.host == _host) &&
                (_topic == null || a.topic == _topic))
              a,
        ];
        return Column(
          children: [
            if (log.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  spacing: 16,
                  children: [
                    _filter('Camera', _host, cams, (v) {
                      setState(() => _host = v);
                    }),
                    _filter('Type', _topic, types, (v) {
                      setState(() => _topic = v);
                    }),
                  ],
                ),
              ),
            Expanded(
              child: shown.isEmpty
                  ? Center(
                      child: Text(
                        log.isEmpty ? 'No alerts yet' : 'No alerts match',
                      ),
                    )
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (_, i) => ListTile(
                        title: Text(shown[i].cam),
                        subtitle: Text(alertName(shown[i].topic)),
                        trailing: Text(alertTime(shown[i].at)),
                        onTap: () => widget.onOpen(shown[i]),
                      ),
                    ),
            ),
          ],
        );
      },
    ),
  );
}
