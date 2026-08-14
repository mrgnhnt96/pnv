import 'dart:convert';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:crypto/crypto.dart';
import 'package:file/file.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:pnv/src/crypto/validate_secret_key.dart';
import 'package:pnv/src/mixins/platform_mixin.dart';
import 'package:pnv/src/mixins/pnv_config_mixin.dart';
import 'package:pnv/src/mixins/pubspec_mixin.dart';
import 'package:pnv/src/pnv_exception.dart';
import 'package:pnv/utils/constants.dart';

abstract class CrypticCommand extends Command<int>
    with PlatformMixin, PubspecMixin, PnvConfigMixin {
  CrypticCommand({
    required this.fs,
    required this.logger,
  }) {
    argParser
      ..addOption(
        'key',
        abbr: 'k',
        help: 'The secret key to use to $name.',
      )
      ..addOption(
        'key-file',
        abbr: 'f',
        help: 'The file containing the secret key to use to $name.',
      )
      ..addOption(
        'flavor',
        help: 'The flavor to use to $name.',
      );
  }

  @override
  final FileSystem fs;

  @override
  final Logger logger;

  @override
  ArgResults get argResults => super.argResults!;

  String? get flavor => argResults['flavor'] as String?;
  String? get key => argResults['key'] as String?;
  String? get keyFile => argResults['key-file'] as String?;
  List<String> get valuesToCrypt {
    final values = argResults.rest;

    if (values.isEmpty) {
      throw PnvException('No values to $name provided.');
    }

    return values;
  }

  String get secret => secretFor(
        key: key,
        keyFile: keyFile,
        flavor: flavor,
      );

  List<int> get secretBytes => decodeSecret(secret);

  List<int> get keyHash => keyHashFor(secret);

  List<int> keyHashFor(String secret) {
    return sha256.convert(decodeSecret(secret)).bytes;
  }

  Uint8List decodeSecret(String secret) {
    final Uint8List bytes;
    try {
      bytes = base64.decode(secret);
    } on FormatException {
      throw const PnvException(
        'Key is not valid base64. A key looks like the output of '
        '`pnv create key`.',
      );
    }

    if (!validateSecretKey(bytes)) {
      throw PnvException(
        'Key is too short: ${bytes.length} bytes, minimum is $minKeyLength. '
        'Generate one with `pnv create key`.',
      );
    }

    return bytes;
  }

  String secretFor({
    String? key,
    String? keyFile,
    String? flavor,
  }) {
    if (key case final String key when key.trim().isNotEmpty) {
      return key;
    }

    String? flavorKeyFile;
    if (flavor?.trim() case final String flavor when flavor.isNotEmpty) {
      final config = pnvConfig();
      if (config == null) {
        throw const PnvException(
          'Failed to find storage directory. Try running '
          '`pnv init` and try again.',
        );
      }

      final keyFile = storageKeyFile(flavor, config);

      if (keyFile.existsSync()) {
        flavorKeyFile = keyFile.path;
      } else {
        final config = pnvConfig();

        if (config == null) {
          throw const PnvException(
            'Failed to find pnv config. Try running '
            '`pnv init` and try again.',
          );
        }

        for (final MapEntry(:key, value: extensions)
            in config.flavors.entries) {
          if (extensions.contains(flavor)) {
            final keyFile = storageKeyFile(key, config);

            if (keyFile.existsSync()) {
              flavorKeyFile = keyFile.path;
              break;
            }
          }
        }
      }
    }

    if (keyFile ?? flavorKeyFile case final String keyFile) {
      final file = fs.file(keyFile);

      if (!file.existsSync()) {
        throw PnvException(
          '❌ Key file "$keyFile" does not exist or was not readable.',
        );
      }

      return file.readAsStringSync().trim();
    }

    throw const PnvException('Missing key, key file, or flavor.');
  }
}
