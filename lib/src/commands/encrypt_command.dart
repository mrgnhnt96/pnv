import 'dart:convert';
import 'dart:typed_data';

import 'package:pnv/src/commands/cryptic_command.dart';
import 'package:pnv/src/crypto/random_bytes.dart';
import 'package:pnv/utils/constants.dart';
import 'package:pointycastle/export.dart';

class EncryptCommand extends CrypticCommand {
  EncryptCommand({
    required super.fs,
    required super.logger,
  });

  @override
  String get name => 'encrypt';

  @override
  String get description => 'Encrypt a secret.';

  @override
  List<String> get aliases => ['enc', 'e', 'encode'];

  @override
  Future<int> run() async {
    final keyHash = this.keyHash;
    for (final value in valuesToCrypt) {
      encrypt(value, keyHash);
    }

    return 0;
  }

  void encrypt(String value, List<int> keyHash) {
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

    final encrypted = cipher.process(utf8.encode(value));

    final encoded = base64.encode([...cipher.mac, ...iv, ...encrypted]);

    logger.write('SECRET;$encoded');
  }
}
