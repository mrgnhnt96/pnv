import 'package:change_case/change_case.dart';
import 'package:file/file.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:pnv/src/models/pnv_config.dart';
import 'package:pnv/src/pnv_exception.dart';
import 'package:yaml/yaml.dart';

mixin FileMixin {
  Logger get logger;
  FileSystem get fs;

  String? get input;

  String decrypt(String value, List<int> keyHash, {String? context});

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

  /// Renders [path] into .env text without writing anything.
  ///
  /// Rendering is separated from writing so a batch can fail before any file
  /// reaches disk — a half-written output directory is worse than none.
  String renderEnvFromYaml(
    String path, {
    required List<int> keyHash,
  }) {
    final file = fs.file(path);

    if (!file.existsSync()) {
      throw PnvException('Input file "$path" does not exist.');
    }

    final content = file.readAsStringSync();

    final yaml = loadYaml(content);

    if (yaml == null) {
      logger.warn('👀 Input file "$path" is empty.');
      return '';
    }

    if (yaml is! YamlMap) {
      throw PnvException('Input file "$path" is not a valid .yaml file.');
    }

    final env = StringBuffer();

    void write(
      Iterable<String> prefix,
      String key,
      String value, {
      required String? comment,
    }) {
      var prefixString = '';
      if (prefix.isNotEmpty) {
        prefixString = prefix.join('_');
        prefixString += '_';
      }

      final envVarKey = '$prefixString$key'.toUpperCase().replaceAll('-', '_');

      var entry = '$envVarKey=$value';
      if (comment != null) {
        entry += ' # $comment';
      }

      env.writeln(entry);
    }

    final entries = envEntriesFromYaml(yaml, source: content);

    void decryptValue(
      Iterable<String> prefix,
      String key,
      String value, {
      required String? comment,
    }) {
      var plainText = value;

      if (value.startsWith('SECRET;')) {
        plainText = decrypt(
          value,
          keyHash,
          context: '${p.relative(path)} → ${[...prefix, key].join('.')}',
        );
      }

      write(prefix, key, '"${escapeEnvValue(plainText)}"', comment: comment);
    }

    void writeEntry(EnvEntries entry) {
      if (entry.entries case final entries?) {
        env.writeln('# .${entry.parents.join('.')}');
        if (entries case [final sub, ...]) {
          env.writeln('# .${sub.parents.join('.')}');
        }

        for (final sub in entries) {
          writeEntry(sub);
        }
      } else if (entry
          case EnvEntries(
            :final key,
            :final value,
            :final comment,
            :final parents
          )) {
        switch (value) {
          case String():
            decryptValue(parents, key, value, comment: comment);
          case Null():
            write(parents, key, '', comment: comment);
          case int():
          case double():
          case bool():
            write(parents, key, '$value', comment: comment);
          case _:
            throw PnvException(
              'Unsupported value type for "$key": ${value.runtimeType} '
              '($value). Lists are not supported.',
            );
        }
      }
    }

    for (final entry in entries) {
      writeEntry(entry);
    }

    return env.toString();
  }

  Future<bool> generateEnvFromYaml(
    String path, {
    required String output,
    required List<int> keyHash,
  }) async {
    final String content;
    try {
      content = renderEnvFromYaml(path, keyHash: keyHash);
    } on PnvException catch (e) {
      logger.err('❌ ${e.message}');
      return false;
    }

    final outputFile = outputEnvFileFor(path, output);

    await writeEnvFile(outputFile, content);

    return true;
  }

  File outputEnvFileFor(String path, String output) {
    final outputFileName = '${p.basenameWithoutExtension(path)}.env';

    return fs.file(
      fs.path.join(fs.currentDirectory.path, output, outputFileName),
    );
  }

  Future<void> writeEnvFile(File outputFile, String content) async {
    final outDir = outputFile.parent;

    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }

    await outputFile.writeAsString(content);

    logger.info('${green.wrap('✓')} Generated .env file '
        'at ${yellow.wrap(p.relative(outputFile.path))}');
  }

  Map<String, ValueType>? entriesFromEnv(String input) {
    final file = fs.file(input);

    if (!file.existsSync()) {
      logger.err('❌ Input file "$input" does not exist.');
      return null;
    }

    final entries = <String, ValueType>{};

    for (final line in file.readAsStringSync().split('\n')) {
      if (line.trimLeft().startsWith('#')) {
        continue;
      }

      final index = line.indexOf('=');
      if (index == -1) {
        continue;
      }

      final key = line.substring(0, index);
      final value = line.substring(index + 1);

      final sanitized = key.replaceAll('"', '').trim();

      if (sanitized.isEmpty) {
        logger.detail('Skipping line "$line" because it has no key.');
        continue;
      }

      entries[sanitized] = getValueType(value);
    }

    return entries;
  }

  Future<bool> generateDartFromEnv(
    String input, {
    required String output,
    required String? className,
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
    final clazz = (className ?? baseName).toPascalCase();
    final outputFile = p.join(output, '$baseName.dart');

    final fields = resolveFields(entries, className: clazz, input: input);

    if (fields == null) {
      return false;
    }

    logger.detail('🔍 Generating .dart file at "$outputFile".');
    final outFile = fs.file(outputFile);

    await outFile.create(recursive: true);

    final body = StringBuffer();

    for (final MapEntry(key: fieldName, value: (envKey, type))
        in fields.entries) {
      body.writeln(
        '  static const $fieldName = ${type.fromEnvironment(envKey)};',
      );
    }

    final content = '''
$generatedFileHeader
class $clazz {
  const $clazz._();

${body.toString().trimRight()}
}
''';

    await outFile.writeAsString(content);

    logger.info('${green.wrap('✓')} Generated .dart file at '
        '${yellow.wrap(p.relative(outputFile))}');

    return true;
  }

  /// Maps each env key to the Dart field that will hold it, or null when any
  /// key cannot become one.
  ///
  /// Emitting a field name without checking it produced Dart that did not
  /// compile — `static const 2FaEnabled`, `static const class`, and two keys
  /// differing only by `-` vs `_` colliding on one name. The error belongs
  /// here, where the offending env key is still in hand.
  Map<String, (String, ValueType)>? resolveFields(
    Map<String, ValueType> entries, {
    required String className,
    required String input,
  }) {
    final fields = <String, (String, ValueType)>{};
    final problems = <String>[];

    for (final MapEntry(:key, value: type) in entries.entries) {
      final fieldName = key.toCamelCase();

      if (!_validIdentifier.hasMatch(fieldName)) {
        problems.add(
          '"$key" becomes "$fieldName", which is not a valid Dart identifier',
        );
        continue;
      }

      if (dartReservedWords.contains(fieldName)) {
        problems.add('"$key" becomes "$fieldName", which is a Dart keyword');
        continue;
      }

      if (fieldName == className) {
        problems.add(
          '"$key" becomes "$fieldName", which collides with the class name',
        );
        continue;
      }

      if (fields[fieldName] case (final other, _)) {
        problems.add('"$key" and "$other" both become "$fieldName"');
        continue;
      }

      fields[fieldName] = (key, type);
    }

    if (problems.isEmpty) {
      return fields;
    }

    logger.err('❌ Cannot generate a Dart class from "$input":');
    for (final problem in problems) {
      logger.err('   • $problem');
    }
    logger.err('   Rename the offending keys, or exclude them from the .env.');

    return null;
  }

  ValueType getValueType(String raw) {
    final (:value, :comment) = splitEnvValue(raw);

    if (comment case final String type
        when RegExp(r'^[a-zA-Z]+$').hasMatch(type)) {
      final result = switch (type.toLowerCase()) {
        'num' => ValueType.num,
        'int' => ValueType.num,
        'string' => ValueType.string,
        'bool' => ValueType.bool,
        _ => null,
      };

      if (result != null) {
        return result;
      }

      logger.warn('Did not recognize type "$type" for value "$value".');
    }

    final unquoted = unquoteEnvValue(value);

    if (int.tryParse(unquoted) case int()) {
      return ValueType.num;
    }

    return switch (unquoted) {
      'false' => ValueType.bool,
      'true' => ValueType.bool,
      _ => ValueType.string,
    };
  }
}

