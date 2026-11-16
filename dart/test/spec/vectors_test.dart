import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:pnv/src/commands/cryptic_command.dart';
import 'package:pnv/src/commands/secret_file_command.dart';
import 'package:pnv/src/crypto/plaintext_detector.dart';
import 'package:pnv/src/crypto/secret_token.dart';
import 'package:pnv/src/handlers/decrypt_handler.dart';
import 'package:pnv/src/mixins/file_mixin.dart';
import 'package:pnv/src/models/pnv_config.dart';
import 'package:pnv/src/pnv_exception.dart';
import 'package:pnv/utils/constants.dart';
import 'package:pointycastle/export.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Runs every case in `spec/vectors/` against this package, so a change in
/// behavior that the spec does not describe fails here instead of surfacing
/// as a Rust/Dart mismatch later.
void main() {
  group('keys.json', () {
    final cmd = _Command();

    for (final c in _cases(_load('keys.json'), 'cases')) {
      test(c['name'], () {
        final key = c['key']! as String;

        if (c['error'] case final String kind) {
          expect(
            () => cmd.decodeSecret(key),
            _failsWith(kind),
          );
          return;
        }

        final bytes = cmd.decodeSecret(key);

        expect(_hex(bytes), c['bytes']);
        expect(_hex(sha256.convert(bytes).bytes), c['aes_key']);
        expect(_hex(keyFingerprint(bytes)), c['key_id']);
      });
    }
  });

  group('tokens.json', () {
    final tokens = _load('tokens.json');
    final handler = _Decrypter();

    group('decrypt', () {
      for (final c in _cases(tokens, 'decrypt')) {
        test(c['name'], () {
          final keyBytes = base64.decode(c['key']! as String);
          final keyHash = sha256.convert(keyBytes).bytes;
          final token = c['token']! as String;

          String run() => handler.decrypt(token, keyHash, keyBytes: keyBytes);

          if (c['error'] case final String kind) {
            expect(run, _failsWith(kind));
            return;
          }

          final parsed = SecretToken.parse(token);

          expect(parsed.version, c['version']);
          expect(
            parsed.keyId == null ? null : _hex(parsed.keyId!),
            c['key_id'],
          );
          expect(_hex(parsed.iv), c['iv']);
          expect(run(), c['plaintext']);
        });
      }
    });

    group('encrypt', () {
      for (final c in _cases(tokens, 'encrypt')) {
        test(c['plaintext'], () {
          final keyBytes = base64.decode(c['key']! as String);
          final iv = _unhex(c['iv']! as String);

          final cipher = GCMBlockCipher(AESEngine())
            ..init(
              true,
              AEADParameters(
                KeyParameter(
                  Uint8List.fromList(sha256.convert(keyBytes).bytes),
                ),
                algAuthTagLength * 8,
                iv,
                Uint8List(0),
              ),
            );

          final body = cipher.process(
            Uint8List.fromList(utf8.encode(c['plaintext']! as String)),
          );

          expect(
            SecretToken.encode(keyBytes: keyBytes, iv: iv, body: body),
            c['token'],
          );
        });
      }
    });
  });

  group('yaml_env.json', () {
    final vectors = _load('yaml_env.json');
    final keyBytes = base64.decode(vectors['key']! as String);
    final keyHash = sha256.convert(keyBytes).bytes;

    for (final c in _cases(vectors, 'cases')) {
      test(c['name'], () {
        final renderer = _EnvRenderer();
        const path = '/project/envs/app.local.yaml';

        renderer.fs.file(path)
          ..createSync(recursive: true)
          ..writeAsStringSync(c['yaml']! as String);

        String run() => renderer.renderEnvFromYaml(
              path,
              keyHash: keyHash,
              keyBytes: keyBytes,
            );

        if (c['error'] case final String kind) {
          expect(run, _failsWith(kind));
          return;
        }

        expect(run(), c['env']);
      });
    }
  });

  group('flavor_from_path.json', () {
    for (final c in _cases(_load('flavor_from_path.json'), 'cases')) {
      test(c['path'], () {
        expect(flavorFromPath(c['path']! as String), c['flavor']);
      });
    }
  });

  group('pnvrc.json', () {
    final vectors = _load('pnvrc.json');

    group('parse', () {
      for (final c in _cases(vectors, 'parse')) {
        test(c['name'], () {
          final json = c['pnvrc']! as Map<String, dynamic>;

          if (c['error'] case final String kind) {
            expect(() => PnvConfig.fromJson(json), _failsWith(kind));
            return;
          }

          expect(() => PnvConfig.fromJson(json), returnsNormally);
        });
      }
    });

    group('groups', () {
      final groups = vectors['groups']! as Map<String, dynamic>;
      final config =
          PnvConfig.fromJson(groups['pnvrc']! as Map<String, dynamic>);

      for (final c in _cases(groups, 'cases')) {
        test(c['name'], () {
          final group = c['group'] as List<dynamic>?;

          expect(
            config.flavorsFor(c['name']! as String),
            group == null ? isNull : unorderedEquals(group),
          );
        });
      }
    });
  });

  group('plaintext_detector.json', () {
    final vectors = _load('plaintext_detector.json');

    group('values', () {
      for (final c in _cases(vectors, 'values')) {
        final comment = c['comment'] as String?;

        test(
            '${c['key_path']}: ${jsonEncode(c['value'])}'
            '${comment == null ? '' : ' # $comment'}', () {
          final suspicion = suspectPlaintext(
            keyPath: c['key_path']! as String,
            value: c['value']! as String,
            comment: comment,
          );

          expect(suspicion != null, c['flagged']);
          expect(suspicion?.reason, c['reason']);
        });
      }
    });

    group('files', () {
      for (final c in _cases(vectors, 'files')) {
        test(c['name'], () {
          final source = c['yaml']! as String;
          final flagged = <String>[];

          final leaves = SecretFileCommand.leaves(loadYaml(source) as YamlMap);

          for (final (path, node) in leaves) {
            final value = node.value;

            if (value is! String || isSecret(value)) continue;

            final suspicion = suspectPlaintext(
              keyPath: path.join('.'),
              value: value,
              comment: commentAfter(node, source),
            );

            if (suspicion != null) flagged.add(path.join('.'));
          }

          expect(flagged, c['flagged']);
        });
      }
    });
  });
}

