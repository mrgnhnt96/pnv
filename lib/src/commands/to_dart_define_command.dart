import 'package:args/command_runner.dart';
import 'package:file/file.dart';

class ToDartDefineCommand extends Command<int> {
  ToDartDefineCommand({
    required this.fs,
  });

  final FileSystem fs;

  @override
  String get usage => super.usage.replaceFirst('[arguments]', '<files>');

  @override
  String get description => 'Converts an env file to Dart Define arguments';

  @override
  String get name => 'to-dart-define';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;

    if (rest.isEmpty) {
      printUsage();
      return 1;
    }

    final files = rest.map(fs.file);

    final defines = <String>[];

    final lines = <String>[];

    for (final file in files) {
      if (!await file.exists()) {
        print('File ${file.path} does not exist.');
        return 1;
      }

      lines.addAll(await file.readAsLines());
    }

    for (final line in lines) {
      final parts = line.split('=');
      if (parts.length != 2) {
        continue;
      }

      final key = parts[0].trim().replaceAll('"', '');
      final value = parts[1].trim().replaceAll('"', '');

      if (key.isEmpty || value.isEmpty) {
        continue;
      }

      if (key.startsWith('#')) {
        continue;
      }

      defines.add('$key=$value');
    }

    print('-D${defines.join(',')}');

    return 0;
  }
}
