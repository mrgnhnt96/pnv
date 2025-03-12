import 'package:pnv/src/commands/generate/generate_env_command.dart';

class DeprecatedGenerateEnvCommand extends GenerateEnvCommand {
  DeprecatedGenerateEnvCommand({
    required super.fs,
    required super.logger,
  });

  @override
  String get name => 'generate-env';

  @override
  Future<int> run() {
    logger.warn('This command is deprecated. Use `pnv generate env` instead.');
    return super.run();
  }
}
