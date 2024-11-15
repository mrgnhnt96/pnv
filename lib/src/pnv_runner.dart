import 'package:args/command_runner.dart';
import 'package:file/file.dart';
import 'package:pnv/src/commands/create_key_command.dart';
import 'package:pnv/src/commands/decrypt_command.dart';
import 'package:pnv/src/commands/encrypt_command.dart';
import 'package:pnv/src/commands/generate_env_command.dart';
import 'package:pnv/src/commands/to_dart_define_command.dart';

class PnvRunner extends CommandRunner<int> {
  PnvRunner({
    required FileSystem fs,
  }) : super('secrets', 'Encrypt and decrypt secrets.') {
    addCommand(EncryptCommand(fs: fs));
    addCommand(DecryptCommand(fs: fs));
    addCommand(GenerateEnvCommand(fs: fs));
    addCommand(CreateKeyCommand());
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

      return await runCommand(argResults) ?? 0;
    } on UsageException catch (e) {
      print(e);

      return 1;
    } catch (e) {
      print('Failed to run command. $e');
      return 1;
    }
  }
}
