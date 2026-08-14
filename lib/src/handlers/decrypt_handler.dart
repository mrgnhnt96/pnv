import 'dart:convert';
import 'dart:typed_data';

import 'package:pnv/utils/constants.dart';
import 'package:pointycastle/export.dart';

mixin DecryptHandler {
  String get secret;

  List<int> get keyHash;

  /// The smallest payload a real secret can produce: tag, iv, and the tag
  /// again (appended by the cipher), around an empty plaintext.
  static const _minPayloadLength = algAuthTagLength + algIvLength;

  /// Decrypts [value], describing [context] — a file path, an env key — in any
  /// error, so a failure in a forty-key file says which value failed.
  String decrypt(String value, List<int> keyHash, {String? context}) {
    final where = context == null ? '' : ' ($context)';

    final Uint8List payload;
    try {
      payload = base64.decode(value.replaceFirst('SECRET;', ''));
    } on FormatException {
      throw Exception(
        'Malformed secret$where: the value after "SECRET;" is not valid '
        'base64. This is a corrupt value, not a key problem.',
      );
    }

    if (payload.length < _minPayloadLength) {
      throw Exception(
        'Malformed secret$where: ${payload.length} bytes is too short to '
        'contain an auth tag and IV. This is a corrupt value, not a key '
        'problem.',
      );
    }

    try {
      return _decrypt(payload, keyHash);
    } catch (e) {
      throw Exception(
        'Failed to decrypt$where. The value is well formed, so this is most '
        'likely the wrong key.',
      );
    }
  }

  /// [keyHash] is the caller's key, not [this.keyHash] — a batch decrypts each
  /// file with a key derived from that file's own name.
  String _decrypt(Uint8List payload, List<int> keyHash) {
    final iv = payload.sublist(
      algAuthTagLength,
      algIvLength + algAuthTagLength,
    );
    final raw = payload.sublist(algAuthTagLength + algIvLength);

    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(Uint8List.fromList(keyHash)),
          algAuthTagLength * 8,
          iv,
          Uint8List(0),
        ),
      );

    final decoded = cipher.process(raw);

    return utf8.decode(decoded);
  }
}
