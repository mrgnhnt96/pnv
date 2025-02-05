import 'package:args/command_runner.dart';
import 'package:file/file.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:pnv/src/commands/create/create_flavor_command.dart';
import 'package:pnv/src/commands/create/create_key_command.dart';

class CreateCommand extends Command<int> {
  CreateCommand({
    required Logger logger,
    required FileSystem fs,
  }) {
    addSubcommand(
      CreateKeyCommand(
        logger: logger,
      ),
    );
    addSubcommand(
      CreateFlavorCommand(
        logger: logger,
        fs: fs,
      ),
    );
  }

  @override
  String get name => 'create';

  @override
  String get description => 'Create new entities for your environment';
}
