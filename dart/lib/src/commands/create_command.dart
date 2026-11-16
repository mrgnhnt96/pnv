import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:pnv/src/commands/create/create_flavor_command.dart';
import 'package:pnv/src/commands/create/create_key_command.dart';
import 'package:pnv/src/handlers/flavor_handler.dart';

class CreateCommand extends Command<int> {
  CreateCommand({
    required Logger logger,
    required FlavorHandler flavorHandler,
  }) {
    addSubcommand(CreateKeyCommand(logger: logger));
    addSubcommand(CreateFlavorCommand(flavorHandler: flavorHandler));
  }

  @override
  String get name => 'create';

  @override
  String get description => 'Create new entities for your environment';
}
