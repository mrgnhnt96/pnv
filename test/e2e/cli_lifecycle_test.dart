@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The real thing: a real project on the real file system, driven by the real
/// executable in a real process.
///
/// Every other test runs in memory against `PnvRunner`, which cannot see
/// process exit codes, the split between stdout and stderr, or file
/// permissions — and those are exactly what the shell scripts consuming pnv
/// depend on. This suite is slower on purpose.
///
/// Run it with `dart test -t e2e`, or as part of `dart test`.
void main() {
  late Directory root;
  late Directory project;
  late Directory keys;

  /// Compiled once, so each invocation is a process start rather than a
  /// fresh compile. AOT is not an option: mason_logger's win32 import fails
  /// to compile on macOS.
  late String snapshot;

  setUpAll(() {
    final repo = Directory.current.path;
    final out = Directory.systemTemp.createTempSync('pnv-e2e-snapshot');
    snapshot = p.join(out.path, 'pnv.dill');

    final result = Process.runSync(
      Platform.resolvedExecutable,
      ['compile', 'kernel', p.join(repo, 'bin', 'pnv.dart'), '-o', snapshot],
      workingDirectory: repo,
    );

    expect(
      result.exitCode,
      0,
      reason: 'could not build the CLI snapshot:\n${result.stderr}',
    );
  });

  setUp(() {
    root = Directory.systemTemp.createTempSync('pnv-e2e');
    project = Directory(p.join(root.path, 'project'))..createSync();
    keys = Directory(p.join(root.path, 'keys'));

    File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync(
      'name: demo_app\nenvironment:\n  sdk: ">=3.2.6 <4.0.0"\n',
    );
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// Runs pnv exactly as a shell script would, and returns what a script sees.
  ({int exitCode, String stdout, String stderr}) pnv(
    List<String> args, {
    String? workingDirectory,
  }) {
    final result = Process.runSync(
      Platform.resolvedExecutable,
      [snapshot, ...args],
      workingDirectory: workingDirectory ?? project.path,
    );

    return (
      exitCode: result.exitCode,
      stdout: '${result.stdout}',
      stderr: '${result.stderr}',
    );
  }

  /// What a shell script gets from `$(pnv ... | tail -1)`.
  String lastLine(String stdout) {
    final lines = stdout.split('\n').where((e) => e.trim().isNotEmpty);
    return lines.isEmpty ? '' : lines.last;
  }

  void initProject() {
    final result = pnv([
      'init',
      '--storage=${keys.path}',
      '--flavor=dev',
      '--flavor=prod',
      '--yes',
      '--gitignore',
    ]);

    expect(result.exitCode, 0, reason: result.stderr);
  }

  String yaml(String name) => p.join(project.path, 'env_files', name);

  group('the whole lifecycle', () {
    test('init, set, verify, generate, build', () {
      // 1. Set up, with no terminal attached anywhere in this suite.
      initProject();

      expect(File(p.join(keys.path, 'dev.key')).existsSync(), isTrue);
      expect(File(p.join(keys.path, 'prod.key')).existsSync(), isTrue);
      expect(
        File(p.join(project.path, '.gitignore')).readAsStringSync(),
        contains('*.key'),
      );

      // 2. A secrets file with plain config beside the secrets.
      File(yaml('app.dev.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
# the dev environment
base-url: http://localhost:8080
app:
  name: demo
  port: 8080
''');

      expect(
        pnv([
          'set',
          'app.api-key',
          'sk-dev-value',
          '--file=${yaml('app.dev.yaml')}',
        ]).exitCode,
        0,
      );
      expect(
        pnv([
          'set',
          'app.db.password',
          'hunter2',
          '--file=${yaml('app.dev.yaml')}',
        ]).exitCode,
        0,
      );

      final content = File(yaml('app.dev.yaml')).readAsStringSync();
      expect(content, contains('# the dev environment'), reason: 'comments');
      expect(content, contains('base-url: http://localhost:8080'));
      expect(content, contains('  db:\n    password: SECRET;'));

      // 3. Safe to publish.
      final verified = pnv(['verify']);
      expect(verified.exitCode, 0, reason: verified.stderr);

      // 4. Down to .env.
      expect(
        pnv([
          'generate',
          'env',
          '--file=${yaml('app.dev.yaml')}',
          '--output=dist',
        ]).exitCode,
        0,
      );

      final env =
          File(p.join(project.path, 'dist', 'app.dev.env')).readAsStringSync();
      expect(env, contains('APP_API_KEY="sk-dev-value"'));
      expect(env, contains('APP_DB_PASSWORD="hunter2"'));
      expect(env, contains('APP_PORT=8080'));

      // 5. Down to Dart.
      expect(
        pnv([
          'generate',
          'dart',
          '--file=${p.join(project.path, 'dist', 'app.dev.env')}',
          '--output=${p.join(project.path, 'lib', 'envs')}',
        ]).exitCode,
        0,
      );

      final dart = File(p.join(project.path, 'lib', 'envs', 'app.dart'))
          .readAsStringSync();
      expect(dart, contains('class App {'));
      expect(dart, contains("String.fromEnvironment('APP_API_KEY')"));
      expect(dart, contains("int.fromEnvironment('APP_PORT')"));

      // 6. Out to the build.
      final defines = pnv([
        'to-dart-define',
        '--per-line',
        p.join(project.path, 'dist', 'app.dev.env'),
      ]);
      expect(defines.exitCode, 0);
      expect(defines.stdout, contains('-DAPP_API_KEY=sk-dev-value'));
    });

    test(
      'key files land readable only by their owner',
      () {
        initProject();

        final mode = File(p.join(keys.path, 'dev.key')).statSync().mode;

        // Low nine bits: owner/group/other. 0600 = 384.
        expect(
          mode & 0x1FF,
          0x180,
          reason: 'a key file is the secret; nobody else may read it',
        );
      },
      testOn: '!windows',
    );

    test('rotate moves a real file to a fresh key on disk', () {
      initProject();

      File(yaml('app.dev.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('app:\n  api-key: replace\n');
      pnv([
        'set',
        'app.api-key',
        'before-rotation',
        '--file=${yaml('app.dev.yaml')}',
      ]);

      final originalKey = File(p.join(keys.path, 'dev.key')).readAsStringSync();

      final result = pnv([
        'rotate',
        '--directory=${p.join(project.path, 'env_files')}',
        '--from=dev',
        '--new-key',
      ]);

      expect(result.exitCode, 0, reason: result.stderr);
      expect(
        File(p.join(keys.path, 'dev.key')).readAsStringSync(),
        isNot(originalKey),
      );
      expect(
        File(p.join(keys.path, 'dev.key.previous')).readAsStringSync(),
        originalKey,
      );

      final read =
          pnv(['get', 'app.api-key', '--file=${yaml('app.dev.yaml')}']);
      expect(lastLine(read.stdout), 'before-rotation');
    });

    test(
      'the retained previous key is not world readable',
      () {
        initProject();
        File(yaml('app.dev.yaml'))
          ..createSync(recursive: true)
          ..writeAsStringSync('app:\n  api-key: replace\n');
        pnv(['set', 'app.api-key', 'v', '--file=${yaml('app.dev.yaml')}']);

        pnv([
          'rotate',
          '--directory=${p.join(project.path, 'env_files')}',
          '--from=dev',
          '--new-key',
        ]);

        final mode =
            File(p.join(keys.path, 'dev.key.previous')).statSync().mode & 0x1FF;

        // It still opens every secret written before the rotation, so it is
        // exactly as sensitive as the key it replaced.
        expect(mode, 0x180);
      },
      testOn: '!windows',
    );
  });

  group('the contract shell scripts depend on', () {
    // Modelled on a real consumer, which globs `SECRET;*` to decide whether a
    // value needs decrypting, greps `^\s*api_key:\s*SECRET;` to find blobs in
    // a YAML file, and reads values out of `$(pnv decrypt ... | tail -1)`.
    setUp(initProject);

    test('encrypt writes a SECRET; blob to stdout', () {
      final key = lastLine(pnv(['create', 'key']).stdout);
      final result = pnv(['encrypt', 'a-value', '--key=$key']);

      expect(result.exitCode, 0);

      final blob = lastLine(result.stdout);

      expect(
        blob,
        startsWith('SECRET;'),
        reason:
            'consumers glob SECRET;* — a version marker must not precede it',
      );
      // The same shape as the consumer's
      // grep -E '^[[:space:]]*api_key:[[:space:]]*SECRET;'
      final inYamlLine = RegExp(r'^\s*api_key:\s*SECRET;');

      expect(
        inYamlLine.hasMatch('  api_key: $blob'),
        isTrue,
        reason: 'consumers grep for the blob inside a YAML line',
      );
    });

    test('decrypt puts the plaintext on the last line of stdout', () {
      final key = lastLine(pnv(['create', 'key']).stdout);
      final blob = lastLine(pnv(['encrypt', 'the value', '--key=$key']).stdout);

      final result = pnv(['decrypt', blob, '--key=$key']);

      expect(result.exitCode, 0);
      expect(lastLine(result.stdout), 'the value');
    });

    test('errors go to stderr, keeping stdout parseable', () {
      final result = pnv(['decrypt', 'SECRET;GARBAGE', '--flavor=dev']);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, isNotEmpty);
      expect(
        lastLine(result.stdout),
        isEmpty,
        reason: 'a shell reading the last line must not get an error message',
      );
    });

    test('a secret written by an older pnv still decrypts', () {
      // A real v0 token and its key, captured before the format was versioned.
      const legacyKey = 'oI0tNittVqP_nLwY';
      const legacyBlob =
          'SECRET;lyho8D18bGu/BzQgpoCb3KhTEJk/1jPC+Jpa+Kk5E1dD2R3/77TZJeREe5c'
          'oaPA9fGxrvwc0IKaAm9w=';

      final result = pnv(['decrypt', legacyBlob, '--key=$legacyKey']);

      expect(result.exitCode, 0, reason: result.stderr);
      expect(lastLine(result.stdout), 'legend-of-zelda');
    });

    test('a v0 and a v1 secret can sit in the same file', () {
      const legacyKey = 'oI0tNittVqP_nLwY';
      const legacyBlob =
          'SECRET;lyho8D18bGu/BzQgpoCb3KhTEJk/1jPC+Jpa+Kk5E1dD2R3/77TZJeREe5c'
          'oaPA9fGxrvwc0IKaAm9w=';

      // Adopt the legacy key as the dev flavor so both values share it.
      File(p.join(keys.path, 'dev.key')).writeAsStringSync(legacyKey);

      File(yaml('app.dev.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('old: $legacyBlob\n');

      pnv(['set', 'fresh', 'a-new-value', '--file=${yaml('app.dev.yaml')}']);

      final shown = pnv(['show', yaml('app.dev.yaml')]);

      expect(shown.exitCode, 0, reason: shown.stderr);
      expect(shown.stdout, contains('old: legend-of-zelda'));
      expect(shown.stdout, contains('fresh: a-new-value'));
    });

    test('exit codes are usable in a script', () {
      expect(pnv(['verify']).exitCode, 0);
      final missingFile =
          pnv(['get', 'nope', '--file=${yaml('missing.dev.yaml')}']);
      final unknownFlavor =
          pnv(['generate', 'env', '--dir=env_files', '--flavor=typo']);

      expect(missingFile.exitCode, 1);
      expect(unknownFlavor.exitCode, 1);
    });
  });

  group('verify as a pre-commit gate', () {
    setUp(initProject);

    test('fails on a plaintext credential and names it', () {
      File(yaml('app.dev.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('app:\n  api-key: sk-live-1234567890abcdefghij\n');

      final result = pnv(['verify']);

      expect(result.exitCode, 1);
      expect(result.stderr, contains('app.api-key'));
    });

    test('passes once the value is encrypted', () {
      File(yaml('app.dev.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('app:\n  api-key: sk-live-1234567890abcdefghij\n');

      expect(pnv(['verify']).exitCode, 1);

      pnv([
        'set',
        'app.api-key',
        'sk-live-1234567890abcdefghij',
        '--file=${yaml('app.dev.yaml')}',
      ]);

      final result = pnv(['verify']);
      expect(result.exitCode, 0, reason: result.stderr);
    });

    test('catches a secret pasted in from another flavor', () {
      File(yaml('app.dev.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('app:\n  api-key: replace\n');

      pnv([
        'set',
        'app.api-key',
        'a-prod-secret',
        '--file=${yaml('app.dev.yaml')}',
        '--flavor=prod',
      ]);

      final result = pnv(['verify']);

      expect(result.exitCode, 1);
      expect(result.stderr, contains('different key'));
    });
  });

  group('adopting pnv from an existing .env', () {
    setUp(initProject);

    test('import round-trips back to the same .env', () {
      const original = 'APP_NAME=demo\n'
          'APP_RUN_TIME_TOKEN="a token with spaces"\n'
          'B64_VALUE="aGVsbG8gd29ybGQ="\n';

      File(p.join(project.path, '.env')).writeAsStringSync(original);

      expect(
        pnv([
          'import',
          '.env',
          '--output=${yaml('app.dev.yaml')}',
        ]).exitCode,
        0,
      );

      expect(
        pnv([
          'generate',
          'env',
          '--file=${yaml('app.dev.yaml')}',
          '--output=dist',
        ]).exitCode,
        0,
      );

      final regenerated =
          File(p.join(project.path, 'dist', 'app.dev.env')).readAsStringSync();

      // Values are quoted on the way out, so compare parsed pairs rather than
      // the raw text.
      Map<String, String> parse(String text) => {
            for (final line in LineSplitter.split(text))
              if (line.contains('='))
                line.substring(0, line.indexOf('=')):
                    line.substring(line.indexOf('=') + 1).replaceAll('"', ''),
          };

      expect(parse(regenerated), parse(original));
    });
  });
}
