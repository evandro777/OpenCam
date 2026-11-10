import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'camera.dart';
import 'fmt.dart';
import 'notify.dart';
import 'onvif.dart';

typedef Event = ({String topic, String op, Map<String, String> data});

/// One alert the app showed. [host] ties it to a camera, [at] is the phone's
/// clock when it arrived.
typedef Alert = ({String host, String cam, String topic, DateTime at});

const maxAlerts = 500;

/// The topics the cameras were seen to send, with a label for Settings.
const alertKinds = <(String, String)>[
  ('VideoSource/MotionAlarm', 'Motion alarm'),
  ('RuleEngine/CellMotionDetector/Motion', 'Cell motion detector'),
  ('RuleEngine/TamperDetector/Tamper', 'Tamper (camera covered or moved)'),
  ('Device/Trigger/DigitalInput', 'Digital input'),
  (alertOthers, 'Others (any event not listed above)'),
];

/// Stands for every topic that is not in [alertKinds].
const alertOthers = '*';

/// Is [topic] switched on in [on]? Unknown topics follow [alertOthers].
bool alertWanted(String topic, Set<String> on) =>
    on.contains(alertKinds.any((k) => k.$1 == topic) ? topic : alertOthers);

/// Topics that raise an alert (badge, notification, log). One motion makes
/// the camera send both motion topics, so only the alarm is on by default.
final alertTopics = ValueNotifier<Set<String>>({'VideoSource/MotionAlarm'});

/// "Trigger/DigitalInput": the last two parts of an ONVIF topic.
String alertName(String topic) =>
    topic.split('/').reversed.take(2).toList().reversed.join('/');

Map<String, dynamic> alertToJson(Alert a) => {
  'host': a.host,
  'cam': a.cam,
  'topic': a.topic,
  'at': a.at.millisecondsSinceEpoch,
};

Alert alertFromJson(Map<String, dynamic> j) => (
  host: j['host'] as String,
  cam: j['cam'] as String,
  topic: j['topic'] as String,
  at: DateTime.fromMillisecondsSinceEpoch(j['at'] as int),
);

/// [a] first, the log cut to the newest [maxAlerts].
List<Alert> addAlert(List<Alert> log, Alert a) =>
    [a, ...log].take(maxAlerts).toList();

/// Every alert shown so far, newest first; kept in `alerts.json`.
final alertLog = ValueNotifier<List<Alert>>([]);

Future<File> _logFile() async =>
    File('${(await getApplicationSupportDirectory()).path}/alerts.json');

Future<void> loadAlertLog() async {
  try {
    final f = await _logFile();
    if (!await f.exists()) return;
    final old = [
      for (final j in jsonDecode(await f.readAsString()) as List)
        alertFromJson(j as Map<String, dynamic>),
    ];
    // An alert may have come in while this was reading: it stays first.
    alertLog.value = [...alertLog.value, ...old].take(maxAlerts).toList();
  } catch (e) {
    debugPrint('alert log unreadable: $e');
  }
}

Future<void> _saving = Future.value();

/// One save at a time (cameras alert together), written to a temp file and
/// renamed over the real one so a crash never leaves half a log.
Future<void> _saveAlertLog() => _saving = _saving.then((_) async {
  try {
    final f = await _logFile();
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(
      jsonEncode([for (final a in alertLog.value) alertToJson(a)]),
      flush: true,
    );
    await tmp.rename(f.path);
  } catch (e) {
    debugPrint('cannot save alert log: $e');
  }
});

Future<void> clearAlertLog() async {
  alertLog.value = [];
  await _saveAlertLog();
}

/// The notifications in an ONVIF PullMessages reply. [Event.topic] has its
/// namespace prefix dropped ("RuleEngine/CellMotionDetector/Motion").
List<Event> parseEvents(String xml) {
  final out = <Event>[];
  for (final m in RegExp(
    r'<(?:\w+:)?NotificationMessage>(.*?)</(?:\w+:)?NotificationMessage>',
    dotAll: true,
  ).allMatches(xml)) {
    final n = m.group(1)!;
    final topic = RegExp(r'<(?:\w+:)?Topic[^>]*>\s*(?:\w+:)?([^<\s]+)')
        .firstMatch(n)
        ?.group(1);
    if (topic == null) continue;
    final data = RegExp(
      r'<(?:\w+:)?Data>(.*?)</(?:\w+:)?Data>',
      dotAll: true,
    ).firstMatch(n)?.group(1);
    out.add((
      topic: topic,
      op: RegExp(r'PropertyOperation="(\w+)"').firstMatch(n)?.group(1) ?? '',
      data: {
        for (final i in RegExp(
          r'Name="([^"]*)"\s+Value="([^"]*)"',
        ).allMatches(data ?? ''))
          i.group(1)!: i.group(2)!,
      },
    ));
  }
  return out;
}

