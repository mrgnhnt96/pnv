import 'package:args/command_runner.dart';
import 'package:file/file.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:pnv/src/handlers/flavor_handler.dart';
import 'package:pnv/src/mixins/platform_mixin.dart';
import 'package:pnv/src/mixins/pnv_config_mixin.dart';
import 'package:pnv/src/mixins/pubspec_mixin.dart';
import 'package:pnv/src/models/pnv_config.dart';

class InitCommand extends Command<int>
    with PubspecMixin, PlatformMixin, PnvConfigMixin {
  InitCommand({
    required this.logger,
    required this.fs,
    required this.flavorHandler,
  });

  @override
  final Logger logger;
  @override
  final FileSystem fs;
  final FlavorHandler flavorHandler;

  @override
  String get name => 'init';

  @override
  String get description => 'Initialize a new environment';

  @override
  Future<int> run() async {
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

    return 0;
  }

  Future<PnvConfig?> createNewConfig({
    required String projectName,
  }) async {
    var path = '';
    while (path.trim().isEmpty) {
      path = logger.prompt(
        'Where would like to store the secrets?',
        defaultValue: '~/.$projectName',
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
          prompt: true,
        );

        if (!created) {
          continue;
        }

        foundFlavors.add(flavor);
      }
    }

    final createFlavors = switch (foundFlavors.isEmpty) {
      true => true,
      false => logger.confirm(
          'Do you want to add more flavors?',
        ),
    };

    if (createFlavors) {
      flavorHandler.createMany(config: config);
    }
  }
}
