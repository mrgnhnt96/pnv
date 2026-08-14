import 'package:args/command_runner.dart';
import 'package:file/file.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:pnv/src/mixins/file_mixin.dart';

class ToDartDefineCommand extends Command<int> {
  ToDartDefineCommand({
    required this.fs,
    required this.logger,
  }) {
    argParser.addFlag(
      'per-line',
      abbr: 'l',
      negatable: false,
      help: 'Emit one -Dkey=value per line instead of a single space-joined '
          'string.\n'
          'Required for values containing whitespace, which cannot survive '
          'command substitution:\n'
          '  pnv to-dart-define -l .env | xargs flutter build apk',
    );
  }

  final FileSystem fs;
  final Logger logger;

  @override
  String get usage => super.usage.replaceFirst('[arguments]', '<files>');

  @override
  String get description => 'Converts an env file to Dart Define arguments';

  @override
  String get name => 'to-dart-define';

  bool get perLine => switch (argResults?['per-line']) {
        true => true,
        _ => false,
      };

  @override
  Future<int> run() async {
    final rest = argResults?.rest ?? const <String>[];

    if (rest.isEmpty) {
      printUsage();
      return 1;
    }

    final lines = <String>[];

    for (final path in rest) {
      final file = fs.file(path);

      if (!file.existsSync()) {
        logger.err('File $path does not exist.');
        return 1;
      }

      lines.addAll(file.readAsLinesSync());
    }

    final defines = <String>[];
    final withWhitespace = <String>[];

    for (final line in lines) {
      if (line.trimLeft().startsWith('#')) {
        continue;
      }

      // Split on the FIRST `=` only. Splitting on every one and demanding
      // exactly two parts silently dropped every base64 value, because
      // base64 padding is `=`.
      final index = line.indexOf('=');
      if (index == -1) {
        continue;
      }

      final key = line.substring(0, index).replaceAll('"', '').trim();
      final (value: raw, comment: _) = splitEnvValue(line.substring(index + 1));
      final value = unquoteEnvValue(raw);

      if (key.isEmpty || value.isEmpty) {
        continue;
      }

      if (value.contains(RegExp(r'\s'))) {
        withWhitespace.add(key);
      }

      defines.add('-D$key=$value');
    }

    if (perLine) {
      for (final define in defines) {
        logger.write('$define\n');
      }

      return 0;
    }

    if (withWhitespace.isNotEmpty) {
      // A quoted argument does not survive `$(...)`: the shell word-splits the
      // RESULT of the substitution, and no amount of quoting inside it
      // prevents that. Saying so is the only honest option.
      logger.err(
        '⚠ ${withWhitespace.join(', ')} contain whitespace and will be split '
        r'into separate arguments by `$(pnv to-dart-define ...)`. '
        'Use --per-line with xargs instead.',
      );
    }

    logger.write('${defines.join(' ')}\n');

    return 0;
  }
}
