import 'dart:convert';

import 'package:pnv/src/crypto/random_bytes.dart';

mixin CryptoMixin {
  String get newKey {
    final bytes = randomBytes(12);

    return base64UrlEncode(bytes);
  }
}
