import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:file/file.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:pnv/src/handlers/flavor_handler.dart';
import 'package:pnv/src/mixins/platform_mixin.dart';
import 'package:pnv/src/mixins/pnv_config_mixin.dart';
import 'package:pnv/src/mixins/pubspec_mixin.dart';
import 'package:pnv/src/models/pnv_config.dart';
import 'package:pnv/src/pnv_exception.dart';

/// What pnv adds to .gitignore, and why each line is there.
const gitignoreEntries = {
  '*.key': 'pnv encryption keys',
  '*.key.previous': 'pnv keys kept by `pnv rotate --new-key`',
};

class InitCommand extends Command<int>
    with PubspecMixin, PlatformMixin, PnvConfigMixin {
  InitCommand({
    required this.logger,
    required this.fs,
    required this.flavorHandler,
  }) {
    argParser
      ..addOption(
        'storage',
        abbr: 's',
        help: 'Where to keep the encryption keys. Must be outside the repo.',
        valueHelp: '~/.my_project',
      )
      ..addMultiOption(
        'flavor',
        abbr: 'f',
        help: 'A flavor to create. Repeatable.',
        valueHelp: 'production',
      )
      ..addFlag(
        'yes',
        abbr: 'y',
        negatable: false,
        help: 'Take the defaults and never prompt. Required where there is no '
            'terminal, such as CI.',
      )
      ..addFlag(
        'gitignore',
        negatable: false,
        help: 'Add pnv key patterns to .gitignore.',
      );
  }

  @override
  final Logger logger;
  @override
  final FileSystem fs;
  final FlavorHandler flavorHandler;

  @override
  String get name => 'init';

  @override
  String get description => 'Initialize a new environment';

  ArgResults get _args => argResults!;

  String? get storageOption {
    final value = (_args['storage'] as String?)?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  List<String> get flavorOptions =>
      (_args['flavor'] as List<String>).map((e) => e.trim()).toList()
        ..removeWhere((e) => e.isEmpty);

  bool get assumeYes => _args['yes'] == true;

  bool get updateGitignore => _args['gitignore'] == true;

  @override
  Future<int> run() async {
    try {
      return await _run();
    } on PnvException catch (e) {
      logger.err('❌ ${e.message}');
      return 1;
    }
  }

  Future<int> _run() async {
    final pubspec = this.pubspec();

    if (pubspec == null) {
      logger.err('Failed to find pubspec.yaml');
      return 1;
    }

    final name = pubspec['name'] as String?;

    if (name == null) {
      logger.err('Failed to find project name in pubspec.yaml');
      return 1;
    }

    logger.info('Initializing PNV for ${yellow.wrap(name)}...');

    final config = switch (pnvConfig()) {
      null => await createNewConfig(projectName: name),
      final config => config,
    };

    if (config == null) {
      logger.err('Failed to create PNV config');
      return 1;
    }

    setupFlavors(config);

    if (!saveConfig(config)) {
      logger.err('Failed to save config');
      return 1;
    }

    if (updateGitignore) {
      _addGitignoreEntries();
    }

    return 0;
  }

  Future<PnvConfig?> createNewConfig({
    required String projectName,
  }) async {
    final defaultPath = '~/.$projectName';

    var path = storageOption ?? '';

    // `--yes` exists so this can run where there is no terminal. Every prompt
    // below throws on such a host, so none of them may be reached.
    if (path.isEmpty && assumeYes) {
      path = defaultPath;
    }

    while (path.trim().isEmpty) {
      path = logger.prompt(
        'Where would like to store the secrets?',
        defaultValue: defaultPath,
      );

      final dir = fs.directory(replaceHome(path));
      if (dir.existsSync() && !fs.isDirectorySync(dir.path)) {
        logger.err('Invalid directory: $path');
        path = '';
        continue;
      }

      if (dir.existsSync()) {
        final confirm = logger.confirm(
          'The directory $path ${red.wrap('already exists')}. '
          'Do you still want to use it?',
        );

        if (!confirm) {
          path = '';
          continue;
        }
      }
    }

    _warnIfInsideProject(path);

    final dir = fs.directory(replaceHome(path));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final config = PnvConfig(storage: path);

    saveConfig(config);

    return config;
  }

  void setupFlavors(PnvConfig config) {
    final dir = storageDir(config);

    final foundFlavors = <String>{};
    if (dir.existsSync()) {
      final files = dir.listSync().whereType<File>();
      logger.detail('Found ${files.length} existing flavors');

      for (final entity in files) {
        logger.detail('Found flavor: ${entity.uri.path}');
        final fileName = entity.uri.pathSegments.last;

        if (p.extension(fileName) != keyExtension) continue;

        final flavor = p.basenameWithoutExtension(fileName);
        foundFlavors.add(flavor);

        if (!config.flavors.containsKey(flavor)) {
          config.addFlavor(flavor);
        }
      }
    } else {
      logger.detail('Storage directory not found');
    }

    if (foundFlavors.isNotEmpty) {
      logger.info('Found flavors:');
      for (final flavor in foundFlavors) {
        logger.info('  ${cyan.wrap(flavor)}');
      }
    }

    for (final flavor in config.flavors.keys) {
      if (!foundFlavors.contains(flavor)) {
        final created = flavorHandler.createIfNotExists(
          flavor,
          config: config,
          prompt: !assumeYes,
        );

        if (!created) {
          continue;
        }

        foundFlavors.add(flavor);
      }
    }

    for (final flavor in flavorOptions) {
      if (foundFlavors.contains(flavor)) continue;

      if (flavorHandler.create(flavor, config: config, force: true)) {
        logger.info('${green.wrap('✓')} ${cyan.wrap(flavor)}');
        foundFlavors.add(flavor);
      }
    }

    // Named flavors are the whole request, so having created them there is
    // nothing left to ask about.
    if (assumeYes || flavorOptions.isNotEmpty) return;

    final createFlavors = switch (foundFlavors.isEmpty) {
      true => true,
      false => logger.confirm('Do you want to add more flavors?'),
    };

    if (createFlavors) {
      flavorHandler.createMany(config: config);
    }
  }

  void _warnIfInsideProject(String path) {
    final root = pubspecPath;

    if (root == null) return;

    final projectDir = fs.file(root).parent.path;
    final storage = fs.directory(replaceHome(path)).path;

    if (p.equals(projectDir, storage) || p.isWithin(projectDir, storage)) {
      logger.warn(
        '⚠ "$path" is inside the project. Keys stored there are one '
        '`git add` away from being published. Prefer somewhere under your '
        'home directory.',
      );
    }
  }

  /// Appends pnv's key patterns to .gitignore, skipping anything already there.
  ///
  /// This is where the leak actually happens, and init is the only moment
  /// anyone is thinking about it.
  void _addGitignoreEntries() {
    final root = pubspecPath;

    if (root == null) return;

    final file = fs.file(p.join(fs.file(root).parent.path, '.gitignore'));
    final existing = file.existsSync() ? file.readAsStringSync() : '';
    // Compare the pattern only. The entries are written with an inline
    // comment, so matching whole lines never recognises its own output and
    // appends a fresh copy on every run.
    final lines =
        existing.split('\n').map((e) => e.split('#').first.trim()).toSet();

    final missing = gitignoreEntries.keys.where((e) => !lines.contains(e));

    if (missing.isEmpty) {
      logger.detail('.gitignore already covers pnv keys');
      return;
    }

    final buffer = StringBuffer(existing);

    if (existing.isNotEmpty && !existing.endsWith('\n')) buffer.writeln();
    buffer.writeln('\n# pnv');

    for (final entry in missing) {
      buffer.writeln('$entry # ${gitignoreEntries[entry]}');
    }

    file
      ..createSync(recursive: true)
      ..writeAsStringSync(buffer.toString());

    logger.info(
      '${green.wrap('✓')} Added ${missing.join(', ')} to .gitignore',
    );
  }
}
