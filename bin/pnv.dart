import 'dart:io';

import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:pnv/src/pnv_runner.dart';

Future<void> main(
  List<String> topLevelArgs, {
  Logger? providedLogger,
  FileSystem? providedFs,
}) async {
  final fs = providedFs ?? const LocalFileSystem();

  final args = [...topLevelArgs];

  var level = Level.info;
  if (args.contains('--loud')) {
    level = Level.verbose;
    args.remove('--loud');
  } else if (args.contains('--quiet')) {
    level = Level.quiet;
    args.remove('--quiet');
  }

  final logger = providedLogger ??
      Logger(
        level: level,
      );

  final runner = PnvRunner(
    fs: fs,
    logger: logger,
  );

  final result = await runner.run(args);

  exitCode = result;
}
