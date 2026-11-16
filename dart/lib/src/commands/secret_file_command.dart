import 'package:file/file.dart';
import 'package:path/path.dart' as p;
import 'package:pnv/src/commands/cryptic_command.dart';
import 'package:pnv/src/mixins/file_mixin.dart';
import 'package:pnv/src/pnv_exception.dart';
import 'package:yaml/yaml.dart';

/// Shared plumbing for commands that operate on a secrets YAML *file* rather
/// than on a value handed to them on the command line.
abstract class SecretFileCommand extends CrypticCommand {
  SecretFileCommand({
    required super.fs,
    required super.logger,
    bool requiresFile = true,
  }) {
    argParser.addOption(
      'file',
      abbr: 'i',
      aliases: ['input'],
      help: 'The .yaml file to $name.',
      valueHelp: 'envs/app.local.yaml',
      mandatory: requiresFile,
    );
  }

  String? get input => argResults['file'] as String?;

  /// The file to act on, validated.
  File get targetFile {
    final path = input;

    if (path == null || path.trim().isEmpty) {
      throw const PnvException('--file is required.');
    }

    final file = fs.file(path);

    if (!file.existsSync()) {
      throw PnvException('Input file "$path" does not exist.');
    }

    final ext = p.extension(path);
    if (ext != '.yaml' && ext != '.yml') {
      throw PnvException('Input file "$path" must be a .yaml file.');
    }

    return file;
  }

  /// The key to use, preferring what was asked for and falling back to the
  /// flavor implied by the file name — the same rule `generate env` uses, so
  /// the key follows where you are writing rather than what you remember.
  ({List<int> bytes, List<int> hash}) keyForFile(String path) {
    final named =
        key != null || keyFile != null || (flavor?.trim().isNotEmpty ?? false);

    if (named) {
      return (bytes: secretBytes, hash: keyHash);
    }

    final inferred = flavorFromPath(path);

    try {
      final secret = secretFor(flavor: inferred);
      return (bytes: decodeSecret(secret), hash: keyHashFor(secret));
    } on PnvException catch (e) {
      throw PnvException(
        'No key for "${p.relative(path)}": its name implies flavor '
        '"$inferred", which has no key. ${e.message}',
      );
    }
  }

  /// Splits a dotted path (`app.api-key`) into its segments.
  List<String> pathSegments(String raw) {
    final parts = raw.split('.').map((e) => e.trim()).toList();

    if (parts.isEmpty || parts.any((e) => e.isEmpty)) {
      throw PnvException(
        'Invalid key path "$raw". Use dots to separate keys, '
        'e.g. "app.api-key".',
      );
    }

    return parts;
  }

  /// Every leaf in [map], as (dotted path, value).
  ///
  /// Used by anything that has to walk a whole file: rotate, verify, show.
  static List<(List<String> path, YamlNode node)> leaves(
    YamlMap map, {
    List<String> parents = const [],
  }) {
    final out = <(List<String>, YamlNode)>[];

    for (final MapEntry(key: keyNode, value: valueNode) in map.nodes.entries) {
      final key = '${(keyNode as YamlScalar).value}';
      final path = [...parents, key];

      if (valueNode is YamlMap) {
        out.addAll(leaves(valueNode, parents: path));
      } else {
        out.add((path, valueNode));
      }
    }

    return out;
  }
}
