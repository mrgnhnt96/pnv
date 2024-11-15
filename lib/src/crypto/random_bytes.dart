import 'dart:math';
import 'dart:typed_data';

Uint8List randomBytes(int length) {
  final rnd = Random.secure();
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = rnd.nextInt(256);
  }
  return bytes;
}
