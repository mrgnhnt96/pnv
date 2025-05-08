import 'package:args/command_runner.dart';
import 'package:pnv/src/handlers/flavor_handler.dart';

class CreateFlavorCommand extends Command<int> {
  CreateFlavorCommand({
    required this.flavorHandler,
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

  final FlavorHandler flavorHandler;

  @override
  String get name => 'flavor';

  @override
  String get description => 'Create a new flavor.';

  String? get flavorName => argResults?['name'] as String?;

  @override
  int run() {
    final success = flavorHandler.create(flavorName ?? '', log: true);

    if (!success) {
      return 1;
    }

    return 0;
  }
}
