import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:crypto/crypto.dart';
import 'package:file/file.dart';
import 'package:pnv/src/crypto/validate_secret_key.dart';

abstract class CrypticCommand extends Command<int> {
  CrypticCommand({
    required this.fs,
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
      );
  }

  final FileSystem fs;

  @override
  ArgResults get argResults => super.argResults!;

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

    if (keyFile case final keyFile?) {
      final file = fs.file(keyFile);

      if (!file.existsSync()) {
        print('❌ Key file "$keyFile" does not exist or was not readable.');
        exit(1);
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
