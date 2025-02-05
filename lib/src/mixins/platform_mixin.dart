import 'dart:io';

mixin PlatformMixin {
  String get home {
    final home = switch (Platform.operatingSystem) {
      'windows' => Platform.environment['USERPROFILE'],
      _ => Platform.environment['HOME'],
    };

    return switch (home) {
      String() => home,
      _ => throw Exception('Failed to find home directory'),
    };
  }

  String replaceHome(String path) {
    if (!path.startsWith('~')) {
      return path;
    }

    return path.replaceFirst('~', home);
  }
}
