import 'dart:convert';

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:pnv/src/handlers/flavor_handler.dart';
import 'package:pnv/src/pnv_runner.dart';
import 'package:test/test.dart';

/// init used to prompt unconditionally, which throws on a host with no
/// terminal — so it was the one command that could not be scripted. Every test
/// here would hang or throw if a prompt were reachable.
void main() {
  late Logger logger;
  late FileSystem fs;
  late List<String> warnings;

  final project = p.join(p.separator, 'project');
  final keys = p.join(p.separator, 'keys');

  setUp(() {
    fs = MemoryFileSystem.test();
    logger = _MockLogger();
    warnings = [];

    when(() => logger.err(any())).thenAnswer((_) {});
    when(() => logger.warn(any())).thenAnswer((i) {
      warnings.add('${i.positionalArguments.first}');
    });
    when(() => logger.progress(any())).thenReturn(_MockProgress());

    // Any prompt reaching a real terminal-less host throws. Make that loud
    // here instead of silently answering.
    when(() => logger.prompt(any(), defaultValue: any(named: 'defaultValue')))
        .thenThrow(StateError('prompted while running non-interactively'));
    when(() => logger.confirm(any(), defaultValue: any(named: 'defaultValue')))
        .thenThrow(StateError('prompted while running non-interactively'));

    fs.directory(project).createSync(recursive: true);
    fs.currentDirectory = project;
    fs.file(p.join(project, 'pubspec.yaml'))
      ..createSync()
      ..writeAsStringSync('name: demo_app\n');
  });

  Future<int> run(List<String> args) {
    return PnvRunner(
      fs: fs,
      logger: logger,
      flavorHandler: FlavorHandler(fs: fs, logger: logger),
    ).run(args);
  }

  Map<String, dynamic> readConfig() {
    return jsonDecode(fs.file(p.join(project, '.pnvrc')).readAsStringSync())
        as Map<String, dynamic>;
  }

  test('creates config, flavors and keys without prompting', () async {
    final code = await run([
      'init',
      '--storage=$keys',
      '--flavor=local',
      '--flavor=production',
      '--yes',
    ]);

    expect(code, 0);

    final config = readConfig();
    expect(config['storage'], keys);
    expect(
      (config['flavors'] as Map<String, dynamic>).keys,
      containsAll(<String>['local', 'production']),
    );
    expect(fs.file(p.join(keys, 'local.key')).existsSync(), isTrue);
    expect(fs.file(p.join(keys, 'production.key')).existsSync(), isTrue);
  });

  test('--yes alone falls back to the default storage path', () async {
    final code = await run(['init', '--yes']);

    expect(code, 0);
    expect(readConfig()['storage'], '~/.demo_app');
  });

  test('is idempotent', () async {
    await run(['init', '--storage=$keys', '--flavor=local', '--yes']);
    final first = fs.file(p.join(keys, 'local.key')).readAsStringSync();

    final code = await run(['init', '--storage=$keys', '--flavor=local', '-y']);

    expect(code, 0);
    expect(
      fs.file(p.join(keys, 'local.key')).readAsStringSync(),
      first,
      reason: 'a second init must not mint a new key over the old one',
    );
  });

  test('warns when storage sits inside the project', () async {
    final code = await run([
      'init',
      '--storage=${p.join(project, 'keys')}',
      '--flavor=local',
      '--yes',
    ]);

    expect(code, 0);
    expect(warnings.join(), contains('inside the project'));
  });

  test('does not warn when storage is outside the project', () async {
    await run(['init', '--storage=$keys', '--flavor=local', '--yes']);

    expect(warnings, isEmpty);
  });

  group('--gitignore', () {
    test('adds the key patterns', () async {
      await run([
        'init',
        '--storage=$keys',
        '--flavor=local',
        '--yes',
        '--gitignore',
      ]);

      final content = fs.file(p.join(project, '.gitignore')).readAsStringSync();

      expect(content, contains('*.key'));
      expect(content, contains('*.key.previous'));
    });

    test('appends to an existing .gitignore without disturbing it', () async {
      fs.file(p.join(project, '.gitignore'))
        ..createSync()
        ..writeAsStringSync('build/\n.dart_tool/\n');

      await run([
        'init',
        '--storage=$keys',
        '--flavor=local',
        '--yes',
        '--gitignore',
      ]);

      final content = fs.file(p.join(project, '.gitignore')).readAsStringSync();

      expect(content, contains('build/'));
      expect(content, contains('.dart_tool/'));
      expect(content, contains('*.key'));
    });

    test('does not add the same entry twice', () async {
      for (var i = 0; i < 3; i++) {
        await run([
          'init',
          '--storage=$keys',
          '--flavor=local',
          '--yes',
          '--gitignore',
        ]);
      }

      final content = fs.file(p.join(project, '.gitignore')).readAsStringSync();

      // The entries are written with an inline comment, so a whole-line
      // comparison never recognises pnv's own output and appends every run.
      int occurrences(String needle) =>
          RegExp(RegExp.escape(needle)).allMatches(content).length;

      expect(occurrences('*.key #'), 1);
      expect(occurrences('*.key.previous #'), 1);
    });

    test('recognises a bare entry a human wrote', () async {
      fs.file(p.join(project, '.gitignore'))
        ..createSync()
        ..writeAsStringSync('*.key\n*.key.previous\n');

      await run([
        'init',
        '--storage=$keys',
        '--flavor=local',
        '--yes',
        '--gitignore',
      ]);

      final content = fs.file(p.join(project, '.gitignore')).readAsStringSync();

      expect(content, '*.key\n*.key.previous\n');
    });
  });
}

class _MockLogger extends Mock implements Logger {}

class _MockProgress extends Mock implements Progress {}
