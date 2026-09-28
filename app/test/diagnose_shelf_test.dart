import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhu_ye_reader/models.dart';
import 'package:zhu_ye_reader/services/library.dart';

/// 临时诊断：跑遍真实书库，逐本打印章节数 / 正文块产出情况。
/// 目的：定位「打开书后正文空白」是解析层问题还是渲染层问题。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('全库解析诊断', () async {
    final dir = Directory(r'E:\chinabook');
    if (!dir.existsSync()) {
      markTestSkipped('书库不存在');
      return;
    }
    final zips = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.zip'))
        .toList()
      ..sort((a, b) => a.lengthSync().compareTo(b.lengthSync()));

    final buf = StringBuffer();
    var bad = 0;
    for (final f in zips) {
      final name = f.uri.pathSegments.last;
      final fid = name.substring(0, name.length - 4);
      try {
        final b = ShelfBook(
          fileId: fid,
          path: f.path,
          title: fid,
          author: '',
          category: '',
          sizeBytes: f.lengthSync(),
          isZip: true,
        );
        final book = await LibraryService.openBook(b);
        final chN = book.chapters.length;
        var nonEmpty = 0;
        var chars = 0;
        final limit = chN < 5 ? chN : 5;
        for (var i = 0; i < limit; i++) {
          final bl = book.blocksOf(i);
          if (bl.isNotEmpty) nonEmpty++;
          chars += bl.map((x) => x.text).join().length;
        }
        String chInfo = '-';
        if (chN > 0) {
          final href = book.chapters[0].href;
          final raw = book.rawOf(href);
          chInfo = 'href=$href rawLen=${raw?.length ?? -1} b0=${book.blocksOf(0).length}';
        }
        final head = book.blocksOf(0).take(2).map((x) => x.text).join('/');
        final h = head.length > 40 ? head.substring(0, 40) : head;
        final empty = chN == 0 || nonEmpty == 0;
        if (empty) bad++;
        buf.writeln(
            '$name ch=$chN nonEmpty=$nonEmpty/$limit chars=$chars ${empty ? "<<<EMPTY" : ""}\n'
            '    $chInfo\n'
            '    head=[$h]');
      } catch (e) {
        bad++;
        buf.writeln('$name EXCEPTION: $e');
      }
    }
    buf.writeln('==== TOTAL=${zips.length}  BAD=$bad ====');
    // ignore: avoid_print
    print(buf.toString());
  }, timeout: const Timeout(Duration(minutes: 30)));
}
