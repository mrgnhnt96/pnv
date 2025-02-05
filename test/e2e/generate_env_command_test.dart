import 'dart:convert';
import 'dart:io';

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:pnv/src/commands/generate_env_command.dart';
import 'package:pnv/src/models/pnv_config.dart';
import 'package:test/test.dart';

import '../../bin/pnv.dart' as pnv;

void main() {
  group(GenerateEnvCommand, () {
    late Logger logger;
    late FileSystem fs;
    late String home;

    const secret =
        'SECRET;lyho8D18bGu/BzQgpoCb3KhTEJk/1jPC+Jpa+Kk5E1dD2R3/77TZJeREe5coaPA9fGxrvwc0IKaAm9w=';
    const decryptedSecret = 'legend-of-zelda';
    final encryptedDirectory = p.join(p.separator, 'envs');
    final decryptedDirectory = p.join(p.separator, 'dist');
    final appLozYaml = p.join(encryptedDirectory, 'app.loz.yaml');
    final appLozEnv = p.join(decryptedDirectory, 'app.loz.env');
    final appLocalYaml = p.join(encryptedDirectory, 'app.local.yaml');
    final appLocalEnv = p.join(decryptedDirectory, 'app.local.env');
    final localYaml = p.join(encryptedDirectory, 'local.yaml');
    final localEnv = p.join(decryptedDirectory, 'local.env');

    setUp(() {
      home = Platform.environment['HOME']!;

      logger = _MockLogger();
      fs = MemoryFileSystem.test();

      when(() => logger.err(any())).thenAnswer((e) {
        print(e.positionalArguments.first);
      });

      fs.directory(encryptedDirectory).createSync(recursive: true);
    });

    String prepEnv(_KeyType? type) {
      const key = 'oI0tNittVqP_nLwY';

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

        fs.file('$home/.pnv/local.key')
          ..createSync(recursive: true)
          ..writeAsStringSync(key);
      }

      String arg;
      switch (type) {
        case _KeyType.key:
          arg = '--key=$key';
        case _KeyType.file:
          arg = '--key-file=$home/.pnv/local.key';
          fs.file('$home/.pnv/local.key')
            ..createSync(recursive: true)
            ..writeAsStringSync(key);
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
      const expectedContent = '''
# .
# .my
MY_SECRET="$decryptedSecret"
''';

      group('using the file option', () {
        Future<void> run(_KeyType type) async {
          final arg = prepEnv(type);

          fs.file(appLocalYaml)
            ..createSync()
            ..writeAsStringSync('''
my:
  secret: $secret
''');

          await pnv.main(
            [
              'generate-env',
              arg,
              '--output=$decryptedDirectory',
              '--file=$appLocalYaml',
            ],
            providedFs: fs,
            providedLogger: logger,
          );
        }

        for (final type in _KeyType.core) {
          test('with ${type.description}', () async {
            final file = fs.file(appLocalEnv);
            expect(file.existsSync(), isFalse);

            await run(type);

            expect(file.existsSync(), isTrue);
            expect(file.readAsStringSync(), expectedContent);
          });
        }
      });

      group('using the directory option', () {
        Future<void> run([_KeyType? type]) async {
          final arg = prepEnv(type);

          final file = switch (type) {
            _KeyType.alias => appLozYaml,
            _KeyType.noExtension => localYaml,
            _ => appLocalYaml,
          };

          fs.file(file)
            ..createSync()
            ..writeAsStringSync('''
my:
  secret: $secret
''');

          await pnv.main(
            [
              'generate-env',
              arg,
              '--output=$decryptedDirectory',
              '--dir=$encryptedDirectory',
            ],
            providedFs: fs,
            providedLogger: logger,
          );
        }

        for (final type in _KeyType.core) {
          test('with ${type.description}', () async {
            final file = fs.file(appLocalEnv);
            expect(file.existsSync(), isFalse);

            await run(type);

            expect(file.existsSync(), isTrue);
            expect(file.readAsStringSync(), expectedContent);
          });
        }

        test('should parse when no flavor is specified', () async {
          final file = fs.file(appLocalEnv);
          expect(file.existsSync(), isFalse);

          await run();

          expect(file.existsSync(), isTrue);
          expect(file.readAsStringSync(), expectedContent);
        });

        test('should parse when flavor alias is used', () async {
          final file = fs.file(appLozEnv);
          expect(file.existsSync(), isFalse);

          await run(_KeyType.alias);

          expect(file.existsSync(), isTrue);
          expect(file.readAsStringSync(), expectedContent);
        });

        test('should parse when file does not have extension', () async {
          final file = fs.file(localEnv);
          expect(file.existsSync(), isFalse);

          await run(_KeyType.noExtension);

          expect(file.existsSync(), isTrue);
          expect(file.readAsStringSync(), expectedContent);
        });
      });
    });
  });
}

class _MockLogger extends Mock implements Logger {}

enum _KeyType {
  key,
  file,
  flavor,
  alias,
  noExtension;

  String get description {
    return switch (this) {
      _KeyType.key => '--key',
      _KeyType.file => '--key-file',
      _KeyType.flavor => '--flavor=local',
      _ => '',
    };
  }

  static List<_KeyType> get core => [
        _KeyType.key,
        _KeyType.file,
        _KeyType.flavor,
      ];
}
