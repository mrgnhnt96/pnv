import 'dart:convert';
import 'dart:io';

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:pnv/src/commands/create/create_flavor_command.dart';
import 'package:pnv/src/models/pnv_config.dart';
import 'package:test/test.dart';

import '../../bin/pnv.dart' as pnv;

void main() {
  group(CreateFlavorCommand, () {
    late Logger logger;
    late FileSystem fs;
    late String home;

    Future<void> run() async {
      await pnv.main(
        ['create', 'flavor', '--name=loz'],
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

      when(() => logger.progress(any())).thenAnswer((e) {
        return _MockProgress();
      });
    });

    group('runs successfully', () {
      setUp(() {
        fs.directory(p.join(home, '.pnv')).createSync(recursive: true);
      });

      void createConfig([Map<String, List<String>>? flavors]) {
        final toSave = PnvConfig(
          storage: '~/.pnv',
          flavors: flavors ?? {},
        );

        fs.currentDirectory.childFile('.pnvrc')
          ..createSync()
          ..writeAsStringSync(jsonEncode(toSave));
      }

      PnvConfig getConfig() {
        final file = fs.file('.pnvrc');
        expect(file.existsSync(), isTrue);

        final content = file.readAsStringSync();

        return PnvConfig.fromJson(
          jsonDecode(content) as Map<String, dynamic>,
        );
      }

      test('and adds new flavor when no flavors exist', () async {
        createConfig();

        await run();

        final expected = PnvConfig(
          storage: '~/.pnv',
          flavors: const {
            'loz': [],
          },
        );

        expect(getConfig(), expected);
        final newKeyFile = fs.file('$home/.pnv/loz.key');
        expect(newKeyFile.existsSync(), isTrue);
        expect(newKeyFile.readAsStringSync(), isNotEmpty);
      });

      test('and adds new flavor when flavors exist', () async {
        createConfig(
          {
            'oot': [],
          },
        );

        await run();

        final expected = PnvConfig(
          storage: '~/.pnv',
          flavors: const {
            'oot': [],
            'loz': [],
          },
        );

        expect(getConfig(), expected);

        final newKeyFile = fs.file('$home/.pnv/loz.key');
        expect(newKeyFile.existsSync(), isTrue);
        expect(newKeyFile.readAsStringSync(), isNotEmpty);
      });
    });
  });
}

class _MockLogger extends Mock implements Logger {}

class _MockProgress extends Mock implements Progress {}
