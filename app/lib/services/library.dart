import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../models.dart';
import 'catalog.dart';
import 'epub.dart';

/// 书库：扫描本地目录，把文件还原成书架条目。
class LibraryService {
  /// 扫描书库目录，返回书架条目（按书名排序）。
  ///
  /// 识别两种文件：
  ///   `<file_id>.zip`  城通书包（内含 epub/mobi/azw3，阅读时抽 epub）
  ///   *.epub         直接放入的独立 epub
  static List<ShelfBook> scan(String root, Catalog catalog) {
    if (root.isEmpty) return const [];
    final dir = Directory(root);
    if (!dir.existsSync()) return const [];

    final out = <ShelfBook>[];
    final seen = <String>{};
    try {
      for (final e in dir.listSync(followLinks: false)) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        final lower = name.toLowerCase();
        String fileId;
        bool isZip;
        if (lower.endsWith('.zip')) {
          fileId = name.substring(0, name.length - 4);
          isZip = true;
        } else if (lower.endsWith('.epub')) {
          fileId = name.substring(0, name.length - 5);
          isZip = false;
        } else {
          continue;
        }
        if (!seen.add(fileId)) continue;
        final meta = catalog.byId(fileId);
        int size = 0;
        try {
          size = e.lengthSync();
        } catch (_) {}
        out.add(ShelfBook(
          fileId: fileId,
          path: e.path,
          title: (meta?.title.isNotEmpty ?? false) ? meta!.title : fileId,
          author: meta?.author ?? '',
          category: meta?.category ?? '未分类',
          sizeBytes: size,
          isZip: isZip,
        ));
      }
    } catch (_) {}
    out.sort((a, b) => a.title.compareTo(b.title));
    return out;
  }

  /// 从书包里取出 EPUB 字节（放 isolate，避免卡 UI）。
  static Future<Uint8List> epubBytesOf(ShelfBook b) async {
    if (!b.isZip) {
      return File(b.path).readAsBytes();
    }
    final path = b.path;
    return Isolate.run(() {
      final bytes = File(path).readAsBytesSync();
      return extractEpubFromPack(bytes);
    });
  }

  /// 打开一本书：读取 → 抽 epub → 解析结构。
  static Future<EpubBook> openBook(ShelfBook b) async {
    final bytes = await epubBytesOf(b);
    return openEpub(bytes);
  }

  /// 懒提取封面，结果返回原始字节（由 CoverCache 负责落盘）。
  static Future<Uint8List?> extractCoverBytes(ShelfBook b) async {
    try {
      final bytes = await epubBytesOf(b);
      return await Isolate.run(() {
        final book = openEpub(bytes);
        return book.cover;
      });
    } catch (_) {
      return null;
    }
  }
}
