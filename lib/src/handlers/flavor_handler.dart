import 'package:file/file.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:pnv/src/mixins/crypto_mixin.dart';
import 'package:pnv/src/mixins/platform_mixin.dart';
import 'package:pnv/src/mixins/pnv_config_mixin.dart';
import 'package:pnv/src/mixins/pubspec_mixin.dart';
import 'package:pnv/src/models/pnv_config.dart';

class FlavorHandler
    with PubspecMixin, PlatformMixin, PnvConfigMixin, CryptoMixin {
  FlavorHandler({
    required this.fs,
    required this.logger,
  });

  @override
  final FileSystem fs;
  @override
  final Logger logger;

  /// The allowed characters for a flavor name.
  final allowed = RegExp(r'^[a-zA-Z0-9_-]+$');

  List<String> flavors() {
    final config = pnvConfig();

    if (config == null) {
      logger.err('No config found. Run `pnv init` first.');
      throw Exception('No config found. Run `pnv init` first.');
    }

    return config.flavors.keys.toList();
  }

  bool create(
    String flavor, {
    PnvConfig? config,
    bool log = false,
  }) {
    config ??= pnvConfig();

    if (config == null) {
      logger.err('No config found. Run `pnv init` first.');
      throw Exception('No config found. Run `pnv init` first.');
    }

    var newFlavor = flavor;

    while (newFlavor.trim().isEmpty) {
      newFlavor = logger
          .prompt('Whats the name of the new ${green.wrap('Flavor')}?')
          .trim();

      final canCreateResult = canCreate(newFlavor, config: config);

      if (canCreateResult.invalid) {
        continue;
      }

      if (canCreateResult.exists) {
        logger.info('Aborting...');
        return false;
      }
    }

    final canCreateResult = canCreate(newFlavor, config: config);

    if (canCreateResult.invalid) {
      return false;
    }

    if (canCreateResult.exists) {
      logger.err('Flavor already exists.');
      final overwrite = logger.confirm(
        red.wrap('Do you want to overwrite the existing flavor?'),
      );

      if (!overwrite) {
        return false;
      }
    }

    final progress = switch (log) {
      true => logger.progress('Creating'),
      false => null,
    };

    _createAndSave(newFlavor, config);

    progress?.complete('Created flavor ${cyan.wrap(newFlavor)}');

    return true;
  }

  void _createAndSave(String flavor, PnvConfig config) {
    storageDir(config).childFile('$flavor.key')
      ..createSync(recursive: true)
      ..writeAsStringSync(newKey);

    config.addFlavor(flavor);

    saveConfig(config);
  }

  bool createIfNotExists(
    String flavor, {
    PnvConfig? config,
    bool prompt = false,
  }) {
    config ??= pnvConfig();

    if (config == null) {
      logger.err('No config found. Run `pnv init` first.');
      throw Exception('No config found. Run `pnv init` first.');
    }

    final canCreateResult = canCreate(flavor, config: config);

    if (canCreateResult.exists && !canCreateResult.missingFile) {
      logger.detail('${green.wrap('✓')} ${cyan.wrap(flavor)} exists');
      return true;
    }

    if (canCreateResult.invalid) {
      logger.err('Invalid flavor name: $flavor');
      return false;
    }

    if (prompt) {
      final create = logger.confirm(
        'Flavor ${cyan.wrap(flavor)} is ${red.wrap('missing')} a key file. '
        'Do you want to create it?',
      );

      if (!create) {
        return false;
      }
    }

    final progress = logger.progress('Creating flavor: $flavor');
    _createAndSave(flavor, config);
    progress.complete('Created flavor ${cyan.wrap(flavor)}');

    return true;
  }

  ({bool invalid, bool exists, bool missingFile}) canCreate(
    String flavor, {
    required PnvConfig config,
  }) {
    final file = storageKeyFile(flavor, config);
    final isMissingFile = !file.existsSync();

    if (config.flavors[flavor] != null) {
      logger.detail('Flavor ($flavor) is setup in config');
      if (isMissingFile) {
        logger.detail('Flavor ($flavor) is missing a key file');
      }

      return (invalid: false, exists: true, missingFile: isMissingFile);
    }

    if (!allowed.hasMatch(flavor)) {
      logger.err(
        'Flavor name can only contain letters, '
        'numbers, underscores and dashes.',
      );
      return (invalid: true, exists: false, missingFile: isMissingFile);
    }

    return (invalid: false, exists: false, missingFile: isMissingFile);
  }

  void createMany({
    PnvConfig? config,
  }) {
    config ??= pnvConfig();

    if (config == null) {
      logger.err('No config found. Run `pnv init` first.');
      throw Exception('No config found. Run `pnv init` first.');
    }

    while (true) {
      final flavor = logger.prompt(
        "What's the name of the new ${green.wrap('Flavor')}? "
        "${darkGray.wrap('(leave blank to finish)')}",
      );

      if (flavor.isEmpty) {
        break;
      }

      final success = create(flavor, config: config);

      if (success) {
        logger.success('✓ $flavor');
      }
    }

    saveConfig(config);
  }

  void delete(String flavor) {
    final config = pnvConfig();

    if (config == null) {
      logger.err('No config found. Run `pnv init` first.');
      throw Exception('No config found. Run `pnv init` first.');
    }

    final file = storageKeyFile(flavor, config);

    if (file.existsSync()) {
      file.deleteSync();
    }

    config.flavors.remove(flavor);
    saveConfig(config);
  }
}
