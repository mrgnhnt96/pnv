import 'dart:convert';
import 'dart:io';

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pnv/src/commands/init_command.dart';
import 'package:pnv/src/models/pnv_config.dart';
import 'package:test/test.dart';

import '../../bin/pnv.dart' as pnv;

void main() {
  group(InitCommand, () {
    late Logger logger;
    late FileSystem fs;
    late String home;

    Future<void> run() async {
      await pnv.main(
        ['init'],
        providedFs: fs,
        providedLogger: logger,
      );
    }

    setUp(() {
      home = Platform.environment['HOME']!;

      logger = _MockLogger();
      fs = MemoryFileSystem.test();

      when(() => logger.err(any())).thenAnswer((e) {
        print(e.positionalArguments.first);
      });
    });

    group('successfully finishes', () {
      setUp(() {
        fs.currentDirectory.childFile('pubspec.yaml')
          ..createSync()
          ..writeAsStringSync('''
name: bananas
''');

        when(
          () => logger.prompt(
            'Where would like to store the secrets?',
            defaultValue: any(named: 'defaultValue'),
          ),
        ).thenReturn('~/secrets/.pnv');
      });

      PnvConfig getConfig() {
        final file = fs.file('.pnvrc');
        expect(file.existsSync(), isTrue);

        final content = file.readAsStringSync();

        return PnvConfig.fromJson(
          jsonDecode(content) as Map<String, dynamic>,
        );
      }

      test('and creates a brand new config', () async {
        await run();

        final dir = fs.directory('$home/secrets/.pnv');
        expect(dir.existsSync(), isTrue);

        final expected = PnvConfig(
          storage: '~/secrets/.pnv',
          flavors: const {},
        );

        expect(getConfig(), expected);
        expect(exitCode, 0);
      });

      test('and creates a new config with existing flavors', () async {
        final dir = fs.directory('$home/secrets/.pnv')
          ..createSync(recursive: true);

        dir.childFile('local.key').createSync();

        await run();

        expect(dir.existsSync(), isTrue);

        final expected = PnvConfig(
          storage: '~/secrets/.pnv',
          flavors: const {
            'local': ['local'],
          },
        );

        expect(getConfig(), expected);
        expect(exitCode, 0);
      });
    });
  });
}

class _MockLogger extends Mock implements Logger {}