/// The header every generated Dart file starts with.
///
/// `generate dart` uses this to tell files it wrote from files it did not,
/// before it deletes anything in the output directory.
const generatedFileHeader = '''
// dart format off
// ignore_for_file: lines_longer_than_80_chars
''';

final _validIdentifier = RegExp(r'^[a-zA-Z_$][a-zA-Z0-9_$]*$');

/// Words Dart will not accept as an identifier.
const dartReservedWords = {
  'assert',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'default',
  'do',
  'else',
  'enum',
  'extends',
  'false',
  'final',
  'finally',
  'for',
  'if',
  'in',
  'is',
  'new',
  'null',
  'rethrow',
  'return',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'var',
  'void',
  'while',
  'with',
};

/// Splits an .env value from its trailing `# type` comment.
///
/// A `#` inside a double-quoted value is part of the value, so a naive split
/// on every `#` mangles any secret containing one.
({String value, String? comment}) splitEnvValue(String raw) {
  final text = raw.trimLeft();

  if (text.startsWith('"')) {
    var i = 1;
    while (i < text.length) {
      if (text[i] == r'\') {
        i += 2;
        continue;
      }
      if (text[i] == '"') break;
      i++;
    }

    if (i < text.length) {
      final value = text.substring(0, i + 1);
      final rest = text.substring(i + 1);
      final hash = rest.indexOf('#');

      return (
        value: value,
        comment: hash == -1 ? null : rest.substring(hash + 1).trim(),
      );
    }
  }

  final hash = text.indexOf('#');

  if (hash == -1) {
    return (value: text.trim(), comment: null);
  }

  return (
    value: text.substring(0, hash).trim(),
    comment: text.substring(hash + 1).trim(),
  );
}

