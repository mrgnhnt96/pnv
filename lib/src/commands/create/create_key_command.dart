import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:pnv/src/crypto/random_bytes.dart';

class CreateKeyCommand extends Command<int> {
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
    final bytes = randomBytes(12);

    final string = base64UrlEncode(bytes);

    logger.write(string);

    return 0;
  }
}
