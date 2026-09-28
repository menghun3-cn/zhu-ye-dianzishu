import 'package:flutter/foundation.dart';

import '../models.dart';
import 'library.dart';
import 'store.dart';

/// 封面缓存：先查磁盘缓存，没有就异步从书包里抽，抽到后落盘。
/// 同一本书的并发请求会被去重，避免滚动时反复解压 22MB 的 zip。
class CoverCache {
  static final Map<String, Uint8List?> _mem = {};
  static final Set<String> _inflight = {};

  /// 仅测试用：关掉真实抽取。
  /// widget test 的时钟是假时钟，这里的文件 I/O 不会完成，还会留下一堆 pending timer
  /// （`A Timer is still pending even after the widget tree was disposed`）。
  /// 打开后 get() 只读内存缓存并立即返回。
  @visibleForTesting
  static bool disabledForTest = false;

  static Uint8List? peek(String fileId) => _mem[fileId];

  static Future<Uint8List?> get(Store store, ShelfBook book) async {
    if (disabledForTest) return _mem[book.fileId];
    if (_mem.containsKey(book.fileId)) return _mem[book.fileId];
    if (_inflight.contains(book.fileId)) {
      // 已有请求在跑，轮询等待（简单可靠，避免额外依赖）
      for (var i = 0; i < 200; i++) {
        await Future.delayed(const Duration(milliseconds: 60));
        if (!_inflight.contains(book.fileId)) return _mem[book.fileId];
      }
      return null;
    }
    _inflight.add(book.fileId);
    try {
      final f = await store.coverFile(book.fileId);
      if (await f.exists()) {
        final d = await f.readAsBytes();
        if (d.isNotEmpty) {
          _mem[book.fileId] = d;
          return d;
        }
      }
      final bytes = await LibraryService.extractCoverBytes(book);
      if (bytes != null && bytes.isNotEmpty) {
        try {
          await f.writeAsBytes(bytes, flush: true);
        } catch (_) {}
      }
      _mem[book.fileId] = bytes;
      return bytes;
    } catch (_) {
      _mem[book.fileId] = null;
      return null;
    } finally {
      _inflight.remove(book.fileId);
    }
  }
}
