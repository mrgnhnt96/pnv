import 'dart:convert';

import 'package:pnv/src/crypto/random_bytes.dart';
import 'package:pnv/utils/constants.dart';

mixin CryptoMixin {
  String get newKey {
    final bytes = randomBytes(newKeyLength);

    return base64UrlEncode(bytes);
  }
}
