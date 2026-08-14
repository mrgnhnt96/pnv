import 'package:pnv/src/commands/secret_file_command.dart';
import 'package:pnv/src/crypto/secret_token.dart';
import 'package:pnv/src/handlers/decrypt_handler.dart';
import 'package:pnv/src/pnv_exception.dart';
import 'package:yaml/yaml.dart';

class GetCommand extends SecretFileCommand with DecryptHandler {
  GetCommand({
    required super.fs,
    required super.logger,
  });

  @override
  String get name => 'get';

  @override
  String get description => 'Read one value out of a .yaml file, decrypted.';

  @override
  String get invocation => 'pnv get <key.path> --file <file.yaml>';

  @override
  Future<int> run() async {
    try {
      return _run();
    } on PnvException catch (e) {
      logger.err('❌ ${e.message}');
      return 1;
    }
  }

  int _run() {
    final rest = argResults.rest;

    if (rest.isEmpty) {
      throw const PnvException(
        'Missing the key path. Try: pnv get app.api-key '
        '--file envs/app.local.yaml',
      );
    }

    final segments = pathSegments(rest.first);
    final file = targetFile;

    final yaml = loadYaml(file.readAsStringSync());

    if (yaml is! YamlMap) {
      throw PnvException('"${file.path}" is not a valid .yaml file.');
    }

    dynamic node = yaml;
    for (final segment in segments) {
      if (node is! YamlMap || !node.containsKey(segment)) {
        throw PnvException(
          'No such key "${segments.join('.')}" in "${file.path}".',
        );
      }
      node = node[segment];
    }

    if (node is YamlMap) {
      throw PnvException(
        '"${segments.join('.')}" is a group, not a value. '
        'Name one of its keys.',
      );
    }

    final value = '$node';

    if (!isSecret(value)) {
      // Not an error: plain config lives in these files too, and reading it
      // back should work the same way.
      logger.write('$value\n');
      return 0;
    }

    final key = keyForFile(file.path);

    final plain = decrypt(
      value,
      key.hash,
      context: segments.join('.'),
      keyBytes: key.bytes,
    );

    logger.write('$plain\n');

    return 0;
  }
}
