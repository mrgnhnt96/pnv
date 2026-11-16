import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pnv/src/crypto/secret_token.dart';
import 'package:pnv/src/pnv_exception.dart';
import 'package:pnv/utils/constants.dart';
import 'package:test/test.dart';

void main() {
  /// A real v0 token and the key behind it, kept as a fixture: the promise
  /// that old secrets keep working is only worth what a real old secret proves.
  const legacyKey = 'oI0tNittVqP_nLwY';
  const legacyToken =
      'SECRET;lyho8D18bGu/BzQgpoCb3KhTEJk/1jPC+Jpa+Kk5E1dD2R3/77TZJeREe5c'
      'oaPA9fGxrvwc0IKaAm9w=';

  List<int> bytesOf(String key) => base64.decode(key);

  group('keyFingerprint', () {
    test('is stable for the same key', () {
      expect(
        keyFingerprint(bytesOf(legacyKey)),
        keyFingerprint(bytesOf(legacyKey)),
      );
    });

    test('differs between keys', () {
      expect(
        keyFingerprint(bytesOf(legacyKey)),
        isNot(keyFingerprint(bytesOf('ZZZZZZZZZZZZZZZZ'))),
      );
    });

    test('is not a prefix of the AES key', () {
      // The AES key is sha256(keyBytes). If the fingerprint were derived the
      // same way, every committed secret would publish four bytes of it.
      final aesKey = sha256.convert(bytesOf(legacyKey)).bytes;
      final id = keyFingerprint(bytesOf(legacyKey));

      expect(id.length, keyIdLength);
      expect(id, isNot(aesKey.sublist(0, keyIdLength)));
    });
  });

  group('isSecret', () {
    test('accepts both versions', () {
      expect(isSecret('SECRET;abc'), isTrue);
      expect(isSecret('SECRET;v1:abc'), isTrue);
    });

    test('rejects anything else', () {
      expect(isSecret('hello'), isFalse);
      expect(isSecret('SECRETS;abc'), isFalse);
      expect(isSecret(''), isFalse);
    });
  });

  group('SecretToken.parse', () {
    test('reads a legacy token as version 0 with no key id', () {
      final token = SecretToken.parse(legacyToken);

      expect(token.version, 0);
      expect(token.keyId, isNull);
      expect(token.iv, hasLength(algIvLength));
    });

    test('a legacy token cannot answer which key made it', () {
      expect(
        SecretToken.parse(legacyToken).matchesKey(bytesOf(legacyKey)),
        isNull,
      );
    });

    test('reads a v1 token and identifies its key', () {
      final encoded = SecretToken.encode(
        keyBytes: bytesOf(legacyKey),
        iv: Uint8List(algIvLength),
        body: Uint8List(algAuthTagLength),
      );

      final token = SecretToken.parse(encoded);

      expect(token.version, 1);
      expect(token.keyId, hasLength(keyIdLength));
      expect(token.matchesKey(bytesOf(legacyKey)), isTrue);
      expect(token.matchesKey(bytesOf('ZZZZZZZZZZZZZZZZ')), isFalse);
    });

    test('rejects a value that is not a secret', () {
      expect(
        () => SecretToken.parse('plain value'),
        throwsA(isA<PnvException>()),
      );
    });

    test('rejects a payload that is not base64', () {
      expect(
        () => SecretToken.parse('SECRET;v1:not base64!!'),
        throwsA(
          isA<PnvException>().having(
            (e) => e.message,
            'message',
            contains('not valid base64'),
          ),
        ),
      );
    });

    test('rejects a payload too short to hold a header and a tag', () {
      expect(
        () =>
            SecretToken.parse('SECRET;v1:${base64.encode(List.filled(8, 0))}'),
        throwsA(
          isA<PnvException>().having(
            (e) => e.message,
            'message',
            contains('too short'),
          ),
        ),
      );
    });

    test('names the context in its errors', () {
      expect(
        () => SecretToken.parse('SECRET;v1:!!', context: 'app.yaml → db.pass'),
        throwsA(
          isA<PnvException>().having(
            (e) => e.message,
            'message',
            contains('app.yaml → db.pass'),
          ),
        ),
      );
    });
  });
}
