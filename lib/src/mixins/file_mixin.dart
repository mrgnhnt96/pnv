import 'package:change_case/change_case.dart';
import 'package:file/file.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:pnv/src/models/pnv_config.dart';
import 'package:yaml/yaml.dart';

mixin FileMixin {
  Logger get logger;
  FileSystem get fs;

  String? get input;

  String decrypt(String value, List<int> keyHash);

  String flavorFrom(String path) {
    if (p.basenameWithoutExtension(path) case final name
        when !name.contains('.')) {
      return name;
    }

    final ext = p.extension(path, 2);
    final sanitized = ext
        .replaceAll(RegExp(r'\.env$'), '')
        .replaceAll(RegExp(r'\.ya?ml$'), '')
        .replaceAll(RegExp(r'^\.'), '');

    return sanitized;
  }

  Future<bool> actForFlavor({
    required String directory,
    required String? flavor,
    required PnvConfig config,
    required Future<bool> Function(String path) action,
  }) async {
    final files = fs.directory(directory).listSync().whereType<File>();

    for (final file in files) {
      if (flavor == null) {
        await action(file.path);
        continue;
      }

      if (config.flavorsFor(flavorFrom(flavor))
          case final Set<String> flavors) {
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

        final result = await action(file.path);
        if (!result) {
          return false;
        }
      }
    }

    return true;
  }

  Future<bool> generateEnvFromYaml(
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

  Map<String, ValueType>? entriesFromEnv(String input) {
    final file = fs.file(input);

    if (!file.existsSync()) {
      logger.err('❌ Input file "$input" does not exist.');
      return null;
    }

    final entries = <String, ValueType>{};

    for (final line in file.readAsStringSync().split('\n')) {
      if (line.startsWith('#')) {
        continue;
      }

      final parts = line.split('=');
      if (parts.length != 2) {
        logger
            .detail('Skipping line "$line" because it is not a valid env var.');
        continue;
      }

      final [key, value] = parts;
      final sanitized = key.replaceAll('"', '');
      final type = getValueType(value);
      entries[sanitized] = type;
    }

    return entries;
  }

  Future<bool> generateDartFromEnv(
    String input, {
    required String output,
  }) async {
    final entries = entriesFromEnv(input);

    if (entries == null) {
      return false;
    }

    final flavor = flavorFrom(input);

    var baseName = p.basenameWithoutExtension(input);
    if (flavor.isNotEmpty) {
      baseName = baseName.replaceAll('.$flavor', '');
    }
    final className = baseName.toPascalCase();
    final outputFile = p.join(output, '$baseName.dart');
    logger.detail('🔍 Generating .dart file at "$outputFile".');
    final outFile = fs.file(outputFile);

    await outFile.create(recursive: true);

    final fields = StringBuffer();

    for (final MapEntry(:key, value: type) in entries.entries) {
      final fieldName = key.toCamelCase();

      fields
          .writeln('  static const $fieldName = ${type.fromEnvironment(key)};');
    }

    final content = '''
class $className {
  const $className._();

${fields.toString().trimRight()}
}
''';

    await outFile.writeAsString(content);

    logger.info('✅ Generated .dart file at "${p.relative(outputFile)}".');

    return true;
  }

  ValueType getValueType(String value) {
    if (int.tryParse(value) case int()) {
      return ValueType.num;
    }

    final stringPatterns = [
      RegExp(r'^".*"$'),
      RegExp(r'^[\w]+$'),
    ];

    for (final pattern in stringPatterns) {
      if (pattern.hasMatch(value)) {
        return ValueType.string;
      }
    }

    return switch (value) {
      'false' => ValueType.bool,
      'true' => ValueType.bool,
      _ => ValueType.string,
    };
  }
}

enum ValueType {
  num,
  string,
  bool;

  String fromEnvironment(String key) => switch (this) {
        num => "int.fromEnvironment('$key')",
        string => "String.fromEnvironment('$key')",
        bool => "bool.fromEnvironment('$key')",
      };
}
