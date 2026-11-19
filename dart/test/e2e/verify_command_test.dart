import 'dart:convert';
import 'dart:io' as io;

import 'package:file/file.dart';
import 'package:file/local.dart';
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

  group('a multi-document file', () {
    test('passes when every document is clean', () async {
      writeYaml(
        'name: captcha_remediation\ndecisions:\n  - type: captcha\n'
        '---\n'
        'name: default_ip_remediation\non_success: break\n',
      );

      final code = await run(['verify', '--dir=$envs']);

      expect(code, 0, reason: allErrors());
      expect(allErrors(), isEmpty);
    });

    test('checks documents after the first', () async {
      writeYaml(
        'name: first\n'
        '---\n'
        'db:\n  password: hunter2hunter2\n',
      );

      final code = await run(['verify', '--dir=$envs']);

      expect(code, 1);
      expect(allErrors(), contains('db.password'));
    });

    test('decrypts secrets in every document', () async {
      writeYaml('app:\n  api-key: replace\n');
      await run(['set', 'app.api-key', 'a-real-secret', '--file=$yamlPath']);
      final first = fs.file(yamlPath).readAsStringSync();
      writeYaml('$first---\nother:\n  api-key: SECRET;v1:GARBAGE\n');

      final code = await run(['verify', '--dir=$envs']);

      expect(code, 1);
      expect(allErrors(), contains('other.api-key'));
      expect(allErrors(), isNot(contains('app.api-key')));
    });
  });

  test('reports invalid YAML and checks the other files', () async {
    writeYaml('a: [unclosed\n', path: p.join(envs, 'broken.local.yaml'));
    writeYaml(
      'app:\n  password: realsecretvalue\n',
      path: p.join(envs, 'leak.local.yaml'),
    );

    final code = await run(['verify', '--dir=$envs']);

    expect(code, 1);
    expect(allErrors(), contains('broken.local.yaml: not valid YAML'));
    expect(allErrors(), contains('leak.local.yaml'));
  });

  group('in a git repo', () {
    late io.Directory repo;

    setUp(() {
      repo = io.Directory.systemTemp.createTempSync('pnv_verify_git_');
      addTearDown(() => repo.deleteSync(recursive: true));

      final init = io.Process.runSync(
        'git',
        ['init', '--quiet'],
        workingDirectory: repo.path,
      );
      expect(init.exitCode, 0, reason: '${init.stderr}');

      fs = const LocalFileSystem();
      final cwd = fs.currentDirectory;
      addTearDown(() => fs.currentDirectory = cwd);
      fs.currentDirectory = repo.path;

      void write(String path, String content) {
        fs.file(p.join(repo.path, path))
          ..createSync(recursive: true)
          ..writeAsStringSync(content);
      }

      write('.gitignore', 'ignored/\n');
      write('envs/app.yaml', 'name: demo\n');
      write(
        'ignored/copy/envs/app.yaml',
        'db:\n  password: hunter2hunter2\n',
      );
    });

    test('skips gitignored files', () async {
      final code = await run(['verify', '--dir=${repo.path}']);

      expect(code, 0, reason: allErrors());
    });

    test('checks untracked files git would track', () async {
      fs
          .file(p.join(repo.path, 'envs', 'new.yaml'))
          .writeAsStringSync('db:\n  password: hunter2hunter2\n');

      final code = await run(['verify', '--dir=${repo.path}']);

      expect(code, 1);
      expect(allErrors(), contains('new.yaml'));
      expect(allErrors(), isNot(contains('ignored')));
    });

    test('only looks under the directory it was given', () async {
      fs.file(p.join(repo.path, 'other', 'leak.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('db:\n  password: hunter2hunter2\n');

      final code = await run(['verify', '--dir=${p.join(repo.path, 'envs')}']);

      expect(code, 0, reason: allErrors());
    });
  });
}

class _MockLogger extends Mock implements Logger {}
