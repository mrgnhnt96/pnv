import 'dart:convert';
import 'dart:io';

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pnv/src/commands/decrypt_command.dart';
import 'package:pnv/src/models/pnv_config.dart';
import 'package:test/test.dart';

import '../../bin/pnv.dart' as pnv;

void main() {
  group(DecryptCommand, () {
    late Logger logger;
    late FileSystem fs;
    late String home;

    setUp(() {
      home = Platform.environment['HOME']!;

      logger = _MockLogger();
      fs = MemoryFileSystem.test();

      when(() => logger.err(any())).thenAnswer((e) {
        print(e.positionalArguments.first);
      });
    });

    Future<void> run(_KeyType type) async {
      const key = 'oI0tNittVqP_nLwY';

      String arg;
      switch (type) {
        case _KeyType.key:
          arg = '--key=$key';
        case _KeyType.file:
          arg = '--key-file=$home/.pnv/some.key';
          fs.file('$home/.pnv/some.key')
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
                    'loz': ['loz'],
                  },
                ),
              ),
            );

          fs.file('$home/.pnv/loz.key')
            ..createSync(recursive: true)
            ..writeAsStringSync(key);
      }

      const secret =
          'SECRET;lyho8D18bGu/BzQgpoCb3KhTEJk/1jPC+Jpa+Kk5E1dD2R3/77TZJeREe5coaPA9fGxrvwc0IKaAm9w=';

      await pnv.main(
        ['decrypt', arg, secret],
        providedFs: fs,
        providedLogger: logger,
      );
    }

    group('runs successfully', () {
      for (final type in _KeyType.values) {
        test('with ${type.description}', () async {
          String? value;
          when(() => logger.write(any())).thenAnswer((e) {
            value = switch (e.positionalArguments.first) {
              final String v when value == null => value = v.trim(),
              _ => value,
            };
          });

          await run(type);

          expect(value, isNotNull);
          expect(value, 'legend-of-zelda');
          expect(exitCode, 0);
        });
      }
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
