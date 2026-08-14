import 'package:file/file.dart';
import 'package:path/path.dart' as p;
import 'package:pnv/src/commands/cryptic_command.dart';
import 'package:pnv/src/handlers/decrypt_handler.dart';
import 'package:pnv/src/mixins/file_mixin.dart';
import 'package:pnv/src/models/pnv_config.dart';
import 'package:pnv/src/pnv_exception.dart';

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
      throw PnvException(
        'Input file "$input" does not exist.',
      );
    }

    final ext = p.extension(input);
    if (!(ext == '.yaml' || ext == '.yml')) {
      throw PnvException('Input file "$input" must be a .yaml file.');
    }

    return input;
  }

  String? get directory {
    final directory = argResults['directory'] as String?;

    if (directory == null) {
      return null;
    }

    if (!fs.directory(directory).existsSync()) {
      throw PnvException(
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

    if (input == null && dir == null) {
      logger
        ..err('Failed to generate .env file(s)')
        ..err('Either --file or --directory must be provided.');
      return 1;
    }

    final config = pnvConfig();
    final selected = resolveFlavor(config);

    if (selected == null) {
      return 1;
    }

    final inputs = <String>[];

    if (input case final String input) {
      inputs.add(input);
    }

    if (dir case final String dir) {
      for (final file in fs.directory(dir).listSync().whereType<File>()) {
        if (selected.flavors case final Set<String> flavors) {
          final fileFlavor = flavorFrom(file.path);

          if (!flavors.contains(fileFlavor)) {
            final relative = p.relative(
              file.path,
              from: fs.currentDirectory.path,
            );
            logger.detail(
              'Skipping file "$relative", '
              'flavor "$fileFlavor" does not match "${selected.name}".',
            );
            continue;
          }
        }

        inputs.add(file.path);
      }
    }

    // Render everything before writing anything. Writing as we went left a
    // half-populated output directory behind whenever one file failed, and
    // which files survived depended on directory iteration order.
    final rendered = <File, String>{};

    for (final path in inputs) {
      final resolved = keyForInput(path, selected);

      if (resolved == null) {
        return 1;
      }

      try {
        rendered[outputEnvFileFor(path, output)] = renderEnvFromYaml(
          path,
          keyHash: resolved.hash,
          keyBytes: resolved.bytes,
        );
      } on PnvException catch (e) {
        logger.err('❌ ${e.message}');
        return 1;
      }
    }

    for (final MapEntry(key: file, value: content) in rendered.entries) {
      await writeEnvFile(file, content);
    }

    return 0;
  }

  /// Resolves `--flavor` against the config, or reports why it cannot.
  ///
  /// An unrecognised name used to resolve to "no flavor selected", which is
  /// the generate-everything path — so a typo widened the run to every
  /// environment on disk, production included, and exited 0.
  ({String? name, Set<String>? flavors})? resolveFlavor(PnvConfig? config) {
    final flavor = this.flavor?.trim();

    if (flavor == null || flavor.isEmpty) {
      return (name: null, flavors: null);
    }

    if (config == null) {
      logger.err(
        '❌ --flavor "$flavor" was given but no .pnvrc was found. '
        'Run `pnv init` first, or pass --key / --key-file instead.',
      );
      return null;
    }

    if (config.flavorsFor(flavor) case final Set<String> flavors) {
      return (name: flavor, flavors: flavors);
    }

    logger.err(
      '❌ Flavor "$flavor" is not in .pnvrc. '
      'Known flavors: ${config.flavors.keys.join(', ')}',
    );

    return null;
  }

  /// The key to decrypt [path] with, or null once the reason has been logged.
  ///
  /// Both forms are returned: the hash is the AES key, the raw bytes are what
  /// a v1 token's key id is checked against.
  ({List<int> bytes, List<int> hash})? keyForInput(
    String path,
    ({String? name, Set<String>? flavors}) selected,
  ) {
    if (key != null || keyFile != null || selected.name != null) {
      try {
        return (bytes: secretBytes, hash: keyHash);
      } on PnvException catch (e) {
        logger.err('❌ ${e.message}');
        return null;
      }
    }

    // No key was named, so the flavor comes from the file name.
    final inferred = flavorFrom(path);

    try {
      final secret = secretFor(flavor: inferred);
      return (bytes: decodeSecret(secret), hash: keyHashFor(secret));
    } on PnvException catch (e) {
      logger.err(
        '❌ No key for "${p.relative(path)}": its name implies flavor '
        '"$inferred", which has no key. ${e.message}',
      );
      return null;
    }
  }
}
