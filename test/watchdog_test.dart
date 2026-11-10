import 'package:flutter_test/flutter_test.dart';
import 'package:opencam/watchdog.dart';

WatchIn _in({
  bool moved = false,
  int stale = 0,
  int skip = 0,
  int fails = 0,
  bool played = false,
  bool dead = false,
  bool saver = false,
  bool diagnosing = false,
  bool diagnosed = true,
  bool vendorSd = false,
  bool icsee = false,
}) => (
  moved: moved,
  stale: stale,
  skip: skip,
  fails: fails,
  played: played,
  dead: dead,
  saver: saver,
  diagnosing: diagnosing,
  diagnosed: diagnosed,
  vendorSd: vendorSd,
  icsee: icsee,
);

void main() {
  test('a moving picture resets the streak and marks it played', () {
    final r = watchStep(_in(moved: true, stale: 2, fails: 3));
    expect((r.act, r.stale, r.fails, r.played), (WatchAct.none, 0, 0, true));
  });

  test('a frozen picture waits 3 ticks, 10 in saver mode', () {
    expect(watchStep(_in(stale: 1)).act, WatchAct.none); // stale 2
    expect(watchStep(_in(stale: 2)).act, WatchAct.reopen); // stale 3
    expect(watchStep(_in(stale: 2, saver: true)).act, WatchAct.none);
    expect(watchStep(_in(stale: 9, saver: true)).act, WatchAct.reopen);
  });

  test('first failure only diagnoses, and not twice at once', () {
    expect(watchStep(_in(dead: true, diagnosed: false)).act, WatchAct.diagnose);
    expect(
      watchStep(_in(dead: true, diagnosed: false, diagnosing: true)).act,
      WatchAct.none,
    );
  });

  test('a camera that never played backs off by fails squared, max 100', () {
    var r = watchStep(_in(dead: true, fails: 2));
    expect((r.act, r.fails, r.skip), (WatchAct.reopen, 3, 9));
    r = watchStep(_in(dead: true, fails: 50));
    expect(r.skip, 100);
  });

  test('a camera that played is retried soon: skip is fails, max 5', () {
    var r = watchStep(_in(dead: true, played: true, fails: 1));
    expect((r.fails, r.skip), (2, 2));
    r = watchStep(_in(dead: true, played: true, fails: 20));
    expect(r.skip, 5);
  });

  test('skip counts down without acting', () {
    final r = watchStep(_in(dead: true, skip: 4));
    expect((r.act, r.skip), (WatchAct.none, 3));
  });

  test('vendor SD that never played on a non-DVRIP camera is dropped', () {
    expect(watchStep(_in(dead: true, vendorSd: true)).act, WatchAct.reopen);
    final r = watchStep(_in(dead: true, vendorSd: true, fails: 1));
    expect((r.act, r.fails, r.skip), (WatchAct.dropVendorSd, 0, 0));
    // An iCSee camera, or one that played, keeps its URL.
    expect(
      watchStep(_in(dead: true, vendorSd: true, fails: 1, icsee: true)).act,
      WatchAct.reopen,
    );
    expect(
      watchStep(_in(dead: true, vendorSd: true, fails: 1, played: true)).act,
      WatchAct.reopen,
    );
  });
}
