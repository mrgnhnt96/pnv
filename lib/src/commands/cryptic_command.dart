import 'dart:convert';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:crypto/crypto.dart';
import 'package:file/file.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:pnv/src/crypto/validate_secret_key.dart';
import 'package:pnv/src/mixins/platform_mixin.dart';
import 'package:pnv/src/mixins/pnv_config_mixin.dart';
import 'package:pnv/src/mixins/pubspec_mixin.dart';

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
      throw ArgumentError('No values to $name provided.');
    }

    return values;
  }

  String get secret {
    if (key case final key? when key.trim().isNotEmpty) {
      return key;
    }

    String? flavorKeyFile;
    if (flavor case final String flavor) {
      if (storageDir case final dir?) {
        final keyFile = dir.childFile('$flavor.key');

        if (keyFile.existsSync()) {
          flavorKeyFile = keyFile.path;
        } else {
          logger.err('No key file found for flavor $flavor.');
          throw ArgumentError('No key file found for flavor $flavor.');
        }
      }
    }

    if (keyFile ?? flavorKeyFile case final keyFile?) {
      final file = fs.file(keyFile);

      if (!file.existsSync()) {
        logger.err('❌ Key file "$keyFile" does not exist or was not readable.');
        throw ArgumentError('Key file does not exist or was not readable.');
      }

      return file.readAsStringSync().trim();
    }

    throw ArgumentError('No key or key file provided.');
  }

  List<int> get secretBytes {
    final bytes = base64.decode(secret);

    if (!validateSecretKey(bytes)) {
      throw ArgumentError('Key is not expected length.');
    }

    return bytes;
  }

  List<int> get keyHash => sha256.convert(secretBytes).bytes;
}
