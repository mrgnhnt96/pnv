import 'package:args/command_runner.dart';
import 'package:file/file.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:pnv/src/commands/generate/generate_dart_command.dart';
import 'package:pnv/src/commands/generate/generate_env_command.dart';

class GenerateCommand extends Command<int> {
  GenerateCommand({
    required this.logger,
    required this.fs,
  }) {
    addSubcommand(
      GenerateEnvCommand(
        logger: logger,
        fs: fs,
      ),
    );
    addSubcommand(
      GenerateDartCommand(
        logger: logger,
        fs: fs,
      ),
    );
  }

  final Logger logger;
  final FileSystem fs;

  @override
  String get description => 'Generates files for your environment';

  @override
  String get name => 'generate';
}
