import 'dart:io';

import 'package:file/local.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:pnv/src/pnv_runner.dart';

void main(List<String> topLevelArgs) async {
  const fs = LocalFileSystem();

  final args = [...topLevelArgs];

  var level = Level.info;
  if (args.contains('--loud')) {
    level = Level.verbose;
    args.remove('--loud');
  } else if (args.contains('--quiet')) {
    level = Level.quiet;
    args.remove('--quiet');
  }

  final logger = Logger(
    level: level,
  );

  final runner = PnvRunner(
    fs: fs,
    logger: logger,
  );

  final result = await runner.run(args);

  exit(result);
}
