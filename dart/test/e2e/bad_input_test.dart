import 'dart:convert';
import 'dart:io';

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:pnv/src/handlers/flavor_handler.dart';
import 'package:pnv/src/models/pnv_config.dart';
import 'package:pnv/src/pnv_runner.dart';
import 'package:test/test.dart';

/// The failure paths.
///
/// The suite this joined had 38 passing tests and none of them fed pnv input
/// it could not handle, which is why every bug below shipped: each one made
/// the tool print a success line and exit 0 on input it got wrong. A fix
/// without a test here is a fix with a countdown on it.
void main() {
  late Logger logger;
  late FileSystem fs;
  late String home;
  late List<String> errors;
  late List<String> written;

  /// The key the fixtures are encrypted with, and the values behind them.
  const key = 'oI0tNittVqP_nLwY';
  const localSecret =
      'SECRET;lyho8D18bGu/BzQgpoCb3KhTEJk/1jPC+Jpa+Kk5E1dD2R3/77TZJeREe5c'
      'oaPA9fGxrvwc0IKaAm9w=';
  const localPlain = 'legend-of-zelda';

  setUp(() {
    home = Platform.environment['HOME']!;
    fs = MemoryFileSystem.test();
    logger = _MockLogger();
    errors = [];
    written = [];

    when(() => logger.err(any())).thenAnswer((i) {
      errors.add('${i.positionalArguments.first}');
    });
    when(() => logger.write(any())).thenAnswer((i) {
      written.add('${i.positionalArguments.first}');
    });
    when(() => logger.progress(any())).thenReturn(_MockProgress());
  });

  void writeConfig({Map<String, List<String>> flavors = const {'local': []}}) {
    fs.file('.pnvrc')
      ..createSync()
      ..writeAsStringSync(
        jsonEncode(PnvConfig(storage: '~/.pnv', flavors: flavors)),
      );

    for (final flavor in flavors.keys) {
      fs.file('$home/.pnv/$flavor.key')
        ..createSync(recursive: true)
        ..writeAsStringSync(key);
    }
  }

  Future<int> run(List<String> args) {
    return PnvRunner(
      fs: fs,
      logger: logger,
      flavorHandler: FlavorHandler(fs: fs, logger: logger),
    ).run(args);
  }

  String allErrors() => errors.join('\n');

  group('generate env', () {
    setUp(() {
      writeConfig(flavors: const {'local': [], 'prod': []});

      fs.file(p.join(p.separator, 'envs', 'app.local.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('v: $localSecret\n');
      fs.file(p.join(p.separator, 'envs', 'app.prod.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('v: plain\n');
    });

    test('an unknown --flavor fails instead of generating everything',
        () async {
      final code = await run([
        'generate',
        'env',
        '--dir=${p.join(p.separator, 'envs')}',
        '--output=${p.join(p.separator, 'dist')}',
        '--flavor=locl',
      ]);

      expect(code, 1, reason: 'a typo must not be treated as "no filter"');
      expect(allErrors(), contains('locl'));
      expect(allErrors(), contains('Known flavors'));
      expect(
        fs.file(p.join(p.separator, 'dist', 'app.prod.env')).existsSync(),
        isFalse,
        reason: 'the production environment must not be decrypted',
      );
    });

    test('a failed batch writes nothing at all', () async {
      fs.file(p.join(p.separator, 'envs', 'zbad.local.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('v: SECRET;GARBAGE\n');

      final code = await run([
        'generate',
        'env',
        '--dir=${p.join(p.separator, 'envs')}',
        '--output=${p.join(p.separator, 'dist')}',
        '--flavor=local',
      ]);

      expect(code, 1);
      expect(
        fs.file(p.join(p.separator, 'dist', 'app.local.env')).existsSync(),
        isFalse,
        reason: 'the good file must not be left behind by the failed batch',
      );
    });

    test('quotes and newlines in a value are escaped', () async {
      // Encrypted with `key`; the plaintext is `he "said"` + newline +
      // `line2` -- both characters that used to corrupt the .env.
      const tricky =
          'SECRET;+xFQo2HGZz4+9nZi766PD+0VNWzR1mdcJVQumR03lC4tJ28ndJ7pXzB'
          'F0vsRUKNhxmc+PvZ2Yu+ujw8=';

      fs.file(p.join(p.separator, 'envs', 'esc.local.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('v: $tricky\n');

      await run([
        'generate',
        'env',
        '--file=${p.join(p.separator, 'envs', 'esc.local.yaml')}',
        '--output=${p.join(p.separator, 'dist')}',
        '--flavor=local',
      ]);

      final out = fs
          .file(p.join(p.separator, 'dist', 'esc.local.env'))
          .readAsStringSync();

      expect(
        out.split('\n').where((e) => e.isNotEmpty).length,
        1,
        reason: 'a newline in a value must not split the entry across lines',
      );
      expect(out, contains(r'\n'));
      expect(out, contains(r'\"'));
    });

    test('a type comment does not leak onto a same-named key', () async {
      fs.file(p.join(p.separator, 'envs', 'cmt.local.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('port: 8080\ndb:\n  port: # int\n');

      await run([
        'generate',
        'env',
        '--file=${p.join(p.separator, 'envs', 'cmt.local.yaml')}',
        '--output=${p.join(p.separator, 'dist')}',
        '--flavor=local',
      ]);

      final out = fs
          .file(p.join(p.separator, 'dist', 'cmt.local.env'))
          .readAsStringSync();

      expect(out, contains('PORT=8080\n'));
      expect(out, isNot(contains('PORT=8080 #')));
      expect(out, contains('DB_PORT= # int'));
    });

    test('the error names the flavor inferred from the file name', () async {
      fs.file(p.join(p.separator, 'envs', 'app.local.backup.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('v: plain\n');

      final code = await run([
        'generate',
        'env',
        '--file=${p.join(p.separator, 'envs', 'app.local.backup.yaml')}',
        '--output=${p.join(p.separator, 'dist')}',
      ]);

      expect(code, 1);
      expect(allErrors(), contains('backup'));
    });
  });

  group('generate dart', () {
    void writeEnv(String name, String content) {
      fs.file(p.join(p.separator, 'envs', name))
        ..createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    test('a key that cannot be a dart identifier fails', () async {
      writeEnv('bad.local.env', '2FA_ENABLED=true\n');

      final code = await run([
        'generate',
        'dart',
        '--file=${p.join(p.separator, 'envs', 'bad.local.env')}',
        '--output=${p.join(p.separator, 'gen')}',
      ]);

      expect(code, 1);
      expect(allErrors(), contains('2FA_ENABLED'));
    });

    test('a key that is a dart keyword fails', () async {
      writeEnv('kw.local.env', 'CLASS="c"\n');

      final code = await run([
        'generate',
        'dart',
        '--file=${p.join(p.separator, 'envs', 'kw.local.env')}',
        '--output=${p.join(p.separator, 'gen')}',
      ]);

      expect(code, 1);
      expect(allErrors(), contains('keyword'));
    });

    test('two keys colliding on one field name fails', () async {
      writeEnv('dup.local.env', 'MY_KEY="a"\nMY-KEY="b"\n');

      final code = await run([
        'generate',
        'dart',
        '--file=${p.join(p.separator, 'envs', 'dup.local.env')}',
        '--output=${p.join(p.separator, 'gen')}',
      ]);

      expect(code, 1);
      expect(allErrors(), contains('myKey'));
    });

    test('refuses an output directory holding files pnv did not write',
        () async {
      writeEnv('ok.local.env', 'OK="v"\n');

      fs.file(p.join(p.separator, 'gen', 'important.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('class Important {}');

      final code = await run([
        'generate',
        'dart',
        '--file=${p.join(p.separator, 'envs', 'ok.local.env')}',
        '--output=${p.join(p.separator, 'gen')}',
      ]);

      expect(code, 1);
      expect(
        fs.file(p.join(p.separator, 'gen', 'important.dart')).existsSync(),
        isTrue,
        reason: 'hand-written source must survive',
      );
      expect(allErrors(), contains('important.dart'));
    });

    test('reuses an output directory it wrote itself', () async {
      writeEnv('ok.local.env', 'OK="v"\n');

      final first = await run([
        'generate',
        'dart',
        '--file=${p.join(p.separator, 'envs', 'ok.local.env')}',
        '--output=${p.join(p.separator, 'gen')}',
      ]);
      final second = await run([
        'generate',
        'dart',
        '--file=${p.join(p.separator, 'envs', 'ok.local.env')}',
        '--output=${p.join(p.separator, 'gen')}',
      ]);

      expect(first, 0);
      expect(second, 0, reason: 'the guard must not block pnv from re-running');
    });

    test('--directory generates every file, not just the first', () async {
      writeEnv('alpha.local.env', 'A="1"\n');
      writeEnv('beta.local.env', 'B="2"\n');

      await run([
        'generate',
        'dart',
        '--dir=${p.join(p.separator, 'envs')}',
        '--output=${p.join(p.separator, 'gen')}',
      ]);

      expect(
        fs.file(p.join(p.separator, 'gen', 'alpha.dart')).existsSync(),
        isTrue,
      );
      expect(
        fs.file(p.join(p.separator, 'gen', 'beta.dart')).existsSync(),
        isTrue,
      );
    });
  });

  group('to-dart-define', () {
    setUp(() {
      fs.file('in.env')
        ..createSync()
        ..writeAsStringSync(
          'PLAIN="hello"\n'
          'B64="aGVsbG8gd29ybGQ="\n'
          'PORT=8080 # int\n'
          '# a comment line\n'
          'SPACED="has spaces"\n',
        );
    });

    test('keeps a base64 value instead of dropping it', () async {
      await run(['to-dart-define', 'in.env']);

      expect(written.join(), contains('-DB64=aGVsbG8gd29ybGQ='));
    });

    test('does not leak a type comment into the argument', () async {
      await run(['to-dart-define', 'in.env']);

      expect(written.join(), contains('-DPORT=8080'));
      expect(written.join(), isNot(contains('#')));
    });

    test('warns that a value with whitespace will be word-split', () async {
      await run(['to-dart-define', 'in.env']);

      expect(allErrors(), contains('SPACED'));
    });

    test('--per-line emits one whole define per line and does not warn',
        () async {
      await run(['to-dart-define', '--per-line', 'in.env']);

      final lines =
          written.join().split('\n').where((e) => e.isNotEmpty).toList();

      expect(lines, contains('-DSPACED=has spaces'));
      expect(lines, contains('-DB64=aGVsbG8gd29ybGQ='));
      expect(errors, isEmpty);
    });
  });

  group('keys', () {
    test('a key shorter than the minimum is rejected', () async {
      final code = await run(['encrypt', 'x', '--key=aaaa']);

      expect(code, 1);
    });

    test('a key that is not base64 is rejected', () async {
      final code = await run(['encrypt', 'x', '--key=!!!!']);

      expect(code, 1);
    });

    test('a malformed payload is not blamed on the key', () async {
      writeConfig();

      final code = await run([
        'decrypt',
        'SECRET;not-base64!!!',
        '--flavor=local',
      ]);

      expect(code, 1);
      expect(allErrors().toLowerCase(), isNot(contains('correct key')));
    });

    test('a well-formed payload under the wrong key blames the key', () async {
      writeConfig(flavors: const {'local': [], 'other': []});
      fs.file('$home/.pnv/other.key').writeAsStringSync('ZZZZZZZZZZZZZZZZ');

      final code = await run(['decrypt', localSecret, '--flavor=other']);

      expect(code, 1);
      expect(allErrors().toLowerCase(), contains('key'));
    });

    test('the right key still decrypts', () async {
      writeConfig();

      final code = await run(['decrypt', localSecret, '--flavor=local']);

      expect(code, 0);
      expect(written.join(), contains(localPlain));
    });
  });

  group('flavors', () {
    test('deleting a flavor that does not exist fails', () async {
      writeConfig();

      final code = await run([
        'delete',
        'flavor',
        '--name=ghost',
        '--force',
      ]);

      expect(code, 1);
      expect(allErrors(), contains('ghost'));
    });

    test('deleting a real flavor removes its key and config entry', () async {
      writeConfig();

      final code = await run([
        'delete',
        'flavor',
        '--name=local',
        '--force',
      ]);

      expect(code, 0);
      expect(fs.file('$home/.pnv/local.key').existsSync(), isFalse);
      expect(fs.file('.pnvrc').readAsStringSync(), isNot(contains('local')));
    });
  });

  group('cli', () {
    test('the executable names itself pnv', () {
      final runner = PnvRunner(
        fs: fs,
        logger: logger,
        flavorHandler: FlavorHandler(fs: fs, logger: logger),
      );

      expect(runner.executableName, 'pnv');
      expect(runner.usage, contains('Usage: pnv'));
    });
  });
}

class _MockLogger extends Mock implements Logger {}

class _MockProgress extends Mock implements Progress {}
