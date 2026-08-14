import 'package:pnv/src/commands/cryptic_command.dart';
import 'package:pnv/src/handlers/encrypt_handler.dart';

class EncryptCommand extends CrypticCommand with EncryptHandler {
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
    final keyBytes = secretBytes;
    final keyHash = this.keyHash;

    for (final value in valuesToCrypt) {
      logger.write(
        '${encryptValue(value, keyBytes: keyBytes, keyHash: keyHash)}\n',
      );
    }

    return 0;
  }
}
