import 'dart:io';

import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:mason_logger/mason_logger.dart';

/// Makes [file] readable only by its owner.
///
/// A key file *is* the secret, so it must not be left at the default umask.
/// Dart's file API cannot set a mode, so this shells out — and only for a real
/// file system, because tests run against an in-memory one where these paths
/// may collide with the developer's own keys on disk.
void restrictKeyPermissions(
  FileSystem fs,
  File file, {
  Logger? logger,
}) {
  if (fs is! LocalFileSystem) return;
  if (Platform.isWindows) return;

  try {
    final result = Process.runSync('chmod', ['600', file.path]);

    if (result.exitCode != 0) {
      logger?.detail('Could not restrict permissions on ${file.path}');
    }
  } catch (e) {
    logger?.detail('Could not restrict permissions on ${file.path}: $e');
  }
}
