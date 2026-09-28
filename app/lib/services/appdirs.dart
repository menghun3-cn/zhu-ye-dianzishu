import 'dart:io';

/// 纯 Dart 的应用支持目录解析。
///
/// 刻意不用 path_provider：它是本项目唯一的平台插件，会带来两串麻烦：
///   1. Windows 构建要求 `.plugin_symlinks` 建符号链接（需管理员 / 开发者模式），
///   2. path_provider_android → jni，后者把 JNI 原生工程塞进 Windows 构建。
/// 自己算路径后，三端都退化成纯 Dart，构建链路只有 Flutter 自己的产物。
class AppDirs {
  static const _appName = 'zhuye_reader';

  static String _p(List<String> parts) =>
      parts.where((e) => e.isNotEmpty).join(Platform.pathSeparator);

  /// 跨平台的「应用私有可写目录」。
  static Directory support() {
    if (Platform.isWindows) {
      final base = Platform.environment['APPDATA'] ??
          Platform.environment['LOCALAPPDATA'] ??
          Directory.systemTemp.path;
      return Directory(_p([base, _appName]));
    }
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
      return Directory(_p([home, 'Library', 'Application Support', _appName]));
    }
    if (Platform.isLinux) {
      final xdg = Platform.environment['XDG_DATA_HOME'];
      if (xdg != null && xdg.isNotEmpty) {
        return Directory(_p([xdg, _appName]));
      }
      final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
      return Directory(_p([home, '.local', 'share', _appName]));
    }
    // Android / iOS：systemTemp 落在应用私有的 cache 目录，可写，够 MVP 用。
    return Directory(_p([Directory.systemTemp.path, _appName]));
  }
}