Map<String, dynamic> _load(String name) {
  final file = io.File(p.join('..', 'spec', 'vectors', name));

  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

Iterable<Map<String, dynamic>> _cases(Map<String, dynamic> json, String key) {
  return (json[key]! as List<dynamic>).cast<Map<String, dynamic>>();
}

/// The error kinds the spec names, told apart by how pnv words them.
String _kindOf(Object error) {
  final message = switch (error) {
    PnvException(:final message) => message,
    TypeError() => 'invalid',
    _ => '$error',
  };

  return switch (message) {
    'invalid' => 'invalid',
    _ when message.startsWith('Not a pnv secret') => 'not-a-secret',
    _ when message.startsWith('Malformed secret') => 'malformed',
    _ when message.startsWith('Wrong key') => 'wrong-key',
    _ when message.startsWith('Failed to decrypt') => 'decrypt-failed',
    _ when message.startsWith('Key is not valid base64') => 'invalid-key',
    _ when message.startsWith('Key is too short') => 'key-too-short',
    _ when message.startsWith('Unsupported value type') => 'unsupported-type',
    _ when message.contains('is not a valid .yaml file') => 'not-a-map',
    _ when message.contains('Flavors have conflicts') => 'conflict',
    _ => 'unexpected: $message',
  };
}

Matcher _failsWith(String kind) {
  return throwsA(
    predicate<Object>(
      (e) => _kindOf(e) == kind,
      'an error of kind "$kind"',
    ),
  );
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _unhex(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

class _Command extends CrypticCommand {
  _Command() : super(fs: MemoryFileSystem.test(), logger: Logger());

  @override
  String get name => 'vectors';

  @override
  String get description => 'Runs the spec vectors.';
}

class _Decrypter with DecryptHandler {
  @override
  String get secret => throw UnimplementedError();

  @override
  List<int> get keyHash => throw UnimplementedError();
}

class _EnvRenderer with DecryptHandler, FileMixin {
  @override
  final FileSystem fs = MemoryFileSystem.test();

  @override
  final Logger logger = Logger(level: Level.quiet);

  @override
  String? get input => null;

  @override
  String get secret => throw UnimplementedError();

  @override
  List<int> get keyHash => throw UnimplementedError();
}
