import 'package:args/command_runner.dart';
import 'package:file/file.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:pnv/src/mixins/platform_mixin.dart';
import 'package:pnv/src/mixins/pnv_config_mixin.dart';
import 'package:pnv/src/mixins/pubspec_mixin.dart';
import 'package:pnv/src/models/pnv_config.dart';

class InitCommand extends Command<int>
    with PubspecMixin, PlatformMixin, PnvConfigMixin {
  InitCommand({
    required this.logger,
    required this.fs,
  });

  @override
  final Logger logger;
  @override
  final FileSystem fs;

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

    final pnvConfig = this.pnvConfig();

    if (pnvConfig == null) {
      if (await createNewConfig(
        projectName: name,
      )
          case final code) {
        return code;
      }
    }

    return 0;
  }

  Future<int> createNewConfig({
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
      }
    }

    final dir = fs.directory(replaceHome(path));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final existingFlavors = <String>{};
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;

      final fileName = entity.uri.pathSegments.last;

      if (p.extension(fileName) != '.key') continue;

      final flavor = p.basenameWithoutExtension(fileName);
      existingFlavors.add(flavor);
    }

    final config = PnvConfig(
      storage: path,
      flavors: {
        for (final flavor in existingFlavors) flavor: [flavor],
      },
    );

    if (!saveConfig(config)) {
      logger.err('Failed to save config');
      return 1;
    }

    return 0;
  }
}
