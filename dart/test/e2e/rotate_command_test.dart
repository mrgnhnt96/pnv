import 'dart:convert';

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:pnv/src/handlers/flavor_handler.dart';
import 'package:pnv/src/models/pnv_config.dart';
import 'package:pnv/src/pnv_runner.dart';
import 'package:test/test.dart';

void main() {
  late Logger logger;
  late FileSystem fs;
  late List<String> errors;
  late List<String> written;

  final yamlPath = p.join(p.separator, 'envs', 'app.local.yaml');
  final keyPath = p.join(p.separator, 'keys', 'local.key');

  setUp(() {
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

    fs.file('.pnvrc')
      ..createSync()
      ..writeAsStringSync(
        jsonEncode(
          PnvConfig(
            storage: p.join(p.separator, 'keys'),
            flavors: const {'local': [], 'next': []},
          ),
        ),
      );
    fs.file(keyPath)
      ..createSync(recursive: true)
      ..writeAsStringSync('oI0tNittVqP_nLwY');
    fs.file(p.join(p.separator, 'keys', 'next.key'))
      ..createSync(recursive: true)
      ..writeAsStringSync('ZZZZZZZZZZZZZZZZ');
  });

  Future<int> run(List<String> args) {
    return PnvRunner(
      fs: fs,
      logger: logger,
      flavorHandler: FlavorHandler(fs: fs, logger: logger),
    ).run(args);
  }

  void writeYaml(String path, String content) {
    fs.file(path)
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  String allErrors() => errors.join('\n');

  /// A file with two secrets under `local`, plus a comment and plain config.
  Future<void> seed([String path = '']) async {
    final target = path.isEmpty ? yamlPath : path;

    writeYaml(target, '''
# local env
base-url: http://localhost:3000
app:
  api-key: replace
  db:
    password: replace
''');

    await run(['set', 'app.api-key', 'key-one', '--file=$target']);
    await run(['set', 'app.db.password', 'pw-one', '--file=$target']);
  }

  group('rotate', () {
    test('re-encrypts under the destination flavor', () async {
      await seed();
      final before = fs.file(yamlPath).readAsStringSync();

      final code = await run([
        'rotate',
        '--file=$yamlPath',
        '--from=local',
        '--to=next',
      ]);

      final after = fs.file(yamlPath).readAsStringSync();

      expect(code, 0);
      expect(after, isNot(before), reason: 'tokens must change');
      expect(after, contains('# local env'), reason: 'comments survive');
      expect(after, contains('base-url: http://localhost:3000'));

      written.clear();
      await run(['get', 'app.api-key', '--file=$yamlPath', '--flavor=next']);
      expect(written.join(), contains('key-one'));
    });

    test('the old key no longer opens the rotated file', () async {
      await seed();
      await run(['rotate', '--file=$yamlPath', '--from=local', '--to=next']);

      final code = await run(['get', 'app.api-key', '--file=$yamlPath']);

      expect(code, 1);
      expect(allErrors(), contains('encrypted with a different key'));
    });

    test('--dry-run writes nothing', () async {
      await seed();
      final before = fs.file(yamlPath).readAsStringSync();

      final code = await run([
        'rotate',
        '--file=$yamlPath',
        '--from=local',
        '--to=next',
        '--dry-run',
      ]);

      expect(code, 0);
      expect(fs.file(yamlPath).readAsStringSync(), before);
    });

    test('--new-key replaces the key and keeps the old one alongside',
        () async {
      await seed();
      final originalKey = fs.file(keyPath).readAsStringSync();

      final code = await run([
        'rotate',
        '--file=$yamlPath',
        '--from=local',
        '--new-key',
      ]);

      expect(code, 0);
      expect(fs.file(keyPath).readAsStringSync(), isNot(originalKey));
      expect(fs.file('$keyPath.previous').readAsStringSync(), originalKey);

      written.clear();
      await run(['get', 'app.api-key', '--file=$yamlPath']);
      expect(written.join(), contains('key-one'));
    });

    test('one unreadable file leaves the whole batch untouched', () async {
      final good = p.join(p.separator, 'batch', 'good.local.yaml');
      final bad = p.join(p.separator, 'batch', 'zbad.local.yaml');

      await seed(good);
      writeYaml(bad, 'v: SECRET;v1:GARBAGE\n');

      final before = fs.file(good).readAsStringSync();

      final code = await run([
        'rotate',
        '--dir=${p.join(p.separator, 'batch')}',
        '--from=local',
        '--to=next',
      ]);

      expect(code, 1);
      expect(
        fs.file(good).readAsStringSync(),
        before,
        reason: 'a half-rotated batch is unrecoverable, so write nothing',
      );
    });

    test('needs a destination', () async {
      await seed();

      final code = await run(['rotate', '--file=$yamlPath', '--from=local']);

      expect(code, 1);
      expect(allErrors(), contains('Name a destination'));
    });

    test('refuses both destinations at once', () async {
      await seed();

      final code = await run([
        'rotate',
        '--file=$yamlPath',
        '--from=local',
        '--to=next',
        '--new-key',
      ]);

      expect(code, 1);
      expect(allErrors(), contains('not both'));
    });

    test('--new-key needs --from', () async {
      await seed();

      final code = await run(['rotate', '--file=$yamlPath', '--new-key']);

      expect(code, 1);
      expect(allErrors(), contains('needs --from'));
    });

    test('needs something to rotate', () async {
      final code = await run(['rotate', '--to=next']);

      expect(code, 1);
      expect(allErrors(), contains('Nothing to rotate'));
    });
  });
}

class _MockLogger extends Mock implements Logger {}

class _MockProgress extends Mock implements Progress {}
