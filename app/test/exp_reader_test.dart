import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhu_ye_reader/models.dart';
import 'package:zhu_ye_reader/services/catalog.dart';
import 'package:zhu_ye_reader/services/covers.dart';
import 'package:zhu_ye_reader/services/epub.dart';
import 'package:zhu_ye_reader/services/library.dart';
import 'package:zhu_ye_reader/services/paginator.dart';
import 'package:zhu_ye_reader/services/store.dart';
import 'package:zhu_ye_reader/ui/reader.dart';

/// 交互实验：验证阅读页手势（点按翻页 / 点中间切工具栏 / 左右滑动）是否真的被响应。
/// 输出写到 data/exp-reader.txt（UTF-8），避免控制台乱码。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Store store;
  late ShelfBook book;

  setUpAll(() async {
    CoverCache.disabledForTest = true;
    await Catalog.load();
    final tmp = Directory.systemTemp.createTempSync('zhuye_exp_');
    store = Store.forTest(tmp, libraryRoot: r'E:\chinabook');
    final shelf = LibraryService.scan(r'E:\chinabook', Catalog.instance);
    final bySize = [...shelf]..sort((a, b) => a.sizeBytes.compareTo(b.sizeBytes));
    const typo = ReaderTypography(
      fontSize: 18,
      lineHeight: 1.8,
      textColor: Color(0xFF1B1B1B),
      mutedColor: Color(0xFF8A8A8A),
    );
    // 挑一本落地章节多页、且不是最后一章的书
    for (final b in bySize.take(10)) {
      final bk = await LibraryService.openBook(b);
      var land = 0;
      for (var i = 0; i < bk.chapters.length; i++) {
        if (bk.blocksOf(i).any((x) => x.kind != BlockKind.image)) {
          land = i;
          break;
        }
      }
      final pages =
          Paginator(width: 856, height: 1368, typo: typo).paginate(bk.blocksOf(land)).length;
      if (land < bk.chapters.length - 1 && pages >= 2) {
        book = b;
        return;
      }
    }
    book = bySize.first;
  });

  testWidgets('阅读页手势实验', (tester) async {
    const outPath = r'F:\asc_workspace\code\aicode\zhu-ye-dianzishu\data\exp-reader.txt';
    tester.view.physicalSize = const Size(900, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final buf = StringBuffer();
    buf.writeln('book=${book.fileId} ${book.title}');

    await tester.pumpWidget(MaterialApp(home: ReaderPage(book: book, store: store)));
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < 60000) {
      if (find.byType(PageView).evaluate().isNotEmpty) break;
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump();
    await tester.pump();

    List<String> ind() {
      final re = RegExp(r'^(\d+)/(\d+)$');
      return tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .where(re.hasMatch)
          .toList();
    }

    String snap() => '底栏=${ind()} AppBar=${find.byType(AppBar).evaluate().length} '
        '章末=${find.text('本章完').evaluate().length}';

    final r = tester.getRect(find.byType(PageView));
    buf.writeln('pageViewRect=$r');
    buf.writeln('起始           : ${snap()}');

    // ① 点右侧 → 应翻到第 2 页
    await tester.tapAt(Offset(r.right - 20, r.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    buf.writeln('点右侧(右20px) : ${snap()}');

    // ② 点左侧 → 应回第 1 页
    await tester.tapAt(Offset(r.left + 20, r.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    buf.writeln('点左侧(左20px) : ${snap()}');

    // ③ 点中间 → 工具栏应隐藏
    await tester.tapAt(r.center);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    buf.writeln('点中间         : ${snap()}（AppBar 应变 0）');

    // ④ 再点中间 → 恢复
    await tester.tapAt(r.center);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    buf.writeln('再点中间       : ${snap()}（AppBar 应变 1）');

    // ⑤ 触屏横向滑动 → 翻页
    await tester.drag(find.byType(PageView), const Offset(-700, 0), kind: PointerDeviceKind.touch);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    buf.writeln('左滑           : ${snap()}');

    await tester.drag(find.byType(PageView), const Offset(700, 0), kind: PointerDeviceKind.touch);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    buf.writeln('右滑           : ${snap()}');

    // ⑥ 滑块跳到最后 → 再点右侧 → 应出现「本章完」
    await tester.drag(find.byType(Slider), const Offset(4000, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    buf.writeln('滑块到末尾     : ${snap()}');
    await tester.tapAt(Offset(r.right - 20, r.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    buf.writeln('末尾再点右侧   : ${snap()}（应出现章末）');

    File(outPath).writeAsStringSync(buf.toString(), flush: true);
    // ignore: avoid_print
    print('written: $outPath');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
