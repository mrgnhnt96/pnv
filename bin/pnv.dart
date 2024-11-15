import 'dart:io';

import 'package:file/local.dart';
import 'package:pnv/src/pnv_runner.dart';

void main(List<String> args) async {
  const fs = LocalFileSystem();

  final runner = PnvRunner(fs: fs);

  final result = await runner.run(args);

  exit(result);
}
