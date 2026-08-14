import 'dart:convert';
import 'dart:typed_data';

import 'package:pnv/src/crypto/random_bytes.dart';
import 'package:pnv/src/crypto/secret_token.dart';
import 'package:pnv/utils/constants.dart';
import 'package:pointycastle/export.dart';

mixin EncryptHandler {
  /// Encrypts [value] into a v1 `SECRET1;` token.
  ///
  /// [keyBytes] is the decoded key; [keyHash] is its SHA-256, which is the
  /// actual AES key. Both are needed: the hash encrypts, the raw bytes produce
  /// the key id stamped into the token.
  String encryptValue(
    String value, {
    required List<int> keyBytes,
    required List<int> keyHash,
  }) {
    final iv = randomBytes(algIvLength);

    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(
          KeyParameter(Uint8List.fromList(keyHash)),
          algAuthTagLength * 8,
          iv,
          Uint8List(0),
        ),
      );

    // process() already appends the auth tag, so the body is complete. The old
    // format also prepended cipher.mac, writing the same 16 bytes twice.
    final body = cipher.process(utf8.encode(value));

    return SecretToken.encode(keyBytes: keyBytes, iv: iv, body: body);
  }
}
