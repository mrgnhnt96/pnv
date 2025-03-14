import 'dart:async';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:file/file.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:pnv/src/mixins/file_mixin.dart';
import 'package:pnv/src/mixins/platform_mixin.dart';
import 'package:pnv/src/mixins/pnv_config_mixin.dart';
import 'package:pnv/src/mixins/pubspec_mixin.dart';

class GenerateDartCommand extends Command<int>
    with FileMixin, PubspecMixin, PlatformMixin, PnvConfigMixin {
  GenerateDartCommand({
    required this.logger,
    required this.fs,
  }) {
    argParser
      ..addOption(
        'output',
        abbr: 'o',
        help: 'The directory to output the .env file to.',
        valueHelp: 'lib/envs',
        mandatory: true,
      )
      ..addOption(
        'directory',
        abbr: 'd',
        aliases: ['dir'],
        help: 'The input directory containing the .env files to '
            'generate the .dart file from.',
        valueHelp: 'decrypted_envs',
      )
      ..addOption(
        'flavor',
        help: 'The flavor to use to $name.',
      )
      ..addOption(
        'file',
        abbr: 'i',
        aliases: ['input'],
        help: 'The input .env file to generate the .dart file from.',
        valueHelp: 'infra.local.env',
      );
  }

  @override
  String decrypt(String value, List<int> keyHash) {
    throw UnimplementedError();
  }

  @override
  ArgResults get argResults => super.argResults!;

  @override
  String get name => 'dart';

  @override
  String get description => 'Generate a .dart file from a .env file.';

  @override
  final Logger logger;
  @override
  final FileSystem fs;

  @override
  String? get input {
    final input = argResults['file'] as String?;

    if (input == null) {
      return null;
    }

    if (!fs.file(input).existsSync()) {
      logger.err('Input file "$input" does not exist.');
      return null;
    }

    final ext = p.extension(input);
    if (ext != '.env') {
      logger.err('Input file "$input" must be a .env file.');
      return null;
    }

    return input;
  }

  String? get directory {
    final directory = argResults['directory'] as String?;

    if (directory == null) {
      return null;
    }

    if (!fs.directory(directory).existsSync()) {
      logger.err('Input directory "$directory" does not exist.');
      return null;
    }

    return directory;
  }

  String? get output {
    final output = argResults['output'] as String;

    if (output.isEmpty) {
      logger.err('Output directory is required.');
      return null;
    }

    return output;
  }

  String? get flavor => argResults['flavor'] as String?;

  @override
  Future<int>? run() async {
    try {
      return await _run();
    } catch (e) {
      logger.err('Failed to generate .env file. $e');
      return 1;
    }
  }

  Future<int> _run() async {
    final input = this.input;
    final dir = directory;
    final output = this.output;

    if (output == null) {
      return 1;
    }

    if (fs.directory(output) case final dir when dir.existsSync()) {
      final entities = dir.listSync();
      final isAllFiles = entities.every((e) => e is File);
      if (!isAllFiles) {
        logger.err(
          '❌ Output directory "$output" contains non-files, aborting. '
          'Please double check that the output directory is accurate. '
          'The directory WILL BE DELETED before generating the .dart file.',
        );

        return 1;
      }

      await dir.delete(recursive: true);
    }

    if (input case final String input) {
      try {
        final result = await generateDartFromEnv(
          input,
          output: output,
        );

        return result ? 0 : 1;
      } catch (e) {
        logger.err('Failed to generate .dart file.\n$e');
        return 1;
      }
    }

    if (flavor case final String flavor) {
      if (dir == null) {
        logger.err('Directory is required when using flavor.');
        return 1;
      }

      final config = pnvConfig();

      if (config == null) {
        logger.err('No .pnvrc file found.');
        return 1;
      }

      final flavors = config.flavorsFor(flavor);

      if (flavors == null) {
        logger.err('Flavor "$flavor" not found.');
        return 1;
      }

      final result = await actForFlavor(
        directory: dir,
        flavor: flavor,
        config: config,
        action: (file) => generateDartFromEnv(file, output: output),
      );

      if (!result) {
        return 1;
      }

      return 0;
    }

    if (dir case final String dir) {
      for (final file in fs.directory(dir).listSync().whereType<File>()) {
        try {
          final result = await generateDartFromEnv(file.path, output: output);
          return result ? 0 : 1;
        } catch (e) {
          logger.err('Failed to generate .dart file.\n$e');
          return 1;
        }
      }

      return 0;
    }

    return 0;
  }
}
