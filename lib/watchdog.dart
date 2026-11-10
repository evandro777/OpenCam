import 'dart:math';

/// What the 3-second watchdog of a camera session should do next.
enum WatchAct {
  /// Nothing (all fine, backing off, or a diagnosis is running).
  none,

  /// First failure of a streak: find out why (login check) before retrying.
  diagnose,

  /// The vendor SD URL never played and there is no DVRIP port: use /onvif2.
  dropVendorSd,

  /// Reconnect now.
  reopen,
}

/// What the watchdog knows at a tick. [moved] = the playback position changed
/// since the last tick.
typedef WatchIn = ({
  bool moved,
  int stale,
  int skip,
  int fails,
  bool played,
  bool dead,
  bool saver,
  bool diagnosing,
  bool diagnosed,
  bool vendorSd, // cam.sd && cam.xm
  bool icsee,
});

typedef WatchOut = ({
  WatchAct act,
  int stale,
  int skip,
  int fails,
  bool played,
});

/// One watchdog tick as a pure function (see CamSession._tick for the effects).
/// A wrong login stops all tries elsewhere; here a camera that played before
/// is retried within ~15 s and one that never played backs off up to ~5 min,
/// so a bad setup cannot hammer the camera.
WatchOut watchStep(WatchIn s) {
  final fails = s.moved ? 0 : s.fails;
  final played = s.played || s.moved;
  final stale = s.moved ? 0 : s.stale + 1;
  WatchOut out(WatchAct a, {int? skip, int? f}) => (
    act: a,
    stale: stale,
    skip: skip ?? s.skip,
    fails: f ?? fails,
    played: played,
  );
  if (s.skip > 0) return out(WatchAct.none, skip: s.skip - 1);
  // Keyframes-only: the picture only moves once per keyframe interval, so
  // wait ~30 s (not ~9 s) before calling the stream dead.
  if (!s.dead && stale < (s.saver ? 10 : 3)) return out(WatchAct.none);
  if (s.diagnosing) return out(WatchAct.none);
  if (!s.diagnosed) return out(WatchAct.diagnose);
  final f = fails + 1;
  if (s.vendorSd && !s.icsee && !played && f >= 2) {
    return out(WatchAct.dropVendorSd, f: 0, skip: 0);
  }
  return out(WatchAct.reopen, f: f, skip: played ? min(f, 5) : min(f * f, 100));
}
