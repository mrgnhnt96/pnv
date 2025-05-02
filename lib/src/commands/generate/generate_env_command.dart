import 'package:file/file.dart';
import 'package:path/path.dart' as p;
import 'package:pnv/src/commands/cryptic_command.dart';
import 'package:pnv/src/handlers/decrypt_handler.dart';
import 'package:pnv/src/mixins/file_mixin.dart';

class GenerateEnvCommand extends CrypticCommand with DecryptHandler, FileMixin {
  GenerateEnvCommand({
    required super.fs,
    required super.logger,
  }) {
    argParser
      ..addOption(
        'file',
        abbr: 'i',
        aliases: ['input'],
        help: 'The input .yaml file to generate the .env file from.',
        valueHelp: 'infra.local.yaml',
      )
      ..addOption(
        'directory',
        abbr: 'd',
        aliases: ['dir'],
        help: 'The input directory containing the .yaml files to '
            'generate the .env file from.',
        valueHelp: 'public',
      )
      ..addOption(
        'output',
        abbr: 'o',
        help: 'The directory to output the .env file to.',
        valueHelp: 'output',
        defaultsTo: 'outputs',
      );
  }

  @override
  String get name => 'env';

  @override
  String get description => 'Generate a .env file from a .yaml file.';

  @override
  String? get input {
    final input = argResults['file'] as String?;

    if (input == null) {
      return null;
    }

    if (!fs.file(input).existsSync()) {
      throw ArgumentError(
        'Input file "$input" does not exist.',
      );
    }

    final ext = p.extension(input);
    if (!(ext == '.yaml' || ext == '.yml')) {
      throw ArgumentError('Input file "$input" must be a .yaml file.');
    }

    return input;
  }

  String? get directory {
    final directory = argResults['directory'] as String?;

    if (directory == null) {
      return null;
    }

    if (!fs.directory(directory).existsSync()) {
      throw ArgumentError(
        'Input directory "$directory" does not exist.',
      );
    }

    return directory;
  }

  String get output {
    final output = argResults['output'] as String;

    if (output.isEmpty) {
      return 'outputs';
    }

    return output;
  }

  @override
  Future<int> run() async {
    try {
      return _run();
    } catch (e) {
      logger.err('Failed to generate .env file. $e');
      return 1;
    }
  }

  Future<int> _run() async {
    final input = this.input;
    final dir = directory;
    final output = this.output;

    if (input case final String input) {
      List<int>? keyHash;

      try {
        keyHash = this.keyHash;
      } catch (_) {}

      if (keyHash == null) {
        final flavor = flavorFrom(input);
        final secret = secretFor(flavor: flavor);
        keyHash = keyHashFor(secret);
      }

      await generateEnvFromYaml(
        input,
        output: output,
        keyHash: keyHash,
      );
    }

    if (dir case final String dir) {
      final config = pnvConfig();
      final files = fs.directory(dir).listSync().whereType<File>();

      for (final file in files) {
        List<int>? keyHash;
        if (config == null) {
          keyHash = this.keyHash;
        } else {
          if (config.flavorsFor(flavor) case final Set<String> flavors) {
            final fileFlavor = flavorFrom(file.path);

            if (!flavors.contains(fileFlavor)) {
              final relative = p.relative(
                file.path,
                from: fs.currentDirectory.path,
              );
              logger.detail(
                'Skipping file "$relative", '
                'flavor "$fileFlavor" does not match "$flavor".',
              );
              continue;
            }

            keyHash = this.keyHash;
          } else {
            final flavor = flavorFrom(file.path);
            final secret = secretFor(flavor: flavor);
            keyHash = keyHashFor(secret);
          }
        }

        await generateEnvFromYaml(
          file.path,
          output: output,
          keyHash: keyHash,
        );
      }
    }

    return 0;
  }
}
