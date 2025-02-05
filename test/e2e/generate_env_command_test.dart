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
    final encryptedYamlFile = p.join(encryptedDirectory, 'app.loz.yaml');
    final decryptedDirectory = p.join(p.separator, 'dist');
    final decryptedEnvFile = p.join(decryptedDirectory, 'app.loz.env');

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
          arg = '--flavor=loz';
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
        case null:
          arg = '';
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

          fs.file(encryptedYamlFile)
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
              '--file=$encryptedYamlFile',
            ],
            providedFs: fs,
            providedLogger: logger,
          );
        }

        for (final type in _KeyType.values) {
          test('with ${type.description}', () async {
            final file = fs.file(decryptedEnvFile);
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

          fs.file(encryptedYamlFile)
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

        for (final type in _KeyType.values) {
          test('with ${type.description}', () async {
            final file = fs.file(decryptedEnvFile);
            expect(file.existsSync(), isFalse);

            await run(type);

            expect(file.existsSync(), isTrue);
            expect(file.readAsStringSync(), expectedContent);
          });
        }

        test('should parse when no flavor is specified', () async {
          final file = fs.file(decryptedEnvFile);
          expect(file.existsSync(), isFalse);

          await run();

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
  flavor;

  String get description {
    return switch (this) {
      _KeyType.key => '--key',
      _KeyType.file => '--key-file',
      _KeyType.flavor => '--flavor',
    };
  }
}
