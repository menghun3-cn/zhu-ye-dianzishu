import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhu_ye_reader/models.dart';
import 'package:zhu_ye_reader/services/catalog.dart';
import 'package:zhu_ye_reader/services/library.dart';
import 'package:zhu_ye_reader/services/store.dart';
import 'package:zhu_ye_reader/ui/reader.dart';

/// 诊断：把 ReaderPage 首屏真实渲染出来的东西 dump 成 UTF-8 文本。
///
/// 注意：Catalog.load() 走平台通道，只能在 setUpAll（假时钟之外）调用。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Store store;
  late ShelfBook book;

  setUpAll(() async {
    await Catalog.load();
    final tmp = Directory.systemTemp.createTempSync('zhuye_dump_');
    store = Store.forTest(tmp, libraryRoot: r'E:\chinabook');
    final shelf = LibraryService.scan(r'E:\chinabook', Catalog.instance);
    final bySize = [...shelf]..sort((a, b) => a.sizeBytes.compareTo(b.sizeBytes));
    book = bySize.first;
  });

  testWidgets('dump 阅读页首屏', (tester) async {
    const outPath = r'F:\asc_workspace\code\aicode\zhu-ye-dianzishu\data\dump-reader.txt';

    tester.view.physicalSize = const Size(900, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final buf = StringBuffer();
    buf.writeln('book=${book.fileId} title=${book.title} size=${book.sizeBytes}');

    await tester.pumpWidget(MaterialApp(home: ReaderPage(book: book, store: store)));
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < 60000) {
      if (find.byType(PageView).evaluate().isNotEmpty) break;
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
    }
    // 分页发生在 layout 阶段，底栏要再多一帧才会刷新出正确的总页数
    await tester.pump();
    await tester.pump();
    buf.writeln('PageView=${find.byType(PageView).evaluate().length} '
        'SelectionArea=${find.byType(SelectionArea).evaluate().length} '
        'Progress=${find.byType(CircularProgressIndicator).evaluate().length} '
        'Texts=${find.byType(Text).evaluate().length} RichTexts=${find.byType(RichText).evaluate().length} '
        'elapsed=${sw.elapsedMilliseconds}ms');

    final pw = find.byType(PageView);
    if (pw.evaluate().isNotEmpty) {
      buf.writeln('pageViewRect=${tester.getRect(pw)}');
      for (final p in tester.widgetList<PageView>(pw)) {
        buf.writeln('itemCount=${p.childrenDelegate.estimatedChildCount}');
      }
    }
    buf.writeln('viewPhysical=${tester.view.physicalSize} dpr=${tester.view.devicePixelRatio}');
    final mqs = find.byType(MediaQuery);
    if (mqs.evaluate().isNotEmpty) {
      final d = tester.widget<MediaQuery>(mqs.first).data;
      buf.writeln('mq size=${d.size} dpr=${d.devicePixelRatio} padding=${d.padding} '
          'viewInsets=${d.viewInsets} viewPadding=${d.viewPadding}');
    }
    buf.writeln('scaffoldRect=${tester.getRect(find.byType(Scaffold).first)}');
    buf.writeln('appBarRect=${tester.getRect(find.byType(AppBar))}');
    buf.writeln('sliderRect=${tester.getRect(find.byType(Slider))}');
    buf.writeln('sliderAncestors:');
    var depth = 0;
    find.byType(Slider).evaluate().first.visitAncestorElements((e) {
      final ro = e.renderObject;
      final sz = (ro is RenderBox && ro.hasSize) ? ro.size.toString() : '?';
      buf.writeln('  [$depth] ${e.widget.runtimeType} size=$sz');
      depth++;
      return depth < 10;
    });

    var i = 0;
    for (final t in tester.widgetList<Text>(find.byType(Text))) {
      final s = t.data ?? t.textSpan?.toPlainText() ?? '';
      buf.writeln('Text[$i] len=${s.length} isData=${t.data != null} '
          '[${s.length > 60 ? s.substring(0, 60) : s}]');
      i++;
      if (i > 40) break;
    }

    File(outPath).writeAsStringSync(buf.toString(), flush: true);
    // ignore: avoid_print
    print('written: $outPath');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
