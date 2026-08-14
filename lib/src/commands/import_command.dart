import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:pnv/src/commands/cryptic_command.dart';
import 'package:pnv/src/crypto/plaintext_detector.dart';
import 'package:pnv/src/handlers/encrypt_handler.dart';
import 'package:pnv/src/mixins/file_mixin.dart';
import 'package:pnv/src/pnv_exception.dart';
import 'package:yaml_edit/yaml_edit.dart';

class ImportCommand extends CrypticCommand with EncryptHandler {
  ImportCommand({
    required super.fs,
    required super.logger,
  }) {
    argParser
      ..addOption(
        'output',
        abbr: 'o',
        help: 'The .yaml file to write.',
        valueHelp: 'envs/app.local.yaml',
        mandatory: true,
      )
      ..addFlag(
        'only-secrets',
        negatable: false,
        help: 'Encrypt only the values that look like secrets, leaving plain '
            'config readable. The default encrypts everything, because '
            'over-encrypting is safe and under-encrypting leaks.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Overwrite the output file if it already exists.',
      );
  }

  @override
  String get name => 'import';

  @override
  String get description => 'Build an encrypted .yaml from an existing .env.';

  @override
  String get invocation => 'pnv import <file.env> --output <file.yaml>';

  String get output => argResults['output'] as String;

  bool get onlySecrets => argResults['only-secrets'] == true;

  bool get force => argResults['force'] == true;

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
        'Name the .env file to import. Try: pnv import .env '
        '--output envs/app.local.yaml',
      );
    }

    final source = fs.file(rest.first);

    if (!source.existsSync()) {
      throw PnvException('Input file "${rest.first}" does not exist.');
    }

    final target = fs.file(output);

    if (target.existsSync() && !force) {
      throw PnvException(
        '"$output" already exists. Pass --force to overwrite it, or point '
        '--output somewhere else.',
      );
    }

    final key = _key();
    final editor = YamlEditor('');
    final entries = <String, String>{};

    var encrypted = 0;
    var plain = 0;

    for (final line in source.readAsLinesSync()) {
      if (line.trimLeft().startsWith('#')) continue;

      final index = line.indexOf('=');
      if (index == -1) continue;

      final name = line.substring(0, index).replaceAll('"', '').trim();
      if (name.isEmpty) continue;

      final (value: raw, comment: _) = splitEnvValue(line.substring(index + 1));
      final value = unquoteEnvValue(raw);

      // Keys stay flat and lowercased so they round-trip back through
      // `generate env` byte for byte. Un-flattening APP_RUN_TIME_KEY is
      // guesswork: the original could have been run-time or run_time, and
      // getting it wrong renames the variable the build depends on.
      final yamlKey = name.toLowerCase();

      final shouldEncrypt = value.isNotEmpty &&
          (!onlySecrets ||
              suspectPlaintext(keyPath: yamlKey, value: value) != null);

      if (shouldEncrypt) {
        entries[yamlKey] = encryptValue(
          value,
          keyBytes: key.bytes,
          keyHash: key.hash,
        );
        encrypted++;
      } else {
        entries[yamlKey] = value;
        plain++;
      }
    }

    if (entries.isEmpty) {
      throw PnvException('No environment variables found in "${rest.first}".');
    }

    editor.update([], entries);

    final content = editor.toString();

    target
      ..createSync(recursive: true)
      ..writeAsStringSync(content.endsWith('\n') ? content : '$content\n');

    logger
      ..info(
        '${green.wrap('✓')} Wrote ${yellow.wrap(p.relative(target.path))} '
        '${darkGray.wrap('($encrypted encrypted, $plain plain)')}',
      )
      ..info(
        'Keys are flat so they regenerate identically. Group them by hand if '
        'you want nesting -- `generate env` joins nested keys with "_".',
      );

    return 0;
  }

  ({List<int> bytes, List<int> hash}) _key() {
    // Prefer what was asked for, then the flavor the OUTPUT name implies —
    // the input is a .env, whose name says nothing about which key to use.
    final named =
        key != null || keyFile != null || (flavor?.trim().isNotEmpty ?? false);

    if (named) {
      return (bytes: secretBytes, hash: keyHash);
    }

    final inferred = flavorFromPath(output);

    try {
      final secret = secretFor(flavor: inferred);
      return (bytes: decodeSecret(secret), hash: keyHashFor(secret));
    } on PnvException catch (e) {
      throw PnvException(
        'No key for "$output": its name implies flavor "$inferred", which has '
        'no key. ${e.message}',
      );
    }
  }
}
