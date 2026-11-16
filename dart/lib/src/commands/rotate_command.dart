import 'package:file/file.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:pnv/src/commands/secret_file_command.dart';
import 'package:pnv/src/crypto/key_permissions.dart';
import 'package:pnv/src/crypto/secret_token.dart';
import 'package:pnv/src/handlers/decrypt_handler.dart';
import 'package:pnv/src/handlers/encrypt_handler.dart';
import 'package:pnv/src/mixins/crypto_mixin.dart';
import 'package:pnv/src/pnv_exception.dart';
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

/// A key in both the forms the crypto needs: the decoded bytes, which identify
/// it, and their hash, which is the AES key.
typedef _Key = ({List<int> bytes, List<int> hash});

class RotateCommand extends SecretFileCommand
    with DecryptHandler, EncryptHandler, CryptoMixin {
  RotateCommand({
    required super.fs,
    required super.logger,
  }) : super(requiresFile: false) {
    argParser
      ..addOption(
        'directory',
        abbr: 'd',
        aliases: ['dir'],
        help: 'Rotate every .yaml file in this directory.',
        valueHelp: 'envs',
      )
      ..addOption(
        'from',
        help: 'The flavor the secrets are encrypted with now. Defaults to the '
            'flavor each file name implies.',
        valueHelp: 'production',
      )
      ..addOption(
        'to',
        help: 'An existing flavor to re-encrypt with.',
        valueHelp: 'production-2026',
      )
      ..addFlag(
        'new-key',
        negatable: false,
        help: 'Generate a fresh key for --from and re-encrypt with it. '
            'The previous key is kept alongside as <flavor>.key.previous.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Report what would change without writing anything.',
      );
  }

  @override
  String get name => 'rotate';

  @override
  String get description =>
      'Re-encrypt a file or directory under a different key.';

  String? get directory => argResults['directory'] as String?;

  String? get from => _trimmed(argResults['from'] as String?);

  String? get to => _trimmed(argResults['to'] as String?);

  /// Named [generateNewKey] rather than `newKey` because CryptoMixin already
  /// has a `newKey` getter that mints one.
  bool get generateNewKey => argResults['new-key'] == true;

  bool get dryRun => argResults['dry-run'] == true;

  static String? _trimmed(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

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
    final files = _inputs();

    if (files.isEmpty) {
      throw const PnvException(
        'Nothing to rotate. Pass --file or --directory.',
      );
    }

    if (to == null && !generateNewKey) {
      throw const PnvException(
        'Name a destination: --to <flavor> to re-encrypt with an existing '
        'flavor, or --new-key to generate a fresh key for --from.',
      );
    }

    if (to != null && generateNewKey) {
      throw const PnvException('Use --to or --new-key, not both.');
    }

    if (generateNewKey && from == null) {
      throw const PnvException(
        "--new-key needs --from, so it knows which flavor's key to replace.",
      );
    }

    final destinationFlavor = to ?? from!;
    final destination =
        generateNewKey ? _freshKey() : _keyForFlavor(destinationFlavor);

    // Re-encrypt everything into memory before writing any of it. A partial
    // rotation is the one unrecoverable state here: half a file under the old
    // key and half under the new leaves nothing that can read the whole thing.
    final pending = <File, String>{};
    var rotated = 0;

    for (final file in files) {
      final source = file.readAsStringSync();
      final yaml = loadYaml(source);

      if (yaml == null) continue;

      if (yaml is! YamlMap) {
        throw PnvException('"${file.path}" is not a valid .yaml file.');
      }

      final origin =
          from == null ? keyForFile(file.path) : _keyForFlavor(from!);
      final editor = YamlEditor(source);
      var changed = 0;

      for (final (path, node) in SecretFileCommand.leaves(yaml)) {
        final value = node.value;

        if (value is! String || !isSecret(value)) continue;

        final plain = decrypt(
          value,
          origin.hash,
          context: '${p.relative(file.path)} → ${path.join('.')}',
          keyBytes: origin.bytes,
        );

        editor.update(
          path,
          encryptValue(
            plain,
            keyBytes: destination.bytes,
            keyHash: destination.hash,
          ),
        );

        changed++;
      }

      if (changed == 0) {
        logger.detail('No secrets in ${p.relative(file.path)}');
        continue;
      }

      rotated += changed;
      pending[file] = editor.toString();

      logger.info(
        '${dryRun ? darkGray.wrap('·') : green.wrap('✓')} '
        '${p.relative(file.path)} '
        '${darkGray.wrap('($changed secret${changed == 1 ? '' : 's'})')}',
      );
    }

    if (rotated == 0) {
      logger.warn('No secrets found to rotate.');
      return 0;
    }

    if (dryRun) {
      final where = generateNewKey
          ? 'a fresh key for "$destinationFlavor"'
          : '"$destinationFlavor"';

      logger.info(
        'Dry run: $rotated secret(s) in ${pending.length} file(s) would move '
        'to $where.',
      );
      return 0;
    }

    // The key lands before the files. If writing the files then fails, the new
    // key is on disk and .previous holds the old one, so both halves are still
    // readable. The reverse order would leave files nothing can open.
    String? backup;
    if (generateNewKey) {
      backup = _installKey(destinationFlavor);
    }

    for (final MapEntry(key: file, value: content) in pending.entries) {
      file.writeAsStringSync(content.endsWith('\n') ? content : '$content\n');
    }

    logger
      ..info('')
      ..info('Re-encrypted $rotated secret(s) with "$destinationFlavor".');

    if (backup != null) {
      logger.info(
        'The previous key is at $backup. '
        'Delete it once you are sure nothing still needs it.',
      );
    } else {
      logger.info(
        'The "${from ?? 'source'}" key was NOT deleted. Retire it with '
        '`pnv delete flavor` once the new files are confirmed working.',
      );
    }

    return 0;
  }

  /// A brand new key, not yet on disk.
  late final String _generated = newKey;

  _Key _freshKey() {
    return (bytes: decodeSecret(_generated), hash: keyHashFor(_generated));
  }

  _Key _keyForFlavor(String flavor) {
    final secret = secretFor(flavor: flavor);

    return (bytes: decodeSecret(secret), hash: keyHashFor(secret));
  }

  /// Writes the generated key over [flavor]'s, keeping the old one alongside.
  ///
  /// Returns where the old key was kept. Without that copy, a crash between
  /// this and the file writes would leave secrets nothing can open.
  String _installKey(String flavor) {
    final config = pnvConfig();

    if (config == null) {
      throw const PnvException('No .pnvrc found. Run `pnv init` first.');
    }

    final keyFile = storageKeyFile(flavor, config);

    if (!keyFile.existsSync()) {
      throw PnvException(
        'No key file for "$flavor" at ${keyFile.path}, so there is nothing '
        'to rotate.',
      );
    }

    final backup = fs.file('${keyFile.path}.previous')
      ..writeAsStringSync(keyFile.readAsStringSync());

    // The backup still decrypts every secret written before this rotation, so
    // it is exactly as sensitive as the key it replaces.
    restrictKeyPermissions(fs, backup, logger: logger);

    keyFile.writeAsStringSync(_generated);
    restrictKeyPermissions(fs, keyFile, logger: logger);

    return backup.path;
  }

  List<File> _inputs() {
    if (input != null) {
      return [targetFile];
    }

    if (directory case final String dir) {
      final directory = fs.directory(dir);

      if (!directory.existsSync()) {
        throw PnvException('Input directory "$dir" does not exist.');
      }

      return directory
          .listSync()
          .whereType<File>()
          .where((e) => const {'.yaml', '.yml'}.contains(p.extension(e.path)))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
    }

    return const [];
  }
}
