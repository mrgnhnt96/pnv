import 'dart:io';

mixin PlatformMixin {
  String? _home;
  String get home {
    if (_home case final String home) {
      return home;
    }

    final home = switch (Platform.operatingSystem) {
      'windows' => Platform.environment['USERPROFILE'],
      _ => Platform.environment['HOME'],
    };

    if (home == null) {
      throw Exception('Failed to find home directory');
    }

    return _home = home;
  }

  String replaceHome(String path) {
    if (!path.startsWith('~')) {
      return path;
    }

    return path.replaceFirst('~', home);
  }
}
