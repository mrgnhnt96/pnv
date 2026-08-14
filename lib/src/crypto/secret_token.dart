import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pnv/src/pnv_exception.dart';
import 'package:pnv/utils/constants.dart';

/// Every pnv secret starts with this, in every version.
///
/// It is load-bearing well outside this package: consumers glob `SECRET;*` to
/// decide whether a value needs decrypting, and grep `^\s*key:\s*SECRET;` to
/// find blobs in a YAML file. A version marker in front of it would break all
/// of that, so the version goes *after*.
const secretPrefix = 'SECRET;';

/// Marks a v1 payload, sitting between [secretPrefix] and the base64 body.
///
/// Unambiguous because the base64 alphabet has no `:`, so a v0 payload can
/// never begin with this. That is what makes a version possible at all — a
/// version *byte* inside the payload would be indistinguishable from the auth
/// tag that used to occupy that position.
const versionMarker = 'v1:';

/// Whether [value] is a pnv secret of any version.
bool isSecret(String value) => value.startsWith(secretPrefix);

/// Identifies the key a secret was encrypted with, without revealing it.
///
/// Deliberately NOT derived from `sha256(key)` — that value *is* the AES key,
/// so publishing a prefix of it in every committed secret would hand out key
/// material. The domain separator makes this a one-way label instead.
Uint8List keyFingerprint(List<int> keyBytes) {
  final digest = sha256.convert([
    ...utf8.encode(keyIdDomain),
    ...keyBytes,
  ]);

  return Uint8List.fromList(digest.bytes.sublist(0, keyIdLength));
}

/// A parsed `SECRET;` token, of either version.
class SecretToken {
  const SecretToken({
    required this.version,
    required this.keyId,
    required this.iv,
    required this.body,
  });

  /// Parses [value], or throws [PnvException] describing what is wrong with it.
  ///
  /// [context] names where the value came from — a file and key path — so a
  /// failure in a forty-key file says which value failed.
  factory SecretToken.parse(String value, {String? context}) {
    final where = context == null ? '' : ' ($context)';

    final int version;
    final String encoded;

    if (!value.startsWith(secretPrefix)) {
      throw PnvException(
        'Not a pnv secret$where: expected it to start with "$secretPrefix".',
      );
    }

    final body = value.substring(secretPrefix.length);

    if (body.startsWith(versionMarker)) {
      version = 1;
      encoded = body.substring(versionMarker.length);
    } else {
      version = 0;
      encoded = body;
    }

    final Uint8List payload;
    try {
      payload = base64.decode(encoded);
    } on FormatException {
      throw PnvException(
        'Malformed secret$where: the value after the prefix is not valid '
        'base64. This is a corrupt value, not a key problem.',
      );
    }

    // v0: tag || iv || ciphertext || tag   (the tag was written twice)
    // v1: keyId || iv || ciphertext || tag
    final headerLength = version == 0
        ? algAuthTagLength + algIvLength
        : keyIdLength + algIvLength;

    if (payload.length < headerLength + algAuthTagLength) {
      throw PnvException(
        'Malformed secret$where: ${payload.length} bytes is too short to '
        'contain a header and an auth tag. This is a corrupt value, not a '
        'key problem.',
      );
    }

    return SecretToken(
      version: version,
      keyId:
          version == 0 ? null : Uint8List.sublistView(payload, 0, keyIdLength),
      iv: version == 0
          ? Uint8List.sublistView(payload, algAuthTagLength, headerLength)
          : Uint8List.sublistView(payload, keyIdLength, headerLength),
      body: Uint8List.sublistView(payload, headerLength),
    );
  }

  /// 0 for a bare `SECRET;` payload, 1 for `SECRET;v1:`.
  final int version;

  /// The first [keyIdLength] bytes of the key's fingerprint, or null on v0,
  /// which carried nothing identifying its key.
  final Uint8List? keyId;

  final Uint8List iv;

  /// Ciphertext with the auth tag appended, which is what the cipher consumes.
  final Uint8List body;

  /// Whether this token was made with the key behind [keyBytes].
  ///
  /// Null when it cannot be known — a v0 token carries no key id, so the only
  /// way to find out is to try decrypting it.
  bool? matchesKey(List<int> keyBytes) {
    if (keyId case final Uint8List id) {
      final expected = keyFingerprint(keyBytes);

      for (var i = 0; i < keyIdLength; i++) {
        if (id[i] != expected[i]) return false;
      }

      return true;
    }

    return null;
  }

  /// Renders a v1 token.
  static String encode({
    required List<int> keyBytes,
    required Uint8List iv,
    required Uint8List body,
  }) {
    return '$secretPrefix$versionMarker${base64.encode([
          ...keyFingerprint(keyBytes),
          ...iv,
          ...body,
        ])}';
  }
}
