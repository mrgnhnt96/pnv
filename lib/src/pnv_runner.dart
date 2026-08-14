import 'package:args/command_runner.dart';
import 'package:file/file.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:pnv/src/commands/create_command.dart';
import 'package:pnv/src/commands/decrypt_command.dart';
import 'package:pnv/src/commands/delete_command.dart';
import 'package:pnv/src/commands/encrypt_command.dart';
import 'package:pnv/src/commands/generate/deprecated_generate_env_command.dart';
import 'package:pnv/src/commands/generate/generate_command.dart';
import 'package:pnv/src/commands/get_command.dart';
import 'package:pnv/src/commands/init_command.dart';
import 'package:pnv/src/commands/rotate_command.dart';
import 'package:pnv/src/commands/set_command.dart';
import 'package:pnv/src/commands/to_dart_define_command.dart';
import 'package:pnv/src/commands/verify_command.dart';
import 'package:pnv/src/handlers/flavor_handler.dart';
import 'package:pnv/src/pnv_exception.dart';

class PnvRunner extends CommandRunner<int> {
  PnvRunner({
    required FileSystem fs,
    required Logger logger,
    required FlavorHandler flavorHandler,
  })  : _logger = logger,
        super('pnv', 'Encrypt and decrypt secrets.') {
    addCommand(EncryptCommand(logger: logger, fs: fs));
    addCommand(DecryptCommand(logger: logger, fs: fs));
    addCommand(GenerateCommand(logger: logger, fs: fs));
    addCommand(DeprecatedGenerateEnvCommand(logger: logger, fs: fs));
    addCommand(CreateCommand(logger: logger, flavorHandler: flavorHandler));
    addCommand(DeleteCommand(logger: logger, flavorHandler: flavorHandler));
    addCommand(ToDartDefineCommand(fs: fs, logger: logger));
    addCommand(SetCommand(fs: fs, logger: logger));
    addCommand(GetCommand(fs: fs, logger: logger));
    addCommand(RotateCommand(fs: fs, logger: logger));
    addCommand(VerifyCommand(fs: fs, logger: logger));
    addCommand(
      InitCommand(logger: logger, fs: fs, flavorHandler: flavorHandler),
    );
  }

  final Logger _logger;

  @override
  Future<int> run(Iterable<String> args) async {
    try {
      final allArgs = [...args];

      if (allArgs.isEmpty) {
        allArgs.add('--help');
      }

      final argResults = parse(allArgs);

      final code = await runCommand(argResults) ?? 0;

      return code;
    } on UsageException catch (e) {
      _logger.err('$e');

      return 1;
    } on PnvException catch (e) {
      // Input failures are the user's problem to fix, so they read better
      // without a "Failed to run command" wrapper around them.
      _logger.err('❌ ${e.message}');

      return 1;
    } catch (e) {
      _logger.err('Failed to run command. $e');
      return 1;
    }
  }
}
