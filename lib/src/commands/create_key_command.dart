import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:pnv/src/crypto/random_bytes.dart';

class CreateKeyCommand extends Command<int> {
  CreateKeyCommand();

  @override
  String get name => 'create-key';

  @override
  String get description => 'Create a new encryption key.';

  @override
  Future<int> run() async {
    final bytes = randomBytes(12);

    final string = base64UrlEncode(bytes);

    print(string);

    return 0;
  }
}
