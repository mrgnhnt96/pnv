import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:pnv/src/commands/create/create_key_command.dart' as key;

class CreateKeyCommand extends Command<int> {
  CreateKeyCommand({
    required this.logger,
  });

  final Logger logger;

  @override
  bool get hidden => true;

  @override
  String get name => 'create-key';

  @override
  String get description => '[DEPRECATED] Use `pnv create key` instead.';

  @override
  Future<int> run() async {
    return key.CreateKeyCommand(
      logger: logger,
    ).run();
  }
}
