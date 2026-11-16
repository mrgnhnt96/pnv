import 'dart:convert';
import 'dart:typed_data';

import 'package:pnv/src/crypto/secret_token.dart';
import 'package:pnv/src/pnv_exception.dart';
import 'package:pnv/utils/constants.dart';
import 'package:pointycastle/export.dart';

mixin DecryptHandler {
  String get secret;

  List<int> get keyHash;

  /// Decrypts [value], describing [context] — a file path, an env key — in any
  /// error, so a failure in a forty-key file says which value failed.
  ///
  /// [keyHash] is the caller's key, not [this.keyHash]: a batch decrypts each
  /// file with a key derived from that file's own name.
  ///
  /// [keyBytes] is the key *before* hashing, and is only needed to check a v1
  /// token's key id. Omitting it skips that check; the auth tag still rejects
  /// a wrong key, just with a less specific message.
  String decrypt(
    String value,
    List<int> keyHash, {
    String? context,
    List<int>? keyBytes,
  }) {
    final where = context == null ? '' : ' ($context)';

    final token = SecretToken.parse(value, context: context);

    if (keyBytes != null && token.matchesKey(keyBytes) == false) {
      throw PnvException(
        'Wrong key$where: this secret was encrypted with a different key. '
        'Check the flavor — a secret from another environment may have been '
        'pasted into this file.',
      );
    }

    try {
      return _decrypt(token, keyHash);
    } catch (e) {
      throw PnvException(
        'Failed to decrypt$where. The value is well formed, so this is most '
        'likely the wrong key.',
      );
    }
  }

  String _decrypt(SecretToken token, List<int> keyHash) {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(Uint8List.fromList(keyHash)),
          algAuthTagLength * 8,
          token.iv,
          Uint8List(0),
        ),
      );

    return utf8.decode(cipher.process(token.body));
  }
}