/// Something happened: not the state dump a new subscription starts with
/// ("Initialized"), and not the "motion ended" half (every value false).
bool isAlert(Event e) =>
    e.op != 'Initialized' &&
    !(e.data.isNotEmpty && e.data.values.every((v) => v == 'false'));

const _subscribe =
    '<tev:CreatePullPointSubscription><tev:InitialTerminationTime>PT10M'
    '</tev:InitialTerminationTime></tev:CreatePullPointSubscription>';
const _pull =
    '<tev:PullMessages><tev:Timeout>PT10S</tev:Timeout>'
    '<tev:MessageLimit>20</tev:MessageLimit></tev:PullMessages>';

/// Alerts of one camera over ONVIF PullPoint, while [start]ed. Only a
/// connected client gets events, so nothing arrives while stopped.
class CamEvents {
  CamEvents(this.cam);
  final Camera cam;

  /// Last alert ("Motion 14:03"), cleared after a minute or by the user.
  final alert = ValueNotifier<String?>(null);

  int _gen = 0; // a loop runs only while it is the current generation
  (String, int)? _service; // events URL and its ONVIF port
  final _seen = <String, DateTime>{};
  Timer? _clear;

  void start() => _loop(++_gen);
  void stop() => _gen++;

  void dispose() {
    stop();
    _clear?.cancel();
    alert.dispose();
  }

  Future<void> _loop(int g) async {
    // Pause between tries: doubles on every failure up to 5 min, so a wrong
    // password (or a camera that is off) is not retried every 15 s.
    var pause = 15;
    while (g == _gen) {
      try {
        final pull = await _open();
        if (pull == null) return; // no events service (e.g. CAM2): give up
        pause = 15;
        while (g == _gen) {
          final xml = await onvifSoap(
            cam,
            pull,
            _pull,
            timeout: const Duration(seconds: 15),
          );
          if (g != _gen) return;
          for (final e in parseEvents(xml).where(isAlert)) {
            _fire(e);
          }
        }
      } catch (e) {
        debugPrint('${cam.name}: events: $e');
      }
      // shortcut: no Renew, a dropped subscription is made again after this
      // pause; add Renew if a camera loses events at the 10 min mark.
      await Future<void>.delayed(Duration(seconds: pause));
      pause = min(pause * 2, 300);
    }
  }

  /// Subscribes and returns the address to pull from, null if the camera has
  /// no events service.
  Future<String?> _open() async {
    final s = _service ??= await _find();
    if (s == null) return null;
    final r = await onvifSoap(cam, s.$1, _subscribe);
    final addr = RegExp(r'<(?:\w+:)?Address[^>]*>([^<]+)<')
        .firstMatch(r)
        ?.group(1);
    if (addr == null) throw 'no subscription address';
    // Some cameras report a wrong IP of their own (192.168.1.10): keep the
    // path, use the address we reached them on.
    return addr.replaceFirst(RegExp(r'//[^/]+'), '//${cam.host}:${s.$2}');
  }

  /// Throws if no ONVIF port answers (camera off: try again later); null if
  /// one answers but offers no events.
  Future<(String, int)?> _find() async {
    var reached = false;
    final found = await firstOnvif<(String, int)>((p) async {
      final l = await onvifServices(cam, p);
      reached = true;
      final u = l.where((x) => x.contains('event')).firstOrNull;
      return u == null ? null : (u, p);
    });
    if (!reached) throw 'no ONVIF answer';
    return found;
  }

  void _fire(Event e) {
    if (!alertWanted(e.topic, alertTopics.value)) return;
    final now = DateTime.now();
    final last = _seen[e.topic];
    if (last != null && now.difference(last) < const Duration(seconds: 30)) {
      return;
    }
    _seen[e.topic] = now;
    final name = alertName(e.topic);
    alert.value = '$name ${hm(now)}';
    _clear?.cancel();
    _clear = Timer(const Duration(seconds: 60), () => alert.value = null);
    alertLog.value = addAlert(alertLog.value, (
      host: cam.host,
      cam: cam.name,
      topic: e.topic,
      at: now,
    ));
    _saveAlertLog();
    showAlert(cam.name, name, '${now.millisecondsSinceEpoch}');
  }
}
