import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencam/pixels.dart';

void main() {
  test('opaque turns the bgr0 padding byte into full alpha', () {
    final px = opaque(Uint8List.fromList([10, 20, 30, 0, 40, 50, 60, 0]));
    expect(px, [10, 20, 30, 255, 40, 50, 60, 255]);
  });

  test('isBlank is true only when nothing is drawn', () {
    expect(isBlank(Uint8List(4000)), isTrue);
    expect(isBlank(Uint8List(4000)..[1994] = 7), isFalse);
  });
}
