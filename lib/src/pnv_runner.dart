import 'package:args/command_runner.dart';
import 'package:file/file.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:pnv/src/commands/create_command.dart';
import 'package:pnv/src/commands/decrypt_command.dart';
import 'package:pnv/src/commands/encrypt_command.dart';
import 'package:pnv/src/commands/generate_env_command.dart';
import 'package:pnv/src/commands/init_command.dart';
import 'package:pnv/src/commands/to_dart_define_command.dart';

class PnvRunner extends CommandRunner<int> {
  PnvRunner({
    required FileSystem fs,
    required Logger logger,
  }) : super('secrets', 'Encrypt and decrypt secrets.') {
    addCommand(EncryptCommand(fs: fs));
    addCommand(DecryptCommand(fs: fs));
    addCommand(GenerateEnvCommand(fs: fs));
    addCommand(InitCommand(logger: logger, fs: fs));
    addCommand(
      CreateCommand(
        logger: logger,
      ),
    );
    addCommand(ToDartDefineCommand(fs: fs));
  }

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
      print(e);

      return 1;
    } catch (e) {
      print('Failed to run command. $e');
      return 1;
    }
  }
}
