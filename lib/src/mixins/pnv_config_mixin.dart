import 'dart:convert';

import 'package:file/file.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:pnv/src/mixins/platform_mixin.dart';
import 'package:pnv/src/mixins/pubspec_mixin.dart';
import 'package:pnv/src/models/pnv_config.dart';

mixin PnvConfigMixin on PubspecMixin, PlatformMixin {
  Logger get logger;

  String? _pnvConfigPath;
  String? get pnvConfigPath {
    if (_pnvConfigPath case final String path) {
      return path;
    }

    final root = pubspecPath;

    if (root == null) {
      Directory? dir;
      while (dir == null || dir.path != dir.parent.path) {
        dir ??= fs.currentDirectory;
        final config = dir.childFile('.pnvrc');

        if (config.existsSync()) {
          return _pnvConfigPath = config.path;
        }

        dir = dir.parent;
      }

      return null;
    }

    final dir = fs.file(pubspecPath).parent;

    final pnvConfig = dir.childFile('.pnvrc');

    return _pnvConfigPath = pnvConfig.path;
  }

  PnvConfig? _config;
  PnvConfig? pnvConfig() {
    if (_config case final PnvConfig config) {
      return config;
    }

    final path = pnvConfigPath;

    if (path == null) {
      return null;
    }

    final file = fs.file(path);

    if (!file.existsSync()) {
      return null;
    }

    final content = file.readAsStringSync();

    if (content.trim().isEmpty) {
      return null;
    }

    final json = jsonDecode(content);

    return switch (json) {
      Map<String, dynamic>() => _config = PnvConfig.fromJson(json),
      _ => null,
    };
  }

  bool saveConfig(PnvConfig config) {
    final path = pnvConfigPath;

    if (path == null) {
      return false;
    }

    try {
      const encoder = JsonEncoder.withIndent('  ');

      final file = fs.file(path);

      if (!file.existsSync()) {
        file.createSync(recursive: true);
      }

      final json = encoder.convert(config.toJson());
      file.writeAsStringSync(json);

      return true;
    } catch (e) {
      logger
        ..err('Failed to save config')
        ..err('$e');
      return false;
    }
  }

  Directory? _storage;
  Directory? get storageDir {
    if (_storage case final Directory dir) {
      return dir;
    }

    final config = pnvConfig();

    if (config == null) {
      return null;
    }

    return _storage = fs.directory(replaceHome(config.storage));
  }
}
