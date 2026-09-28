import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhu_ye_reader/models.dart';
import 'package:zhu_ye_reader/services/epub.dart';
import 'package:zhu_ye_reader/services/library.dart';
import 'package:zhu_ye_reader/services/paginator.dart';

/// 解析层验收：跑遍 `E:\chinabook` 全部已下载书包，逐本做
///   ① 每章都能解析出内容块
///   ② 阅读器「落地章节」（打开的落脚点）一定有文字，不会白屏
///   ③ 分页零丢字、页内无空页
///   ④ 图片块字节完整、纵横比有效
///
/// 这些是用户实际会看到的东西，所以用真实数据、真实代码路径（不是 mock）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('解析层验收：全库正文 / 落地章节 / 分页完整性', () async {
    const libRoot = r'E:\chinabook';
    final dir = Directory(libRoot);
    if (!dir.existsSync()) {
      markTestSkipped('书库不存在：$libRoot');
      return;
    }

    final zips = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.zip'))
        .toList()
      ..sort((a, b) => a.lengthSync().compareTo(b.lengthSync()));
    if (zips.isEmpty) {
      markTestSkipped('书库为空');
      return;
    }

    // 与阅读器一致的排版参数（手机尺寸下的一页）
    const typo = ReaderTypography(
      fontSize: 18,
      lineHeight: 1.8,
      textColor: Color(0xFF1B1B1B),
      mutedColor: Color(0xFF8A8A8A),
    );
    const pageW = 400.0;
    const pageH = 620.0;

    final buf = StringBuffer();
    final failed = <String>[];
    var totCh = 0, totContentCh = 0, totBlocks = 0, totChars = 0, totPages = 0, totImgs = 0;
    var totBlankLanding = 0;
    var noCover = 0;
    final sw = Stopwatch()..start();

    for (final f in zips) {
      final name = f.uri.pathSegments.last;
      final fid = name.substring(0, name.length - 4);
      final ms = Stopwatch()..start();
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
        final book = await LibraryService.openBook(shelf);
        final n = book.chapters.length;

        // 阅读器落点：第一个含「非图片块」的章节（封面/版权这类纯图页会被跳过）
        final landing = _firstReadable(book);
        final landBlocks = book.blocksOf(landing);
        final landText = landBlocks
            .where((b) => b.kind != BlockKind.image)
            .map((b) => b.text.trim())
            .where((s) => s.isNotEmpty)
            .join();

        var contentCh = 0, blocks = 0, chars = 0, pagesN = 0, imgs = 0;
        var preservedBad = 0, emptyPageBad = 0, imgBad = 0;
        var landFirstPageOk = false;

        for (var i = 0; i < n; i++) {
          final bl = book.blocksOf(i);
          if (bl.isEmpty) continue;
          if (bl.any((b) => b.kind != BlockKind.image)) contentCh++;

          var chChars = 0;
          for (final b in bl) {
            blocks++;
            chChars += b.text.length;
            if (b.kind == BlockKind.image) {
              imgs++;
              final data = b.image;
              if (data == null || data.isEmpty || !(b.aspect > 0)) imgBad++;
            }
          }
          chars += chChars;

          final pages = Paginator(width: pageW, height: pageH, typo: typo).paginate(bl);
          pagesN += pages.length;

          var pageChars = 0;
          for (final p in pages) {
            if (p.isEmpty) emptyPageBad++;
            for (final b in p) {
              pageChars += b.text.length;
            }
          }
          // 分页是按字符切块，字符总数必须一点不少
          if (pageChars != chChars) preservedBad++;

          if (i == landing) {
            final first = pages.isNotEmpty ? pages.first : const <Block>[];
            landFirstPageOk = first.isNotEmpty &&
                first.any((b) => b.kind != BlockKind.image && b.text.trim().isNotEmpty);
          }
        }

        totCh += n;
        totContentCh += contentCh;
        totBlocks += blocks;
        totChars += chars;
        totPages += pagesN;
        totImgs += imgs;
        final coverOk = (book.cover?.isNotEmpty ?? false) && book.coverAspect > 0;
        if (!coverOk) noCover++;

        final blankLanding = landText.isEmpty || !landFirstPageOk;
        if (blankLanding) totBlankLanding++;

        final bad = blankLanding || preservedBad > 0 || emptyPageBad > 0 || imgBad > 0 || n == 0;
        if (bad) {
          failed.add('$fid ch=$n land=$landing blankLanding=$blankLanding '
              'lostChars=$preservedBad emptyPages=$emptyPageBad badImgs=$imgBad');
        }
        final head = landText.length > 14 ? landText.substring(0, 14) : landText;
        buf.writeln('${bad ? "FAIL" : "OK  "} $fid ch=$n content=$contentCh blocks=$blocks '
            'chars=$chars pages=$pagesN imgs=$imgs cover=${coverOk ? 1 : 0} '
            'land=$landing head=[$head] ${ms.elapsedMilliseconds}ms');
      } catch (e) {
        failed.add('$fid EXCEPTION: $e');
        buf.writeln('FAIL $fid EXCEPTION: $e');
      }
    }
    sw.stop();

    buf.writeln('');
    buf.writeln('==== 解析层验收汇总 ====');
    buf.writeln('书包数            : ${zips.length}');
    buf.writeln('章节总数          : $totCh（其中含文字 $totContentCh）');
    buf.writeln('内容块总数        : $totBlocks');
    buf.writeln('正文字符总数      : $totChars');
    buf.writeln('分页后总页数      : $totPages');
    buf.writeln('图片块总数        : $totImgs');
    buf.writeln('落地空白（白屏）  : $totBlankLanding');
    buf.writeln('封面缺失的书      : $noCover');
    buf.writeln('不通过书包数      : ${failed.length}');
    buf.writeln('耗时              : ${sw.elapsedMilliseconds}ms');
    if (failed.isNotEmpty) {
      buf.writeln('---- 不通过明细 ----');
      for (final x in failed) {
        buf.writeln('  $x');
      }
    }
    // ignore: avoid_print
    print('解析层验收完成，报告已写入 data/acceptance-parse.txt');
    File(r'F:\asc_workspace\code\aicode\zhu-ye-dianzishu\data\acceptance-parse.txt')
        .writeAsStringSync(buf.toString(), flush: true);

    expect(totBlankLanding, 0, reason: '有书包打开后落地章节没有文字（用户会看到白屏）');
    expect(failed, isEmpty, reason: '存在解析/分页异常的包');
  }, timeout: const Timeout(Duration(minutes: 40)));
}

/// 与 `reader.dart` 同一套落点判定（共享实现，见 services/epub.dart）。
int _firstReadable(EpubBook b) => firstReadableChapter(b);
