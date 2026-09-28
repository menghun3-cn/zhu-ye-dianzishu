import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhu_ye_reader/models.dart';
import 'package:zhu_ye_reader/services/epub.dart';
import 'package:zhu_ye_reader/services/library.dart';
import 'package:zhu_ye_reader/services/paginator.dart';

/// 诊断工具（验收排障用）：把若干书包的解析结果写成 UTF-8 文本，便于外部查看。
/// 用法：flutter test test/probe_book_test.dart
///   或指定书：flutter test test/probe_book_test.dart --dart-define=ZIP=1357044529
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('dump 书包解析结果', () async {
    const libRoot = r'E:\chinabook';
    const outPath = r'F:\asc_workspace\code\aicode\zhu-ye-dianzishu\data\probe-book.txt';
    const only = String.fromEnvironment('ZIP');

    final dir = Directory(libRoot);
    if (!dir.existsSync()) {
      markTestSkipped('书库不存在');
      return;
    }
    var zips = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.zip'))
        .toList()
      ..sort((a, b) => a.lengthSync().compareTo(b.lengthSync()));
    if (only.isNotEmpty) {
      zips = zips.where((f) => f.path.contains(only)).toList();
    }
    zips = zips.take(4).toList();

    const typo = ReaderTypography(
      fontSize: 18,
      lineHeight: 1.8,
      textColor: Color(0xFF1B1B1B),
      mutedColor: Color(0xFF8A8A8A),
    );

    final buf = StringBuffer();
    for (final f in zips) {
      final name = f.uri.pathSegments.last;
      final fid = name.substring(0, name.length - 4);
      buf.writeln('===== $fid  ($name, ${f.lengthSync()} bytes) =====');
      try {
        final shelf = ShelfBook(
          fileId: fid,
          path: f.path,
          title: fid,
          author: '',
          category: '',
          sizeBytes: f.lengthSync(),
          isZip: true,
        );
        final b = await LibraryService.openBook(shelf);
        buf.writeln('title=${b.title} author=${b.author} chapters=${b.chapters.length} '
            'cover=${b.cover?.length ?? -1}B aspect=${b.coverAspect}');
        final n = b.chapters.length;
        final show = n < 8 ? n : 8;
        for (var i = 0; i < show; i++) {
          final bl = b.blocksOf(i);
          final kinds = <String, int>{};
          for (final x in bl) {
            kinds[x.kind.name] = (kinds[x.kind.name] ?? 0) + 1;
          }
          final joined = bl.map((x) => x.text).join().trim();
          buf.writeln('  ch$i href=${b.chapters[i].href} title=[${b.chapters[i].title}] '
              'blocks=${bl.length} chars=${joined.length} kinds=$kinds');
          buf.writeln('       head=[${joined.length > 70 ? joined.substring(0, 70) : joined}]');
        }
        var landing = 0;
        for (var i = 0; i < n; i++) {
          if (b.blocksOf(i).any((x) => x.kind != BlockKind.image)) {
            landing = i;
            break;
          }
        }
        final lb = b.blocksOf(landing);
        buf.writeln('  LANDING ch=$landing blocks=${lb.length} '
            'chars=${lb.map((x) => x.text).join().length}');
        for (final x in lb.take(6)) {
          buf.writeln('       - ${x.kind.name} len=${x.text.length} img=${x.image?.length ?? -1} '
              'aspect=${x.aspect} text=[${x.text.length > 40 ? x.text.substring(0, 40) : x.text}]');
        }
        final pages = Paginator(width: 856, height: 1364, typo: typo).paginate(lb);
        buf.writeln('  paginate(856x1364) -> ${pages.length} 页');
        for (var i = 0; i < (pages.length < 4 ? pages.length : 4); i++) {
          final p = pages[i];
          final txt = p.map((x) => x.text).join();
          buf.writeln('       page$i blocks=${p.length} chars=${txt.length} '
              'head=[${txt.length > 60 ? txt.substring(0, 60) : txt}]');
        }
      } catch (e, st) {
        buf.writeln('  EXCEPTION: $e');
        buf.writeln('$st');
      }
      buf.writeln('');
    }
    await File(outPath).writeAsString(buf.toString(), flush: true);
    // ignore: avoid_print
    print('written: $outPath');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
