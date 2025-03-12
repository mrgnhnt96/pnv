import 'package:args/command_runner.dart';
import 'package:file/file.dart';
import 'package:mason_logger/mason_logger.dart';

class GenerateDartCommand extends Command<int> {
  GenerateDartCommand({
    required this.logger,
    required this.fs,
  }) {
    argParser.addOption(
      'output',
      abbr: 'o',
      help: 'The directory to output the .env file to.',
      valueHelp: 'lib/envs',
      mandatory: true,
    );
  }

  @override
  String get name => 'dart';

  @override
  String get description => 'Generate a .dart file from a .env file.';

  final Logger logger;
  final FileSystem fs;
}
