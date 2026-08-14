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

  final project = p.join(p.separator, 'project');
  final keys = p.join(p.separator, 'keys');
  final envPath = p.join(project, 'legacy.env');
  final yamlPath = p.join(project, 'envs', 'app.local.yaml');

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
    when(() => logger.info(any())).thenAnswer((_) {});

    fs.directory(project).createSync(recursive: true);
    fs.currentDirectory = project;
    fs.file(p.join(project, 'pubspec.yaml'))
      ..createSync()
      ..writeAsStringSync('name: demo\n');
    fs.file(p.join(project, '.pnvrc'))
      ..createSync()
      ..writeAsStringSync(
        jsonEncode(
          PnvConfig(storage: keys, flavors: const {'local': []}),
        ),
      );
    fs.file(p.join(keys, 'local.key'))
      ..createSync(recursive: true)
      ..writeAsStringSync('oI0tNittVqP_nLwY');
  });

  Future<int> run(List<String> args) {
    return PnvRunner(
      fs: fs,
      logger: logger,
      flavorHandler: FlavorHandler(fs: fs, logger: logger),
    ).run(args);
  }

  void writeEnv(String content) {
    fs.file(envPath)
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  String readYaml() => fs.file(yamlPath).readAsStringSync();
  String output() => written.join();
  String allErrors() => errors.join('\n');

  group('import', () {
    test('encrypts every value by default', () async {
      writeEnv('APP_NAME=demo\nAPP_KEY=sk-live-1234567890abcdefghij\n');

      final code = await run(['import', envPath, '--output=$yamlPath']);

      expect(code, 0);
      expect(readYaml(), contains('app_name: SECRET;v1:'));
      expect(readYaml(), contains('app_key: SECRET;v1:'));
    });

    test('keys stay flat so they regenerate identically', () async {
      writeEnv('APP_RUN_TIME_TOKEN="a token with spaces"\n');

      await run(['import', envPath, '--output=$yamlPath']);
      await run([
        'generate',
        'env',
        '--file=$yamlPath',
        '--output=${p.join(project, 'dist')}',
      ]);

      final regenerated =
          fs.file(p.join(project, 'dist', 'app.local.env')).readAsStringSync();

      // Un-flattening APP_RUN_TIME_TOKEN is guesswork -- run-time or run_time?
      // -- and guessing wrong renames the variable the build depends on.
      expect(regenerated, contains('APP_RUN_TIME_TOKEN="a token with spaces"'));
    });

    test('a value containing = survives', () async {
      writeEnv('B64="aGVsbG8gd29ybGQ="\n');

      await run(['import', envPath, '--output=$yamlPath']);
      await run(['show', yamlPath]);

      expect(output(), contains('aGVsbG8gd29ybGQ='));
    });

    test('--only-secrets leaves plain config readable', () async {
      writeEnv(
        'APP_NAME=demo\n'
        'APP_KEY=sk-live-1234567890abcdefghij\n'
        'APP_PASSWORD=realsecretvalue\n',
      );

      await run(['import', envPath, '--output=$yamlPath', '--only-secrets']);

      final yaml = readYaml();

      expect(yaml, contains('app_name: demo'));
      expect(yaml, contains('app_key: SECRET;v1:'));
      expect(yaml, contains('app_password: SECRET;v1:'));
    });

    test('skips comments and blank lines', () async {
      writeEnv('# a comment\n\nA=1\n');

      await run(['import', envPath, '--output=$yamlPath']);

      expect(readYaml(), isNot(contains('#')));
      expect(readYaml(), contains('a: SECRET;v1:'));
    });

    test('refuses to overwrite without --force', () async {
      writeEnv('A=1\n');
      await run(['import', envPath, '--output=$yamlPath']);

      final code = await run(['import', envPath, '--output=$yamlPath']);

      expect(code, 1);
      expect(allErrors(), contains('already exists'));
    });

    test('--force overwrites', () async {
      writeEnv('A=1\n');
      await run(['import', envPath, '--output=$yamlPath']);

      final code =
          await run(['import', envPath, '--output=$yamlPath', '--force']);

      expect(code, 0);
    });

    test('fails on an empty .env', () async {
      writeEnv('# nothing but a comment\n');

      final code = await run(['import', envPath, '--output=$yamlPath']);

      expect(code, 1);
      expect(allErrors(), contains('No environment variables'));
    });

    test('fails when the input does not exist', () async {
      final code = await run(['import', 'nope.env', '--output=$yamlPath']);

      expect(code, 1);
      expect(allErrors(), contains('does not exist'));
    });
  });

  group('show', () {
    test('prints the file with secrets decrypted', () async {
      writeEnv('APP_KEY=the-secret\n');
      await run(['import', envPath, '--output=$yamlPath']);

      final code = await run(['show', yamlPath]);

      expect(code, 0);
      expect(output(), contains('app_key: the-secret'));
      expect(output(), isNot(contains('SECRET;v1:')));
    });

    test('accepts the path positionally, as a textconv driver passes it',
        () async {
      writeEnv('APP_KEY=the-secret\n');
      await run(['import', envPath, '--output=$yamlPath']);

      await run(['show', yamlPath]);

      expect(output(), contains('the-secret'));
    });

    test('passes through a file with no secrets', () async {
      final plain = p.join(project, 'plain.yaml');
      fs.file(plain)
        ..createSync()
        ..writeAsStringSync('a: 1\nb: two\n');

      final code = await run(['show', plain]);

      expect(code, 0);
      expect(output(), 'a: 1\nb: two\n');
    });

    test('leaves comments and structure alone', () async {
      fs.file(yamlPath)
        ..createSync(recursive: true)
        ..writeAsStringSync('# a comment\napp:\n  key: replace\n');
      await run(['set', 'app.key', 'v', '--file=$yamlPath']);
      written.clear();

      await run(['show', yamlPath]);

      expect(output(), contains('# a comment'));
      expect(output(), contains('  key: v'));
    });

    test('fails on a missing file', () async {
      final code = await run(['show', 'nope.yaml']);

      expect(code, 1);
      expect(allErrors(), contains('does not exist'));
    });
  });
}

class _MockLogger extends Mock implements Logger {}
