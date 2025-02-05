import 'dart:async';

import 'package:args/command_runner.dart';
import 'package:file/file.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:pnv/src/mixins/crypto_mixin.dart';
import 'package:pnv/src/mixins/platform_mixin.dart';
import 'package:pnv/src/mixins/pnv_config_mixin.dart';
import 'package:pnv/src/mixins/pubspec_mixin.dart';

class CreateFlavorCommand extends Command<int>
    with PubspecMixin, PlatformMixin, PnvConfigMixin, CryptoMixin {
  CreateFlavorCommand({
    required this.fs,
    required this.logger,
  }) {
    argParser
      ..addOption(
        'name',
        abbr: 'n',
        help: 'The flavor to create.',
      )
      ..addFlag(
        'force',
        abbr: 'f',
        help: 'Force overwrite existing files.',
      );
  }

  @override
  final FileSystem fs;
  @override
  final Logger logger;

  @override
  String get name => 'flavor';

  @override
  String get description => 'Create a new flavor.';

  String? get flavorName => argResults?['name'] as String?;

  @override
  FutureOr<int>? run() {
    final config = pnvConfig();

    if (config == null) {
      logger.err('No config found. Run `pnv init` first.');
      return 1;
    }

    var newFlavor = flavorName ?? '';

    final allowed = RegExp(r'^[a-zA-Z0-9_-]+$');

    while (newFlavor.trim().isEmpty) {
      newFlavor = logger
          .prompt('Whats the name of the new ${green.wrap('Flavor')}?')
          .trim();

      if (config.flavors[newFlavor] != null) {
        logger.err('Flavor already exists.');
        final overwrite = logger.confirm(
          red.wrap('Do you want to overwrite the existing flavor?'),
        );

        if (!overwrite) {
          logger.info('Aborting...');
          return 0;
        }
      }

      if (!allowed.hasMatch(newFlavor)) {
        logger.err(
          'Flavor name can only contain letters, '
          'numbers, underscores and dashes.',
        );
        newFlavor = '';
      }
    }

    final flavorFile = storageDir?.childFile('$newFlavor.key');

    if (flavorFile == null) {
      logger.err('Failed to create flavor file.');
      return 1;
    }

    flavorFile
      ..create()
      ..writeAsStringSync(newKey);

    config.addFlavor(newFlavor);

    saveConfig(config);

    return null;
  }
}
