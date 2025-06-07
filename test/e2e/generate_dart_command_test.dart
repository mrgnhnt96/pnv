// ignore_for_file: unnecessary_await_in_return

import 'dart:convert';

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:pnv/src/commands/generate/generate_dart_command.dart';
import 'package:pnv/src/models/pnv_config.dart';
import 'package:test/test.dart';

import '../../bin/pnv.dart' as pnv;

void main() {
  group(GenerateDartCommand, () {
    late Logger logger;
    late FileSystem fs;

    const decryptedSecret = 'legend-of-zelda';
    final decryptedDirectory = p.join(p.separator, 'dist');
    final dartDirectory = p.join(decryptedDirectory, 'dart');
    final appLozEnv = p.join(decryptedDirectory, 'app.loz.env');
    final appLocalEnv = p.join(decryptedDirectory, 'app.local.env');
    final appDart = p.join(dartDirectory, 'app.dart');
    final localEnv = p.join(decryptedDirectory, 'local.env');
    final localDart = p.join(dartDirectory, 'local.dart');

    setUp(() {
      logger = _MockLogger();
      fs = MemoryFileSystem.test();

      when(() => logger.err(any())).thenAnswer((e) {
        print(e.positionalArguments.first);
      });

      fs.directory(decryptedDirectory).createSync(recursive: true);
    });

    String prepEnv(_KeyType? type) {
      void setupFlavor() {
        fs.file('.pnvrc')
          ..createSync()
          ..writeAsStringSync(
            jsonEncode(
              PnvConfig(
                storage: '~/.pnv',
                flavors: const {
                  'local': ['loz'],
                },
              ),
            ),
          );
      }

      String arg;
      switch (type) {
        case _KeyType.flavor:
          arg = '--flavor=local';
          setupFlavor();
        case _KeyType.noExtension:
          arg = '--flavor=local';
          setupFlavor();
        case _KeyType.alias:
          arg = '--flavor=loz';
          setupFlavor();
        case null:
          arg = '';
          setupFlavor();
      }

      return arg;
    }

    group('runs successfully', () {
      const expectedAppContent = '''
class App {
  const App._();

  static const mySecret = String.fromEnvironment('MY_SECRET');
}
''';
      const expectedLocalContent = '''
class Local {
  const Local._();

  static const mySecret = String.fromEnvironment('MY_SECRET');
}
''';

      group('using the directory option', () {
        Future<void> run([_KeyType? type]) async {
          final arg = prepEnv(type);

          final file = switch (type) {
            _KeyType.alias => appLozEnv,
            _KeyType.noExtension => localEnv,
            _ => appLocalEnv,
          };

          fs.file(file)
            ..createSync()
            ..writeAsStringSync('''
# .
# .my
MY_SECRET="$decryptedSecret"
''');

          await pnv.main(
            [
              'generate',
              'dart',
              arg,
              '--output=$dartDirectory',
              '--dir=$decryptedDirectory',
            ],
            providedFs: fs,
            providedLogger: logger,
          );
        }

        for (final type in _KeyType.core) {
          test('with ${type.description}', () async {
            final file = fs.file(appDart);
            expect(file.existsSync(), isFalse);

            await run(type);

            expect(file.existsSync(), isTrue);
            expect(file.readAsStringSync(), expectedAppContent);
          });
        }

        test('should parse when no flavor is specified', () async {
          final file = fs.file(appDart);
          expect(file.existsSync(), isFalse);

          await run();

          expect(file.existsSync(), isTrue);
          expect(file.readAsStringSync(), expectedAppContent);
        });

        test('should parse when flavor alias is used', () async {
          final file = fs.file(appDart);
          expect(file.existsSync(), isFalse);

          await run(_KeyType.alias);

          expect(file.existsSync(), isTrue);
          expect(file.readAsStringSync(), expectedAppContent);
        });

        test('should parse when file does not have extension', () async {
          final file = fs.file(localDart);
          expect(file.existsSync(), isFalse);

          await run(_KeyType.noExtension);

          expect(file.existsSync(), isTrue);
          expect(file.readAsStringSync(), expectedLocalContent);
        });
      });

      group('should infer types', () {
        Future<void> run() async {
          const type = _KeyType.noExtension;
          final arg = prepEnv(type);

          final file = switch (type) {
            _KeyType.alias => appLozEnv,
            _KeyType.noExtension => localEnv,
            _ => appLocalEnv,
          };
          fs.file(file)
            ..createSync()
            ..writeAsStringSync('''
# .
# .my
MY_STRING="hello"
MY_NUM=123
MY_BOOL=true
MY_EMPTY_STRING=""
MY_EMPTY=
MY_DECLARED_NUM= #num
MY_DECLARED_STRING= #string
MY_DECLARED_BOOL= #bool
''');

          await pnv.main(
            [
              'generate',
              'dart',
              arg,
              '--output=$dartDirectory',
              '--dir=$decryptedDirectory',
            ],
            providedFs: fs,
            providedLogger: logger,
          );
        }

        test('should infer types', () async {
          final file = fs.file(localDart);
          expect(file.existsSync(), isFalse);

          await run();

          final expectedLines = [
            "  static const myString = String.fromEnvironment('MY_STRING');",
            "  static const myNum = int.fromEnvironment('MY_NUM');",
            "  static const myBool = bool.fromEnvironment('MY_BOOL');",
            // ignore: lines_longer_than_80_chars
            "  static const myEmptyString = String.fromEnvironment('MY_EMPTY_STRING');",
            "  static const myEmpty = String.fromEnvironment('MY_EMPTY');",
            "  static const myDeclaredNum = int.fromEnvironment('MY_DECLARED_NUM');",
            "  static const myDeclaredString = String.fromEnvironment('MY_DECLARED_STRING');",
            "  static const myDeclaredBool = bool.fromEnvironment('MY_DECLARED_BOOL');",
          ];

          expect(file.existsSync(), isTrue);
          for (final line in file.readAsLinesSync()) {
            expectedLines.remove(line);
          }

          expect(expectedLines, isEmpty);
        });
      });
    });
  });
}

class _MockLogger extends Mock implements Logger {}

enum _KeyType {
  flavor,
  alias,
  noExtension;

  String get description {
    return switch (this) {
      _KeyType.flavor => '--flavor=local',
      _ => '',
    };
  }

  static List<_KeyType> get core => [
        _KeyType.flavor,
      ];
}
