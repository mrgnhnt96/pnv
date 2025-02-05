import 'dart:convert';

import 'package:file/file.dart';
import 'package:yaml/yaml.dart';

mixin PubspecMixin {
  FileSystem get fs;

  String? get pubspecPath {
    Directory? dir;

    while (dir == null || dir.path != dir.parent.path) {
      dir ??= fs.currentDirectory;
      final pubspec = dir.childFile('pubspec.yaml');

      if (pubspec.existsSync()) {
        return pubspec.path;
      }

      dir = dir.parent;
    }

    return null;
  }

  String? pubspecContent() {
    final path = pubspecPath;

    if (path == null) {
      return null;
    }

    return fs.file(path).readAsStringSync();
  }

  Map<String, dynamic>? pubspec() {
    final content = pubspecContent();

    if (content == null) {
      return null;
    }

    try {
      final json = jsonDecode(jsonEncode(loadYaml(content)));

      return switch (json) {
        Map<String, dynamic>() => json,
        _ => null,
      };
    } catch (e) {
      return null;
    }
  }
}
