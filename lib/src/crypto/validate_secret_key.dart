import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pnv/utils/constants.dart';

bool validateSecretKey(Uint8List key) {
  final h = sha256.convert(key);
  return h.bytes.length == algKeyLength;
}
