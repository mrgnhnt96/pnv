import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pnv/utils/constants.dart';
import 'package:pointycastle/export.dart';

mixin DecryptHandler {
  String get secret;

  List<int> get keyHash;

  String decrypt(String value, List<int> keyHash) {
    try {
      return _decrypt(value, keyHash);
    } catch (e) {
      print('Failed to decrypt value. Do you have the correct key?');
      exit(1);
    }
  }

  String _decrypt(String value, List<int> keyHash) {
    final hexValue = base64.decode(value.replaceFirst('SECRET;', ''));

    final iv =
        hexValue.sublist(algAuthTagLength, algIvLength + algAuthTagLength);
    final raw = hexValue.sublist(algAuthTagLength + algIvLength);

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
