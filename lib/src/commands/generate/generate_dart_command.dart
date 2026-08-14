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
      )
      ..addOption(
        'class-name',
        abbr: 'c',
        help: 'The name of the class to generate. Defaults to '
            'name of the input file (backend.local.env -> Backend).'
            '\n\nApplies only to the --file flag.',
        valueHelp: 'Env',
      );
  }

  @override
  String decrypt(
    String value,
    List<int> keyHash, {
    String? context,
    List<int>? keyBytes,
  }) {
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

  String? get className {
    return switch (argResults['class-name']) {
      final String name => name,
      _ => null,
    };
  }

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

    if (!clearOutputDirectory(output)) {
      return 1;
    }

    if (input case final String input) {
      try {
        final result = await generateDartFromEnv(
          input,
          output: output,
          className: className,
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
        action: (file) => generateDartFromEnv(
          file,
          output: output,
          className: null,
        ),
      );

      if (!result) {
        return 1;
      }

      return 0;
    }

    if (dir case final String dir) {
      // Every file, not just the first — this loop used to return on its
      // first iteration, so a directory of five .env files produced one
      // .dart file and exit 0.
      var ok = true;

      for (final file in fs.directory(dir).listSync().whereType<File>()) {
        try {
          final result = await generateDartFromEnv(
            file.path,
            output: output,
            className: null,
          );

          ok = ok && result;
        } catch (e) {
          logger.err('Failed to generate .dart file.\n$e');
          return 1;
        }
      }

      return ok ? 0 : 1;
    }

    return 0;
  }

  /// Empties the output directory, refusing if it holds anything pnv did not
  /// generate.
  ///
  /// The directory is deleted wholesale, so "is this ours?" has to be a real
  /// test. It used to be "does it contain a subdirectory", which let the
  /// command destroy hand-written source files without a word.
  bool clearOutputDirectory(String output) {
    final dir = fs.directory(output);

    if (!dir.existsSync()) {
      return true;
    }

    final foreign = <String>[];

    for (final entity in dir.listSync()) {
      if (entity is! File) {
        foreign.add('${p.relative(entity.path)}${p.separator} (directory)');
        continue;
      }

      String? content;
      try {
        content = entity.readAsStringSync();
      } catch (_) {
        content = null;
      }

      if (content == null || !content.startsWith(generatedFileHeader)) {
        foreign.add(p.relative(entity.path));
      }
    }

    if (foreign.isNotEmpty) {
      logger
        ..err(
          '❌ Refusing to use "$output" as an output directory: it contains '
          'files pnv did not generate, and the directory is emptied before '
          'generating.',
        )
        ..err('   Not generated by pnv:');
      for (final path in foreign) {
        logger.err('   • $path');
      }
      logger.err('   Point --output at a directory pnv owns.');

      return false;
    }

    dir.deleteSync(recursive: true);

    return true;
  }
}
