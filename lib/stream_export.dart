import 'camera.dart';

/// Desktop players [playCommand] can write a line for.
const players = ['mpv', 'ffplay', 'VLC', 'ffmpeg (save to file)'];

/// Shell line that opens [url] (with login) in [player], one of [players].
String playCommand(Camera cam, String url, String player) {
  final u = "'${url.replaceAll("'", r"'\''")}'";
  final tcp = !cam.udp;
  return switch (player) {
    'ffplay' => 'ffplay -rtsp_transport ${tcp ? 'tcp' : 'udp'} $u',
    'VLC' => 'vlc ${tcp ? '--rtsp-tcp ' : ''}$u',
    'ffmpeg (save to file)' =>
      'ffmpeg -rtsp_transport ${tcp ? 'tcp' : 'udp'} -i $u -c copy out.mp4',
    _ => 'mpv --rtsp-transport=${tcp ? 'tcp' : 'udp'} $u',
  };
}

/// [s] (a stream URL or a shell line holding one) with the password hidden.
/// Only the password field is touched, so a short password like `1` cannot
/// rewrite the host or the user.
String maskPass(String s) => s
    .replaceAll(RegExp(r'password=[^&\s]*'), 'password=•••')
    .replaceAllMapped(
      RegExp(r"//([^:/@\s']*):[^@\s']*@"),
      (m) => '//${m[1]}:•••@',
    );

/// ONVIF stream [uri] (XML-escaped, no or empty credentials) with this
/// camera's login put in, so it plays as is.
String streamUrl(Camera cam, String uri) {
  final enc = Uri.encodeComponent;
  var u = uri.replaceAll('&amp;', '&');
  if (u.contains('password=')) {
    // Xiongmai: credentials live in the path.
    u = u
        .replaceFirst(RegExp(r'user=[^&]*'), 'user=${enc(cam.user)}')
        .replaceFirst(RegExp(r'password=[^&]*'), 'password=${enc(cam.pass)}');
  } else {
    u = Uri.parse(u)
        .replace(userInfo: '${enc(cam.user)}:${enc(cam.pass)}')
        .toString();
  }
  return u;
}
