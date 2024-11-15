import 'package:path/path.dart' as p;
import 'package:pnv/src/commands/cryptic_command.dart';
import 'package:pnv/src/handlers/decrypt_handler.dart';
import 'package:yaml/yaml.dart';

class GenerateEnvCommand extends CrypticCommand with DecryptHandler {
  GenerateEnvCommand({required super.fs}) {
    argParser
      ..addOption(
        'input',
        abbr: 'i',
        help: 'The input .yaml file to generate the .env file from.',
        valueHelp: 'infra.local.yaml',
        mandatory: true,
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

  String get input {
    final input = argResults['input'] as String;

    if (!input.endsWith('.yaml')) {
      throw ArgumentError('Input file "$input" must be a .yaml file.');
    }

    return input;
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
    final output = this.output;

    final keyHash = this.keyHash;

    final file = fs.file(input);

    if (!file.existsSync()) {
      print('❌ Input file "$input" does not exist or was not readable.');
      return 1;
    }

    final content = file.readAsStringSync();

    final yaml = loadYaml(content);

    final inputFileName = p.basenameWithoutExtension(input);

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
      print('👀 Input file "$input" is empty.');
      await outputFile.writeAsString('');
      return 0;
    }

    if (yaml is! YamlMap) {
      print('❌ Input file "$input" is not a valid .yaml file.');
      return 1;
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

    print('✅ Generated .env file at "${p.relative(outputFile.path)}".');

    return 0;
  }
}
