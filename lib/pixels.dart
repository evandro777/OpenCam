import 'dart:typed_data';

/// True when every sampled byte is zero (a grab with nothing drawn, or a fully
/// transparent picture saved by an older run).
/// shortcut: samples ~1 byte in 997, a picture with only a few lit pixels
/// could count as blank; fine for a camera frame.
bool isBlank(Uint8List b) {
  for (var i = 0; i < b.length; i += 997) {
    if (b[i] != 0) return false;
  }
  return true;
}

/// mpv's raw screenshot is `bgr0`: the 4th byte of each pixel is padding,
/// usually 0, and would read as fully transparent. Set it to opaque, in place.
Uint8List opaque(Uint8List bgr0) {
  for (var i = 3; i < bgr0.length; i += 4) {
    bgr0[i] = 255;
  }
  return bgr0;
}
