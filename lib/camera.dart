class Camera {
  const Camera({
    required this.name,
    required this.host,
    required this.user,
    required this.pass,
    this.udp = false,
    this.split = false,
    this.keyframes = false,
    this.sd = true,
    this.xm = true,
    this.panInvert = false,
    this.ptzLens = -1,
  });

  final String name, host, user, pass;

  /// RTSP transport. CAM2 (Yoosee) only answers over UDP; mpv defaults to TCP.
  final bool udp;

  /// Stacked two-lens picture (CAM1): show as two cells.
  final bool split;

  /// Grid tile decodes keyframes only (far less CPU); fullscreen always decodes
  /// everything. Only for cameras with a short keyframe interval: with a long
  /// one the tile stays black and the watchdog keeps reconnecting.
  final bool keyframes;

  /// The grid tile plays the low-res stream (SD); off = main stream (HD).
  /// Same for every camera; [xm] only decides which URL gives the SD stream.
  final bool sd;

  /// Xiongmai / iCSee: these ignore the /onvifN path and always send the main
  /// stream, so their SD stream needs the vendor URL (stream=1). Detected: the
  /// session turns it off when that URL never plays (e.g. Yoosee).
  final bool xm;

  /// Left/right arrows are swapped. The cameras report neither this nor the
  /// moving lens (CAM1: mirror/flip are off, one ONVIF source and PTZ config
  /// for both lenses), so it is set once per camera.
  final bool panInvert;

  /// Split cameras: the lens that moves (0 top, 1 bottom), -1 = not set.
  final int ptzLens;

  Camera copyWith({
    bool? udp,
    bool? split,
    bool? keyframes,
    bool? sd,
    bool? xm,
    bool? panInvert,
    int? ptzLens,
  }) => Camera(
    name: name,
    host: host,
    user: user,
    pass: pass,
    udp: udp ?? this.udp,
    split: split ?? this.split,
    keyframes: keyframes ?? this.keyframes,
    sd: sd ?? this.sd,
    xm: xm ?? this.xm,
    panInvert: panInvert ?? this.panInvert,
    ptzLens: ptzLens ?? this.ptzLens,
  );

  /// Port 554 and the /onvif paths worked on all four cameras (see plan.md).
  String url() {
    // Built as a string: Uri(path:) would leave the `&` unescaped.
    if (sd && xm) {
      return 'rtsp://$host:554/user=${Uri.encodeComponent(user)}'
          '&password=${Uri.encodeComponent(pass)}&channel=1&stream=1.sdp?';
    }
    return Uri(
      scheme: 'rtsp',
      // Encoded by hand: a raw `@ : / #` in a password would break the URL.
      userInfo: '${Uri.encodeComponent(user)}:${Uri.encodeComponent(pass)}',
      host: host,
      port: 554,
      path: sd ? '/onvif2' : '/onvif1',
    ).toString();
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'host': host,
    'user': user,
    'pass': pass,
    'udp': udp,
    'split': split,
    'keyframes': keyframes,
    'sd': sd,
    'xm': xm,
    'panInvert': panInvert,
    'ptzLens': ptzLens,
  };

  factory Camera.fromJson(Map<String, dynamic> j) => Camera(
    name: j['name'] as String,
    host: j['host'] as String,
    user: j['user'] as String,
    pass: j['pass'] as String,
    udp: j['udp'] as bool? ?? false,
    split: j['split'] as bool? ?? false,
    keyframes: j['keyframes'] as bool? ?? false,
    sd: j['sd'] as bool? ?? true,
    xm: j['xm'] as bool? ?? true,
    panInvert: j['panInvert'] as bool? ?? false,
    ptzLens: j['ptzLens'] as int? ?? -1,
  );
}
