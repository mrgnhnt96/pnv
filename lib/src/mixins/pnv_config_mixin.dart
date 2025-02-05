import 'dart:convert';

import 'package:mason_logger/mason_logger.dart';
import 'package:pnv/src/mixins/pubspec_mixin.dart';
import 'package:pnv/src/models/pnv_config.dart';

mixin PnvConfigMixin on PubspecMixin {
  Logger get logger;

  String? get pnvConfigPath {
    final pubspecPath = this.pubspecPath;

    if (pubspecPath == null) {
      return null;
    }

    final dir = fs.file(pubspecPath).parent;

    final pnvConfig = dir.childFile('.pnvrc');

    if (!pnvConfig.existsSync()) {
      pnvConfig.create();
    }

    return pnvConfig.path;
  }

  PnvConfig? pnvConfig() {
    final path = pnvConfigPath;

    if (path == null) {
      return null;
    }

    final content = fs.file(path).readAsStringSync();

    if (content.trim().isEmpty) {
      return null;
    }

    final json = jsonDecode(content);

    return switch (json) {
      Map<String, dynamic>() => PnvConfig.fromJson(json),
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

      final json = encoder.convert(config.toJson());
      fs.file(path).writeAsStringSync(json);

      return true;
    } catch (e) {
      logger
        ..err('Failed to save config')
        ..err('$e');
      return false;
    }
  }
}
