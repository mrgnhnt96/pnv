import 'package:path/path.dart' as p;
import 'package:pnv/src/commands/secret_file_command.dart';
import 'package:pnv/src/crypto/secret_token.dart';
import 'package:pnv/src/handlers/decrypt_handler.dart';
import 'package:pnv/src/pnv_exception.dart';
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

class ShowCommand extends SecretFileCommand with DecryptHandler {
  ShowCommand({
    required super.fs,
    required super.logger,
  }) : super(requiresFile: false);

  @override
  String get name => 'show';

  @override
  String get description => 'Print a .yaml file with its secrets decrypted.';

  @override
  String get invocation => 'pnv show <file.yaml>';

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
    // Takes the path positionally as well as via --file: git's textconv
    // driver appends the file as a bare argument and cannot be told otherwise.
    final path =
        input ?? (argResults.rest.isEmpty ? null : argResults.rest.first);

    if (path == null) {
      throw const PnvException('Name the .yaml file to show.');
    }

    final file = fs.file(path);

    if (!file.existsSync()) {
      throw PnvException('Input file "$path" does not exist.');
    }

    final source = file.readAsStringSync();
    final yaml = loadYaml(source);

    if (yaml is! YamlMap) {
      // Not a secrets file. A textconv driver must still emit *something*
      // readable, or the diff shows nothing at all.
      logger.write(source);
      return 0;
    }

    final leaves = SecretFileCommand.leaves(yaml);
    final hasSecrets = leaves.any(
      (e) => e.$2.value is String && isSecret(e.$2.value as String),
    );

    if (!hasSecrets) {
      logger.write(source);
      return 0;
    }

    final key = keyForFile(file.path);
    final editor = YamlEditor(source);

    for (final (keyPath, node) in leaves) {
      final value = node.value;

      if (value is! String || !isSecret(value)) continue;

      editor.update(
        keyPath,
        decrypt(
          value,
          key.hash,
          context: '${p.relative(file.path)} → ${keyPath.join('.')}',
          keyBytes: key.bytes,
        ),
      );
    }

    logger.write(editor.toString());

    return 0;
  }
}
