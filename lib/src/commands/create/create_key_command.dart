import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:pnv/src/mixins/crypto_mixin.dart';

class CreateKeyCommand extends Command<int> with CryptoMixin {
  CreateKeyCommand({
    required this.logger,
  });

  final Logger logger;

  @override
  String get name => 'key';

  @override
  String get description => 'Create a new encryption key.';

  @override
  Future<int> run() async {
    logger.write(newKey);

    return 0;
  }
}
