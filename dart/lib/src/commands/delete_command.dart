import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:pnv/src/commands/delete/delete_flavor_command.dart';
import 'package:pnv/src/handlers/flavor_handler.dart';

class DeleteCommand extends Command<int> {
  DeleteCommand({
    required FlavorHandler flavorHandler,
    required Logger logger,
  }) {
    addSubcommand(
      DeleteFlavorCommand(flavorHandler: flavorHandler, logger: logger),
    );
  }

  @override
  String get description => 'Delete commands';

  @override
  String get name => 'delete';
}
