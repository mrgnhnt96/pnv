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

  /// A realistic layout: a project with a pubspec, and keys outside it.
  final project = p.join(p.separator, 'project');
  final envs = p.join(project, 'envs');
  final yamlPath = p.join(envs, 'app.local.yaml');
  final keys = p.join(p.separator, 'keys');

  setUp(() {
    fs = MemoryFileSystem.test();
    logger = _MockLogger();
    errors = [];

    when(() => logger.err(any())).thenAnswer((i) {
      errors.add('${i.positionalArguments.first}');
    });
    when(() => logger.write(any())).thenAnswer((_) {});

    fs.directory(project).createSync(recursive: true);
    fs.currentDirectory = project;

    fs.file(p.join(project, 'pubspec.yaml'))
      ..createSync()
      ..writeAsStringSync('name: demo\n');
    fs.file(p.join(project, '.pnvrc'))
      ..createSync()
      ..writeAsStringSync(
        jsonEncode(
          PnvConfig(
            storage: keys,
            flavors: const {'local': [], 'other': []},
          ),
        ),
      );
    fs.file(p.join(keys, 'local.key'))
      ..createSync(recursive: true)
      ..writeAsStringSync('oI0tNittVqP_nLwY');
    fs.file(p.join(keys, 'other.key'))
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

  void writeYaml(String content, {String? path}) {
    fs.file(path ?? yamlPath)
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  String allErrors() => errors.join('\n');

  test('passes a file whose secrets all decrypt', () async {
    writeYaml('app:\n  api-key: replace\n');
    await run(['set', 'app.api-key', 'a-real-secret', '--file=$yamlPath']);

    final code = await run(['verify', '--dir=$envs']);

    expect(code, 0);
    expect(allErrors(), isEmpty);
  });

  test('fails on a plaintext value that looks like a credential', () async {
    writeYaml('app:\n  api-key: sk-live-1234567890abcdefghij\n');

    final code = await run(['verify', '--dir=$envs']);

    expect(code, 1);
    expect(allErrors(), contains('app.api-key'));
    expect(allErrors(), contains('API key'));
  });

  test('a "# plaintext" comment settles it', () async {
    writeYaml(
      'app:\n  api-key: sk-live-1234567890abcdefghij # plaintext, a demo key\n',
    );

    final code = await run(['verify', '--dir=$envs']);

    expect(code, 0);
  });

  test('fails on a secret encrypted under another flavor', () async {
    writeYaml('app:\n  api-key: replace\n');
    await run([
      'set',
      'app.api-key',
      'from-elsewhere',
      '--file=$yamlPath',
      '--flavor=other',
    ]);

    final code = await run(['verify', '--dir=$envs']);

    expect(code, 1);
    expect(allErrors(), contains('encrypted with a different key'));
  });

  test('fails on a corrupt token, without blaming the key', () async {
    writeYaml('app:\n  api-key: SECRET;v1:GARBAGE\n');

    final code = await run(['verify', '--dir=$envs']);

    expect(code, 1);
    expect(allErrors(), contains('Malformed secret'));
  });

  test('fails when key storage is inside the project', () async {
    fs.file(p.join(project, '.pnvrc')).writeAsStringSync(
          jsonEncode(
            PnvConfig(
              storage: p.join(project, 'keys'),
              flavors: const {'local': []},
            ),
          ),
        );
    writeYaml('app:\n  name: demo\n');

    final code = await run(['verify', '--dir=$envs']);

    expect(code, 1);
    expect(allErrors(), contains('inside the project'));
  });

  test('a plain config file needs no key at all', () async {
    writeYaml('base-url: http://localhost:3000\nport: 8080\n');
    fs.file(p.join(keys, 'local.key')).deleteSync();

    final code = await run(['verify', '--dir=$envs']);

    expect(code, 0, reason: 'nothing to decrypt, so nothing to unlock');
  });

  test('reports the missing key when a file does have secrets', () async {
    writeYaml('app:\n  api-key: replace\n');
    await run(['set', 'app.api-key', 'x', '--file=$yamlPath']);
    fs.file(p.join(keys, 'local.key')).deleteSync();

    final code = await run(['verify', '--dir=$envs']);

    expect(code, 1);
    expect(allErrors(), contains('local'));
  });

  test('checks every file under the directory', () async {
    writeYaml('a:\n  b: ok\n', path: p.join(envs, 'one.local.yaml'));
    writeYaml(
      'app:\n  password: realsecretvalue\n',
      path: p.join(envs, 'nested', 'two.local.yaml'),
    );

    final code = await run(['verify', '--dir=$envs']);

    expect(code, 1);
    expect(allErrors(), contains('two.local.yaml'));
  });
}

class _MockLogger extends Mock implements Logger {}
