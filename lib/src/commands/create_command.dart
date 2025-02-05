import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:pnv/src/commands/create/create_key_command.dart';

class CreateCommand extends Command<int> {
  CreateCommand({
    required Logger logger,
  }) {
    addSubcommand(
      CreateKeyCommand(
        logger: logger,
      ),
    );
  }

  @override
  String get name => 'create';

  @override
  String get description => 'Create new entities for your environment';
}
