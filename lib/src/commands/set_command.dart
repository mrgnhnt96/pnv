import 'dart:convert';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:pnv/src/commands/secret_file_command.dart';
import 'package:pnv/src/handlers/encrypt_handler.dart';
import 'package:pnv/src/pnv_exception.dart';
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

class SetCommand extends SecretFileCommand with EncryptHandler {
  SetCommand({
    required super.fs,
    required super.logger,
  }) {
    argParser
      ..addFlag(
        'stdin',
        negatable: false,
        help: 'Read the value from stdin instead of an argument. '
            'Use this for values too long or awkward to quote.',
      )
      ..addFlag(
        'plain',
        negatable: false,
        help: 'Write the value unencrypted. For config that lives beside '
            'secrets and is not one.',
      );
  }

  @override
  String get name => 'set';

  @override
  String get description => 'Encrypt a value into a .yaml file, in place.';

  @override
  String get invocation => 'pnv set <key.path> [value] --file <file.yaml>';

  bool get fromStdin => argResults['stdin'] == true;

  bool get plain => argResults['plain'] == true;

  @override
  Future<int> run() async {
    try {
      return _run();
    } on PnvException catch (e) {
      logger.err('❌ ${e.message}');
      return 1;
    }
  }

  int _run() {
    final rest = argResults.rest;

    if (rest.isEmpty) {
      throw const PnvException(
        'Missing the key path. Try: pnv set app.api-key "value" '
        '--file envs/app.local.yaml',
      );
    }

    final segments = pathSegments(rest.first);
    final file = targetFile;

    final String value;
    if (fromStdin) {
      value = stdin.readLineSync(encoding: utf8) ?? '';
    } else if (rest.length >= 2) {
      value = rest.sublist(1).join(' ');
    } else {
      throw const PnvException(
        'Missing the value. Pass it as an argument, or use --stdin.',
      );
    }

    final stored = switch (plain) {
      true => value,
      false => () {
          final key = keyForFile(file.path);
          return encryptValue(
            value,
            keyBytes: key.bytes,
            keyHash: key.hash,
          );
        }(),
    };

    // yaml_edit rewrites only the span it touches, so comments, key order and
    // indentation elsewhere in the file are preserved byte for byte.
    final editor = YamlEditor(file.readAsStringSync());

    setPath(editor, segments, stored);

    final updated = editor.toString();

    file.writeAsStringSync(
      updated.endsWith('\n') ? updated : '$updated\n',
    );

    final where = '${p.relative(file.path)} → ${segments.join('.')}';

    logger.info(
      '${green.wrap('✓')} ${plain ? 'Set' : 'Encrypted'} '
      '${yellow.wrap(where)}',
    );

    return 0;
  }

  /// Writes [value] at [segments], creating any groups on the way.
  ///
  /// yaml_edit will not create a parent en route to a key, and adding them one
  /// empty map at a time renders them in flow style (`db: {password: x}`),
  /// which reads nothing like the rest of the file. So this finds how far the
  /// existing structure goes and writes the whole remainder in one update,
  /// which yaml_edit renders as block style.
  void setPath(YamlEditor editor, List<String> segments, String value) {
    const missing = Object();

    dynamic nest(int from) {
      dynamic out = value;
      for (var i = segments.length - 1; i > from; i--) {
        out = {segments[i]: out};
      }
      return out;
    }

    // An empty file has no root map to traverse into, so seed the whole
    // structure at the root rather than walking a document that is not there.
    if (editor.parseAt([], orElse: () => YamlScalar.wrap(null)).value == null) {
      editor.update([], {segments.first: nest(0)});
      return;
    }

    var depth = 0;
    while (depth < segments.length) {
      final node = editor.parseAt(
        segments.sublist(0, depth + 1),
        orElse: () => YamlScalar.wrap(missing),
      );

      if (identical(node.value, missing)) break;

      // The last segment is allowed to be a scalar — that is an overwrite.
      if (depth == segments.length - 1) {
        depth++;
        break;
      }

      if (node is! YamlMap) {
        throw PnvException(
          '"${segments.sublist(0, depth + 1).join('.')}" is a value, not a '
          'group, so "${segments.join('.')}" cannot be set under it.',
        );
      }

      depth++;
    }

    if (depth == segments.length) {
      editor.update(segments, value);
      return;
    }

    editor.update(segments.sublist(0, depth + 1), nest(depth));
  }
}
