import 'dart:io';
import 'package:path/path.dart' as path;

class Utils {
  static final credentialsFilePath =
      path.join(Utils.dartConfigDir, 'pub-credentials.json');

  /// The location for dart-specific configuration.
  static final String dartConfigDir = () {
    String? configDir;
    if (Platform.isLinux) {
      configDir = Platform.environment['XDG_CONFIG_HOME'] ??
          path.join(Platform.environment['HOME']!, '.config');
    } else if (Platform.isWindows) {
      configDir = Platform.environment['APPDATA']!;
    } else if (Platform.isMacOS) {
      configDir = path.join(
          Platform.environment['HOME']!, 'Library', 'Application Support');
    } else {
      configDir = path.join(Platform.environment['HOME'] ?? '', '.config');
    }
    return path.join(configDir, 'dart');
  }();
}
