import 'dart:async';

import 'package:pnv/src/commands/cryptic_command.dart';
import 'package:pnv/src/handlers/decrypt_handler.dart';

class DecryptCommand extends CrypticCommand with DecryptHandler {
  DecryptCommand({
    required super.fs,
    required super.logger,
  });

  @override
  String get name => 'decrypt';

  @override
  String get description => 'Decrypt a secret.';

  @override
  List<String> get aliases => ['dec', 'd', 'decode'];

  @override
  Future<int> run() async {
    final keyHash = this.keyHash;

    for (final value in valuesToCrypt) {
      final result = decrypt(value, keyHash);

      logger.write(result);
    }

    return 0;
  }
}
