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

  const key = 'oI0tNittVqP_nLwY';
  final yamlPath = p.join(p.separator, 'envs', 'app.local.yaml');

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

    fs.file('.pnvrc')
      ..createSync()
      ..writeAsStringSync(
        jsonEncode(
          PnvConfig(storage: '/keys', flavors: const {'local': [], 'prod': []}),
        ),
      );
    fs.file(p.join(p.separator, 'keys', 'local.key'))
      ..createSync(recursive: true)
      ..writeAsStringSync(key);
    fs.file(p.join(p.separator, 'keys', 'prod.key'))
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

  void writeYaml(String content) {
    fs.file(yamlPath)
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  String readYaml() => fs.file(yamlPath).readAsStringSync();

  String output() => written.join();
  String allErrors() => errors.join('\n');

  group('set', () {
    test('encrypts in place and leaves everything else byte for byte',
        () async {
      writeYaml('''
# a leading comment
base-url: http://localhost:3000   # trailing comment
app:
  name: demo
  api-key: replace-me
''');

      final code = await run([
        'set',
        'app.api-key',
        'sk-live-abc',
        '--file=$yamlPath',
      ]);

      final result = readYaml();

      expect(code, 0);
      expect(result, contains('# a leading comment'));
      expect(
        result,
        contains('base-url: http://localhost:3000   # trailing comment'),
      );
      expect(result, contains('name: demo'));
      expect(result, contains('api-key: SECRET1;'));
      expect(result, isNot(contains('replace-me')));
    });

    test('creates missing groups in block style', () async {
      writeYaml('app:\n  name: demo\n');

      await run(['set', 'app.db.password', 'hunter2', '--file=$yamlPath']);

      // Block style, not the `db: {password: ...}` flow map that adding one
      // empty map at a time produces.
      expect(readYaml(), contains('  db:\n    password: SECRET1;'));
    });

    test('seeds an empty document', () async {
      writeYaml('');

      final code = await run(['set', 'a.b.c', 'v', '--file=$yamlPath']);

      expect(code, 0);
      expect(readYaml(), contains('a:\n  b:\n    c: SECRET1;'));
      expect(readYaml(), endsWith('\n'));
    });

    test('--plain writes the value as given', () async {
      writeYaml('app:\n  name: demo\n');

      await run([
        'set',
        'app.region',
        'us-east-1',
        '--file=$yamlPath',
        '--plain',
      ]);

      expect(readYaml(), contains('region: us-east-1'));
      expect(readYaml(), isNot(contains('SECRET')));
    });

    test('refuses a path that runs through a scalar', () async {
      writeYaml('app:\n  name: demo\n');

      final code = await run(['set', 'app.name.oops', 'v', '--file=$yamlPath']);

      expect(code, 1);
      expect(allErrors(), contains('is a value, not a group'));
      expect(readYaml(), 'app:\n  name: demo\n', reason: 'must not be touched');
    });

    test('requires a value', () async {
      writeYaml('a: b\n');

      final code = await run(['set', 'a', '--file=$yamlPath']);

      expect(code, 1);
      expect(allErrors(), contains('Missing the value'));
    });

    test('rejects an empty path segment', () async {
      writeYaml('a: b\n');

      final code = await run(['set', 'app..key', 'v', '--file=$yamlPath']);

      expect(code, 1);
      expect(allErrors(), contains('Invalid key path'));
    });
  });

  group('get', () {
    test('round-trips a value set by set', () async {
      writeYaml('app:\n  name: demo\n');

      await run(['set', 'app.api-key', 'sk-live-abc', '--file=$yamlPath']);
      final code = await run(['get', 'app.api-key', '--file=$yamlPath']);

      expect(code, 0);
      expect(output(), contains('sk-live-abc'));
    });

    test('reads a plain value back unchanged', () async {
      writeYaml('base-url: http://localhost:3000\n');

      await run(['get', 'base-url', '--file=$yamlPath']);

      expect(output(), contains('http://localhost:3000'));
    });

    test('fails on a key that is not there', () async {
      writeYaml('app:\n  name: demo\n');

      final code = await run(['get', 'app.nope', '--file=$yamlPath']);

      expect(code, 1);
      expect(allErrors(), contains('No such key'));
    });

    test('fails when the path names a group', () async {
      writeYaml('app:\n  name: demo\n');

      final code = await run(['get', 'app', '--file=$yamlPath']);

      expect(code, 1);
      expect(allErrors(), contains('is a group, not a value'));
    });

    test('names the wrong key when a secret came from another flavor',
        () async {
      writeYaml('app:\n  name: demo\n');

      // Encrypt under prod, then read it from a file whose name says local.
      await run([
        'set',
        'app.api-key',
        'from-prod',
        '--file=$yamlPath',
        '--flavor=prod',
      ]);

      final code = await run(['get', 'app.api-key', '--file=$yamlPath']);

      expect(code, 1);
      expect(
        allErrors(),
        contains('encrypted with a different key'),
        reason: 'the key id makes a cross-flavor paste identifiable',
      );
    });
  });
}

class _MockLogger extends Mock implements Logger {}
