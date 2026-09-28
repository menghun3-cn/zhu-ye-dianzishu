import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'appdirs.dart';

import '../models.dart';

/// 本地持久化：排版设置、书库目录、阅读进度、书签。
/// 全部落在应用支持目录下的 zhuye_reader/，不碰系统其他位置。
class Store extends ChangeNotifier {
  late Directory _dir;
  ReaderSettings settings = const ReaderSettings();
  String libraryRoot = '';
  Map<String, BookProgress> progress = {};
  List<Bookmark> bookmarks = [];

  /// 默认书库目录：Windows 下用下载落盘目录 E:\chinabook，其他平台用应用文档目录。
  static String defaultLibraryRoot() {
    if (kIsWeb) return '';
    if (Platform.isWindows) return r'E:\chinabook';
    // Android：共享存储下的书库目录（需在系统设置里授予「所有文件访问」权限）。
    if (Platform.isAndroid) return '/storage/emulated/0/chinabook';
    // iOS：App 沙盒的 Documents（配合 UIFileSharingEnabled 可用文件 App / iTunes 拷入）。
    if (Platform.isIOS) {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isNotEmpty) return '$home/Documents/chinabook';
    }
    return '';
  }

  static Future<Store> load() async {
    final s = Store();
    s._dir = AppDirs.support();
    if (!s._dir.existsSync()) s._dir.createSync(recursive: true);

    final cfg = s._readJson('store.json');
    if (cfg != null) {
      s.settings = ReaderSettings.fromJson((cfg['settings'] as Map?)?.cast<String, dynamic>() ?? {});
      s.libraryRoot = (cfg['libraryRoot'] ?? '').toString();
    } else {
      s.libraryRoot = defaultLibraryRoot();
    }

    final pr = s._readJson('progress.json');
    if (pr != null) {
      pr.forEach((k, v) {
        if (v is Map) s.progress[k] = BookProgress.fromJson(v.cast<String, dynamic>());
      });
    }

    final bm = s._readJson('bookmarks.json');
    if (bm != null && bm['items'] is List) {
      s.bookmarks = (bm['items'] as List)
          .whereType<Map>()
          .map((e) => Bookmark.fromJson(e.cast<String, dynamic>()))
          .toList();
    }
    return s;
  }

  /// 显式声明无参构造：一旦类里出现任何命名构造函数，Dart 就不再自动生成它，
  /// 而 `load()` 等地方仍然需要 `Store()`。
  Store();

  /// 仅测试用：把持久化目录指到临时目录，避免验收测试动到真实用户配置与阅读进度。
  @visibleForTesting
  factory Store.forTest(Directory dir, {String libraryRoot = ''}) {
    final s = Store();
    s._dir = dir;
    if (!dir.existsSync()) dir.createSync(recursive: true);
    s.libraryRoot = libraryRoot;
    return s;
  }

  Directory get dir => _dir;

  Map<String, dynamic>? _readJson(String name) {
    try {
      final f = File('${_dir.path}${Platform.pathSeparator}$name');
      if (!f.existsSync()) return null;
      return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  void _writeJson(String name, Object data) {
    try {
      final f = File('${_dir.path}${Platform.pathSeparator}$name');
      f.writeAsStringSync(jsonEncode(data), flush: true);
    } catch (_) {}
  }

  Future<void> saveConfig() async {
    _writeJson('store.json', {
      'settings': settings.toJson(),
      'libraryRoot': libraryRoot,
    });
    notifyListeners();
  }

  void setSettings(ReaderSettings s) {
    settings = s;
    _writeJson('store.json', {
      'settings': settings.toJson(),
      'libraryRoot': libraryRoot,
    });
    notifyListeners();
  }

  void setLibraryRoot(String root) {
    libraryRoot = root;
    _writeJson('store.json', {
      'settings': settings.toJson(),
      'libraryRoot': libraryRoot,
    });
    notifyListeners();
  }

  BookProgress? progressOf(String fileId) => progress[fileId];

  /// 记录阅读进度。
  ///
  /// [notify] 正常应为 true（书架要跟着刷新「第 N 章」）。**唯一的例外是阅读页
  /// `dispose()` 里那次落盘**：那时框架正处在「树已锁定」的卸载阶段，
  /// notifyListeners 会一路调到 HomeShell.setState →
  /// `setState() called when widget tree was locked`（真机上是红屏/断言）。
  /// 所以卸载路径必须传 notify: false —— 盘照写，只是不广播。
  void setProgress(String fileId, int chapter, int page, {bool notify = true}) {
    progress[fileId] = BookProgress(
      chapterIndex: chapter,
      pageIndex: page,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    if (notify) notifyListeners();
    // 进度写盘做节流：这里直接写，文件很小（单本 ~60 字节 * N）
    _writeJson('progress.json', progress.map((k, v) => MapEntry(k, v.toJson())));
  }

  bool isBookmarked(String fileId, int chapter, int page) => bookmarks
      .any((b) => b.fileId == fileId && b.chapterIndex == chapter && b.pageIndex == page);

  void toggleBookmark(Bookmark b) {
    // 注意顺序：必须先记住「原来有没有」，再删。
    // 之前是先 removeWhere 再判断 isBookmarked —— 此时已经被删掉了，
    // 判断必然为 false，于是又把它加回来，结果「书签永远取消不掉」。
    final existed = isBookmarked(b.fileId, b.chapterIndex, b.pageIndex);
    bookmarks.removeWhere((x) =>
        x.fileId == b.fileId && x.chapterIndex == b.chapterIndex && x.pageIndex == b.pageIndex);
    if (!existed) {
      bookmarks.add(b);
    }
    _writeJson('bookmarks.json', {'items': bookmarks.map((e) => e.toJson()).toList()});
    notifyListeners();
  }

  List<Bookmark> bookmarksOf(String fileId) =>
      bookmarks.where((b) => b.fileId == fileId).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  void removeBookmark(Bookmark b) {
    bookmarks.remove(b);
    _writeJson('bookmarks.json', {'items': bookmarks.map((e) => e.toJson()).toList()});
    notifyListeners();
  }

  /// 封面缓存目录（懒提取，按 file_id 命名）。
  Future<File> coverFile(String fileId) async {
    final d = Directory('${_dir.path}${Platform.pathSeparator}covers');
    if (!d.existsSync()) d.createSync(recursive: true);
    return File('${d.path}${Platform.pathSeparator}$fileId.img');
  }
}
