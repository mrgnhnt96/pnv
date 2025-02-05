import 'dart:convert';

import 'package:file/file.dart';
import 'package:yaml/yaml.dart';

mixin PubspecMixin {
  FileSystem get fs;

  String? _pubspecPath;
  String? get pubspecPath {
    if (_pubspecPath case final String path) {
      return path;
    }

    Directory? dir;
    while (dir == null || dir.path != dir.parent.path) {
      dir ??= fs.currentDirectory;
      final pubspec = dir.childFile('pubspec.yaml');

      if (pubspec.existsSync()) {
        return _pubspecPath = pubspec.path;
      }

      dir = dir.parent;
    }

    return null;
  }

  String? _content;
  String? pubspecContent() {
    if (_content case final String content) {
      return content;
    }

    final path = pubspecPath;

    if (path == null) {
      return null;
    }

    return _content = fs.file(path).readAsStringSync();
  }

  Map<String, dynamic>? _pubspec;
  Map<String, dynamic>? pubspec() {
    if (_pubspec case final Map<String, dynamic> pubspec) {
      return pubspec;
    }

    final content = pubspecContent();

    if (content == null) {
      return null;
    }

    try {
      final json = jsonDecode(jsonEncode(loadYaml(content)));

      return switch (json) {
        Map<String, dynamic>() => _pubspec = json,
        _ => null,
      };
    } catch (e) {
      return null;
    }
  }
}
