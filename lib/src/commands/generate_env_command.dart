import 'package:file/file.dart';
import 'package:path/path.dart' as p;
import 'package:pnv/src/commands/cryptic_command.dart';
import 'package:pnv/src/handlers/decrypt_handler.dart';
import 'package:yaml/yaml.dart';

class GenerateEnvCommand extends CrypticCommand with DecryptHandler {
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
        valueHelp: 'infra.local.yaml',
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
  String get name => 'generate-env';

  @override
  String get description => 'Generate a .env file from a .yaml file.';

  @override
  List<String> get aliases => ['gen-env', 'env-gen', 'env'];

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
      print('Failed to generate .env file. $e');
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

      await parseFile(
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
          if (flavor case final String flavor) {
            final fileFlavor = flavorFrom(file.path);

            if (fileFlavor != flavor) {
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

        await parseFile(
          file.path,
          output: output,
          keyHash: keyHash,
        );
      }
    }

    return 0;
  }

  String flavorFrom(String path) {
    final ext = p.extension(path, 2);
    final sanitized =
        ext.replaceAll(RegExp(r'\.ya?ml'), '').replaceAll(RegExp(r'^\.'), '');

    return sanitized;
  }

  Future<bool> parseFile(
    String path, {
    required String output,
    required List<int> keyHash,
  }) async {
    final file = fs.file(path);

    if (!file.existsSync()) {
      logger.err('❌ Input file "$path" does not exist.');
      return false;
    }

    final content = file.readAsStringSync();

    final yaml = loadYaml(content);

    final inputFileName = p.basenameWithoutExtension(path);

    final outputFileName = '$inputFileName.env';

    final outputFile = fs.file(
      fs.path.join(
        fs.currentDirectory.path,
        output,
        outputFileName,
      ),
    );

    final outDir = outputFile.parent;

    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }

    if (yaml == null) {
      logger.warn('👀 Input file "$input" is empty.');
      await outputFile.writeAsString('');
      return true;
    }

    if (yaml is! YamlMap) {
      logger.err('❌ Input file "$input" is not a valid .yaml file.');
      return false;
    }

    final env = StringBuffer();

    void write(Iterable<String> prefix, String key, dynamic value) {
      var prefixString = '';
      if (prefix.isNotEmpty) {
        prefixString = prefix.join('_');
        prefixString += '_';
      }

      final envVarKey = '$prefixString$key'.toUpperCase().replaceAll('-', '_');

      env.writeln('$envVarKey=$value');
    }

    void traverse(
      Map<String, dynamic> data, {
      Iterable<String> prefix = const [],
    }) {
      final location = prefix.isNotEmpty ? '.${prefix.join('.')}' : '.';

      env.writeln('# $location');
      for (final key in data.keys) {
        final value = data[key];

        void decryptValue(String value) {
          var plainText = value;

          if (value.startsWith('SECRET;')) {
            plainText = decrypt(value, keyHash);
          }

          write(prefix, key, '"$plainText"');
        }

        final _ = switch (value) {
          String() => decryptValue(value),
          int() => write(prefix, key, value),
          double() => write(prefix, key, value),
          bool() => write(prefix, key, value),
          Map<String, dynamic>() =>
            traverse(value, prefix: prefix.followedBy([key])),
          YamlMap() => traverse(
              Map<String, dynamic>.from(value),
              prefix: prefix.followedBy([key]),
            ),
          Null() => null,
          _ => throw ArgumentError(
              'Unsupported value type. ${value.runtimeType} ($value)',
            ),
        };
      }
    }

    traverse(Map<String, dynamic>.from(yaml.value));

    await outputFile.writeAsString(env.toString());

    logger.info('✅ Generated .env file at "${p.relative(outputFile.path)}".');

    return true;
  }
}