/// Escapes a plaintext value for a double-quoted .env entry.
///
/// Without this a value containing a quote emits unparseable syntax and a
/// value containing a newline splits the entry across two lines, silently
/// truncating everything after the break when it is read back.
String escapeEnvValue(String value) {
  return value
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\r', r'\r')
      .replaceAll('\n', r'\n');
}

/// The inverse of [escapeEnvValue].
String unescapeEnvValue(String value) {
  final out = StringBuffer();

  for (var i = 0; i < value.length; i++) {
    if (value[i] != r'\' || i + 1 >= value.length) {
      out.write(value[i]);
      continue;
    }

    i++;
    out.write(
      switch (value[i]) {
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        final other => other,
      },
    );
  }

  return out.toString();
}

/// Strips the surrounding quotes from an .env value and unescapes it.
String unquoteEnvValue(String value) {
  if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
    return unescapeEnvValue(value.substring(1, value.length - 1));
  }

  return value;
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

class EnvEntries {
  const EnvEntries.sub(
    this.key,
    List<EnvEntries> this.entries,
  )   : value = null,
        comment = null,
        parents = const [];

  const EnvEntries.value(
    this.key,
    this.value, {
    required this.comment,
    required this.parents,
  }) : entries = null;

  final String key;
  final Iterable<String> parents;
  final dynamic value;
  final String? comment;
  final List<EnvEntries>? entries;
}

List<EnvEntries> envEntriesFromYaml(
  YamlMap yaml, {
  required String source,
  Iterable<String>? parents,
}) {
  parents ??= [];

  final entries = <EnvEntries>[];

  for (final MapEntry(key: keyNode, value: valueNode) in yaml.nodes.entries) {
    final key = '${(keyNode as YamlScalar).value}';

    if (valueNode is YamlMap) {
      entries.add(
        EnvEntries.sub(
          key,
          envEntriesFromYaml(
            valueNode,
            source: source,
            parents: parents.followedBy([key]),
          ),
        ),
      );
      continue;
    }

    entries.add(
      EnvEntries.value(
        key,
        valueNode.value,
        comment: commentAfter(valueNode, source),
        parents: parents,
      ),
    );
  }

  return entries;
}

/// The trailing comment on [node]'s own line, if any.
///
/// Read from the node's source span rather than by scanning the block for a
/// line containing `<key>:` — that matched substrings, and the last match won,
/// so a nested `db.port: # int` attached its type to an unrelated top-level
/// `port:`.
String? commentAfter(YamlNode node, String source) {
  final end = node.span.end.offset;

  if (end > source.length) return null;

  final lineEnd = source.indexOf('\n', end);
  final rest = source.substring(end, lineEnd == -1 ? source.length : lineEnd);

  final hash = rest.indexOf('#');

  if (hash == -1) return null;

  final comment = rest.substring(hash + 1).trim();

  return comment.isEmpty ? null : comment;
}
