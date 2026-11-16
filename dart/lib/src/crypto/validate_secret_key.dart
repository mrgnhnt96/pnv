import 'dart:typed_data';

import 'package:pnv/utils/constants.dart';

/// Whether [key] is long enough to be used as a secret.
///
/// This checks the DECODED key, not its hash. Hashing any input produces
/// [algKeyLength] bytes, so measuring the digest — as this once did — accepts
/// every input and rejects nothing.
bool validateSecretKey(Uint8List key) {
  return key.length >= minKeyLength;
}
