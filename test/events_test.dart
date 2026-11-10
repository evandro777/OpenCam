import 'package:flutter_test/flutter_test.dart';
import 'package:opencam/events.dart';

String _msg(String topic, String op, String items) =>
    '<wsnt:NotificationMessage><wsnt:Topic Dialect="x">tns1:$topic</wsnt:Topic>'
    '<wsnt:Message><tt:Message UtcTime="t" PropertyOperation="$op">'
    '<tt:Source><tt:SimpleItem Name="VideoSource" Value="V_SRC_000" /></tt:Source>'
    '<tt:Data>$items</tt:Data></tt:Message></wsnt:Message></wsnt:NotificationMessage>';

String _item(String n, String v) => '<tt:SimpleItem Name="$n" Value="$v" />';

void main() {
  // Shapes taken from real PullMessages replies of CAM1/3/4 (Xiongmai).
  final xml =
      '<tev:PullMessagesResponse>'
      '${_msg('RuleEngine/CellMotionDetector/Motion', 'Initialized', _item('IsMotion', 'false'))}'
      '${_msg('RuleEngine/CellMotionDetector/Motion', 'Changed', _item('IsMotion', 'true'))}'
      '${_msg('VideoSource/MotionAlarm', 'Changed', _item('State', 'false'))}'
      '${_msg('Device/Trigger/DigitalInput', 'Changed', '')}'
      '</tev:PullMessagesResponse>';

  test('parseEvents reads topic, operation and data items', () {
    final e = parseEvents(xml);
    expect(e, hasLength(4));
    expect(e[1].topic, 'RuleEngine/CellMotionDetector/Motion');
    expect(e[1].op, 'Changed');
    expect(e[1].data, {'IsMotion': 'true'});
    expect(e[3].data, isEmpty); // Source items are not data
  });

  test('an empty reply has no events', () {
    expect(
      parseEvents('<tev:PullMessagesResponse></tev:PullMessagesResponse>'),
      isEmpty,
    );
  });

  test('an alert survives JSON, and the log keeps the newest $maxAlerts', () {
    final a = (
      host: '10.0.0.5',
      cam: 'Front',
      topic: 'VideoSource/MotionAlarm',
      at: DateTime.fromMillisecondsSinceEpoch(1762700000000),
    );
    expect(alertFromJson(alertToJson(a)), a);
    var log = <Alert>[];
    for (var i = 0; i < maxAlerts + 5; i++) {
      log = addAlert(log, (
        host: 'h',
        cam: 'c',
        topic: 't$i',
        at: DateTime.fromMillisecondsSinceEpoch(i),
      ));
    }
    expect(log, hasLength(maxAlerts));
    expect(log.first.topic, 't${maxAlerts + 4}');
    expect(log.last.topic, 't5');
  });

  test('unlisted topics follow the Others switch', () {
    const known = 'VideoSource/MotionAlarm';
    expect(alertWanted(known, {known}), isTrue);
    expect(
      alertWanted('RuleEngine/CellMotionDetector/Motion', {known}),
      isFalse,
    );
    expect(alertWanted('RuleEngine/Human/Detected', {known}), isFalse);
    expect(alertWanted('RuleEngine/Human/Detected', {alertOthers}), isTrue);
    expect(
      alertWanted(known, {alertOthers}),
      isFalse,
    ); // known ones are separate
  });

  test('alertName keeps the last two topic parts', () {
    expect(
      alertName('RuleEngine/CellMotionDetector/Motion'),
      'CellMotionDetector/Motion',
    );
    expect(alertName('Motion'), 'Motion');
  });

  test('only real changes are alerts', () {
    expect(parseEvents(xml).map(isAlert), [false, true, false, true]);
  });
}
