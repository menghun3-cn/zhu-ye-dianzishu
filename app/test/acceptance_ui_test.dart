import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhu_ye_reader/main.dart';
import 'package:zhu_ye_reader/models.dart';
import 'package:zhu_ye_reader/services/catalog.dart';
import 'package:zhu_ye_reader/services/covers.dart';
import 'package:zhu_ye_reader/services/epub.dart';
import 'package:zhu_ye_reader/services/library.dart';
import 'package:zhu_ye_reader/services/paginator.dart';
import 'package:zhu_ye_reader/services/store.dart';
import 'package:zhu_ye_reader/ui/home.dart';
import 'package:zhu_ye_reader/ui/reader.dart';
import 'package:zhu_ye_reader/ui/settings_page.dart';

/// UI 验收：用真实书库数据驱动真实界面，逐项点击验证。
///
/// 三条硬约束（踩过的坑）：
///   1. widget test 用假时钟，真实文件 / Isolate / 平台通道异步必须放进 `runAsync` 推进，
///      否则永远等不到结果（表现为测试挂死到超时）。
///   2. `Catalog.load()` 走平台通道，只能在 `setUpAll` 里调。
///   3. `CoverCache` 的轮询在假时钟下会留下 pending timer，测试里必须关掉真实抽取。

const _libRoot = r'E:\chinabook';

Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  int timeoutMs = 120000,
  int stepMs = 200,
}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsedMilliseconds < timeoutMs) {
    if (done()) return;
    await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: stepMs)));
    // 必须带一个非零 duration：pump() 不带参数时**不会推进假时钟**，
    // 于是 `Future(...)` / `Timer(Duration.zero)` 这类调度永远不会执行
    // （书库扫描走的就是 `Future(() => LibraryService.scan(...))`）。
    await tester.pump(const Duration(milliseconds: 16));
  }
  if (done()) return;
  throw StateError('pumpUntil 超时（${timeoutMs}ms）');
}

String _plain(Text t) => t.data ?? t.textSpan?.toPlainText() ?? '';

/// 底栏的「当前页/总页」与「当前章/总章」（按树中出现顺序）。
List<String> _indicators(WidgetTester tester) {
  final re = RegExp(r'^(\d+)/(\d+)$');
  return tester.widgetList<Text>(find.byType(Text)).map(_plain).where(re.hasMatch).toList();
}

int _pageNo(WidgetTester tester) => int.parse(_indicators(tester)[0].split('/')[0]);
int _pageTotal(WidgetTester tester) => int.parse(_indicators(tester)[0].split('/')[1]);
int _chapNo(WidgetTester tester) => int.parse(_indicators(tester)[1].split('/')[0]);

/// PageView 的真实页索引。底栏那对「当前页/总页」把「本章完」那一屏排除在计数之外
/// （翻到它时页码停在最后一页不动），所以判断「翻页到底有没有生效」必须看真实索引。
int _pvIndex(WidgetTester tester) {
  final pv = tester.widget<PageView>(find.byType(PageView));
  final p = pv.controller?.page;
  return p == null ? (pv.controller?.initialPage ?? 0) : p.round();
}

Iterable<Text> _bodyTexts(WidgetTester tester) => tester.widgetList<Text>(
      find.descendant(of: find.byType(SelectionArea), matching: find.byType(Text)),
    );

String _renderedBody(WidgetTester tester) => _bodyTexts(tester).map(_plain).join();

/// 与 `reader.dart` 同一套落点判定（现在直接复用 services/epub.dart 的共享实现，
/// 避免「测试一套逻辑、reader 另一套」漂移）。
int _landingChapter(EpubBook book) => firstReadableChapter(book);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Store store;
  late List<ShelfBook> shelf;
  ShelfBook? readerBook;
  var readerBookPages = 0;
  ShelfBook? kbdBook;
  var kbdChapters = 0;

  setUpAll(() async {
    CoverCache.disabledForTest = true;
    await Catalog.load();
    final tmp = Directory.systemTemp.createTempSync('zhuye_accept_');
    store = Store.forTest(tmp, libraryRoot: _libRoot);
    shelf = LibraryService.scan(_libRoot, Catalog.instance);
    if (shelf.isEmpty) return;

    // 挑一本「落地章节有多页正文、且不是最后一章」的书：
    // 既要能验证翻页 / 排版对页数的影响，也要能验证章末页（末章没有章末页）。
    const typo = ReaderTypography(
      fontSize: 18,
      lineHeight: 1.8,
      textColor: Color(0xFF1B1B1B),
      mutedColor: Color(0xFF8A8A8A),
    );
    final bySize = [...shelf]..sort((a, b) => a.sizeBytes.compareTo(b.sizeBytes));
    final info = StringBuffer('候选（按体积升序，最多看 10 本）:\n');
    for (final b in bySize.take(10)) {
      final book = await LibraryService.openBook(b);
      final land = _landingChapter(book);
      final n = book.chapters.length;
      final pages =
          Paginator(width: 856, height: 1368, typo: typo).paginate(book.blocksOf(land)).length;
      info.writeln('${b.fileId} ${b.title} size=${b.sizeBytes} ch=$n land=$land '
          'landPages=$pages landChars=${book.blocksOf(land).map((x) => x.text).join().length}');
      final ok = land < n - 1 && pages >= 2;
      if (ok && pages > readerBookPages) {
        readerBook = b;
        readerBookPages = pages;
      }
      // 键盘用例要验「跨章切」和「目录自动定位到当前章」，得有一本章数足够多的书
      // （3 章的样本切两下就到头了，也测不出目录滚动）。
      if (pages >= 2 && n > kbdChapters) {
        kbdBook = b;
        kbdChapters = n;
      }
    }
    readerBook ??= bySize.first;
    kbdBook ??= readerBook;
    info.writeln('选中(阅读/排版): ${readerBook!.fileId} ${readerBook!.title} landPages=$readerBookPages');
    info.writeln('选中(键盘): ${kbdBook!.fileId} ${kbdBook!.title} ch=$kbdChapters');
    File(r'F:\asc_workspace\code\aicode\zhu-ye-dianzishu\data\ui-accept-info.txt')
        .writeAsStringSync(info.toString(), flush: true);
  });

  Future<void> bootApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ZhuYeReader(store: store));
    // 等真实扫库结束（书架上出现「N 本」）。注意不能用 '书架' 判断 —— 底部 tab 也叫「书架」，
    // 空书架时它同样匹配，会导致等在扫描完成之前。
    await pumpUntil(tester, () => find.text('${shelf.length} 本').evaluate().isNotEmpty);
  }

  Future<void> openReader(WidgetTester tester, ShelfBook book) async {
    tester.view.physicalSize = const Size(900, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: ReaderPage(book: book, store: store)));
    await pumpUntil(tester, () => find.byType(PageView).evaluate().isNotEmpty);
    // 分页发生在 layout 阶段，底栏要再多一帧才刷新出正确的总页数
    await tester.pump();
    await tester.pump();
  }

  // -------------------------------------------------------------------------
  // 书架页
  // -------------------------------------------------------------------------
  testWidgets('书架页：扫描 / 搜索 / 分类 / 列表网格切换 / 点书进阅读页', (tester) async {
    if (shelf.isEmpty) {
      markTestSkipped('书库为空');
      return;
    }
    await bootApp(tester);

    expect(find.text('书架 ${shelf.length}'), findsOneWidget);
    expect(find.text('${shelf.length} 本'), findsOneWidget);

    final named = shelf.where((b) => b.title != b.fileId).length;
    expect(named, greaterThan(shelf.length ~/ 2), reason: '超过一半的书没从名录还原出书名');

    final rows = find.descendant(of: find.byType(ShelfPage), matching: find.byType(ListTile));
    expect(rows, findsWidgets);

    // 搜索过滤
    final target = shelf.first;
    final kw = target.title.length >= 2 ? target.title.substring(0, 2) : target.title;
    final field = find.descendant(of: find.byType(ShelfPage), matching: find.byType(TextField));
    await tester.enterText(field, kw);
    await tester.pump();
    final counts = tester
        .widgetList<Text>(
            find.descendant(of: find.byType(ShelfPage), matching: find.byType(Text)))
        .map(_plain)
        .where((s) => s.endsWith(' 本'))
        .toList();
    expect(counts, isNotEmpty, reason: '书架没有显示过滤后的数量');
    final n = int.parse(counts.first.replaceAll(' 本', ''));
    expect(n, greaterThan(0), reason: '搜索「$kw」把书全滤掉了');
    expect(n, lessThan(shelf.length), reason: '搜索「$kw」没有起到过滤作用');

    await tester.enterText(field, '');
    await tester.pump();
    expect(find.text('${shelf.length} 本'), findsOneWidget);

    // 分类 chip
    final chips = find.byType(ChoiceChip);
    expect(chips, findsWidgets);
    expect(tester.widget<ChoiceChip>(chips.first).selected, isTrue, reason: '默认应选中「全部」');

    // 网格 / 列表
    await tester.tap(find.byTooltip('网格'));
    await tester.pump();
    expect(find.byType(GridView), findsOneWidget, reason: '切网格没生效');
    await tester.tap(find.byTooltip('列表'));
    await tester.pump();
    expect(find.byType(GridView), findsNothing, reason: '切回列表没生效');

    // 点书进阅读页
    await tester.tap(rows.first);
    await pumpUntil(tester, () => find.byType(ReaderPage).evaluate().isNotEmpty);
    expect(find.byType(ReaderPage), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // 阅读页：正文 / 翻页 / 工具栏 / 书签 / 章末 / 目录
  // -------------------------------------------------------------------------
  testWidgets('阅读页：首屏有正文 / 点击翻页 / 工具栏显隐 / 书签 / 章末 / 目录跳章', (tester) async {
    final book = readerBook;
    if (book == null) {
      markTestSkipped('书库为空');
      return;
    }
    store.setSettings(const ReaderSettings());
    await openReader(tester, book);

    // ① 首屏必须有正文，且渲染出来的字确实来自这本书
    final epub = (await tester.runAsync(() => LibraryService.openBook(book)))!;
    final rendered = _renderedBody(tester);
    expect(rendered.trim().length, greaterThan(80), reason: '首屏渲染出来的文字太少');

    final fullText = epub.blocksOf(_landingChapter(epub)).map((b) => b.text).join();
    var checked = 0, hit = 0;
    for (final w in _bodyTexts(tester)) {
      final s = _plain(w).trim();
      if (s.length < 8) continue;
      checked++;
      if (fullText.contains(s)) hit++;
    }
    expect(checked, greaterThan(0), reason: '正文区没找到成句的文字');
    expect(hit, checked, reason: '首屏有文本不是本书正文（$hit/$checked 命中）');

    // ② 底栏页码 / 章号
    expect(_indicators(tester).length, 2, reason: '底栏缺少「当前页/总页」或「当前章/总章」');
    expect(_pageNo(tester), 1, reason: '打开时应停在第 1 页');
    expect(_indicators(tester)[1].split('/')[1], '${epub.chapters.length}', reason: '总章数不对');
    final totalPages = _pageTotal(tester);
    expect(totalPages, greaterThan(1), reason: '选中的书落地章节只有 1 页，无法验证翻页');

    // ③ 点右侧下一页 / 点左侧上一页
    final r = tester.getRect(find.byType(PageView));
    await tester.tapAt(Offset(r.right - 20, r.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_pageNo(tester), 2, reason: '点右侧没有翻到第 2 页');

    await tester.tapAt(Offset(r.left + 20, r.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_pageNo(tester), 1, reason: '点左侧没有回到第 1 页');

    // ④ 点中间隐藏 / 恢复工具栏
    final r2 = tester.getRect(find.byType(PageView));
    expect(find.byType(AppBar), findsOneWidget);
    await tester.tapAt(r2.center);
    await tester.pump();
    expect(find.byType(AppBar), findsNothing, reason: '点中间没有隐藏工具栏');
    await tester.tapAt(r2.center);
    await tester.pump();
    expect(find.byType(AppBar), findsOneWidget, reason: '再点中间没有恢复工具栏');

    // ⑤ 书签加 / 取消
    final before = store.bookmarksOf(book.fileId).length;
    await tester.tap(find.byTooltip('书签'));
    await tester.pump();
    expect(store.bookmarksOf(book.fileId).length, before + 1, reason: '加书签没生效');
    await tester.tap(find.byTooltip('书签'));
    await tester.pump();
    expect(store.bookmarksOf(book.fileId).length, before, reason: '取消书签没生效');

    // ⑥ 章末页（落地章不是最后一章，所以后面还挂着一张「本章完」页）
    await tester.drag(find.byType(Slider), const Offset(4000, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    for (var i = 0; i < 3 && find.text('本章完').evaluate().isEmpty; i++) {
      await tester.drag(find.byType(PageView), const Offset(-800, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }
    expect(find.text('本章完'), findsOneWidget, reason: '章末没有出现「本章完」页');
    expect(find.textContaining('下一章 ·'), findsOneWidget, reason: '章末缺少「下一章」按钮');

    // ⑦ 目录抽屉：章数正确 + 跳章生效
    await tester.tap(find.byTooltip('目录'));
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsOneWidget, reason: '目录抽屉没打开');
    expect(find.textContaining('${epub.chapters.length} 章 ·'), findsOneWidget, reason: '抽屉章数不对');
    final tocTiles = find.descendant(of: find.byType(Drawer), matching: find.byType(ListTile));
    expect(tocTiles, findsWidgets);
    final chapBefore = _chapNo(tester);
    // 按 key 定位章节项：抽屉顶部还有「返回上一页」等非章节项，按索引点会点错。
    await tester.tap(find.byKey(const ValueKey('toc-2')));
    await tester.pumpAndSettle();
    await pumpUntil(tester, () => find.byType(PageView).evaluate().isNotEmpty);
    await tester.pump();
    await tester.pump();
    expect(_chapNo(tester), isNot(chapBefore), reason: '点目录里的章节没有跳转');
    expect(_pageNo(tester), 1, reason: '跳章后应回到该章第 1 页');
  });

  // -------------------------------------------------------------------------
  // 阅读页：PC 键盘快捷键
  // -------------------------------------------------------------------------
  testWidgets('阅读页：键盘快捷键（翻页 / 切章 / 首末页 / 目录自动定位）', (tester) async {
    final book = kbdBook;
    if (book == null) {
      markTestSkipped('书库为空');
      return;
    }
    store.setSettings(const ReaderSettings());
    // 进度归零：store 是全局的，上一条用例可能把阅读位置留在末章，
    // 那样「切下一章」根本无处可去（这不是缺陷，是测试前置没造好）。
    store.setProgress(book.fileId, 0, 0);
    await openReader(tester, book);

    final epub = (await tester.runAsync(() => LibraryService.openBook(book)))!;
    expect(epub.chapters.length, greaterThanOrEqualTo(4),
        reason: '键盘用例需要章数足够多的书（当前 ${epub.chapters.length} 章）');

    // 让外层键盘 Focus 拿到焦点（真机上首帧 autofocus 就是这个状态）
    tester.widget<Focus>(find.byKey(const ValueKey('reader-keys'))).focusNode!.requestFocus();
    await tester.pump();

    Future<void> press(LogicalKeyboardKey k) async {
      await tester.sendKeyEvent(k);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<void> ctrl(LogicalKeyboardKey k) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(k);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<void> settleChapter() async {
      await pumpUntil(tester, () => find.byType(PageView).evaluate().isNotEmpty);
      await tester.pump();
      await tester.pump();
    }

    // ① 翻页键
    final totalPages = _pageTotal(tester);
    expect(totalPages, greaterThan(1), reason: '选中的书落地章节只有 1 页，没法验证键盘翻页');
    expect(_pvIndex(tester), 0, reason: '打开时应停在第 1 页');

    await press(LogicalKeyboardKey.arrowRight);
    expect(_pvIndex(tester), 1, reason: '→ 没有翻到下一页');
    expect(_pageNo(tester), 2, reason: '→ 之后底栏页码没联动');

    await press(LogicalKeyboardKey.arrowLeft);
    expect(_pvIndex(tester), 0, reason: '← 没有翻回上一页');

    await press(LogicalKeyboardKey.space);
    expect(_pvIndex(tester), 1, reason: '空格没有翻页');

    await press(LogicalKeyboardKey.pageDown);
    expect(_pvIndex(tester), 2, reason: 'PageDown 没有翻页');

    await press(LogicalKeyboardKey.pageUp);
    expect(_pvIndex(tester), 1, reason: 'PageUp 没有回退一页');

    await press(LogicalKeyboardKey.end);
    expect(_pvIndex(tester), totalPages - 1, reason: 'End 没有跳到本章最后一页');
    expect(find.text('本章完'), findsNothing, reason: 'End 落到了「本章完」屏，而不是本章最后一页');

    await press(LogicalKeyboardKey.home);
    expect(_pvIndex(tester), 0, reason: 'Home 没有回到本章第 1 页');

    // 顺带把本章每一页都真实渲染一遍：任何一页布局溢出（页底文字被裁掉）
    // 都会让 widget 测试以异常收场，不需要额外断言。
    for (var i = 1; i < totalPages; i++) {
      await press(LogicalKeyboardKey.arrowRight);
      expect(_pvIndex(tester), i, reason: '逐页翻到第 ${i + 1} 页失败');
    }
    await press(LogicalKeyboardKey.home);

    // ② Ctrl+→ 进下一章（落在该章第 1 页）
    final c0 = _chapNo(tester);
    await ctrl(LogicalKeyboardKey.arrowRight);
    await settleChapter();
    final c1 = _chapNo(tester);
    expect(c1, greaterThan(c0), reason: 'Ctrl+→ 没有进下一章');
    expect(_pageNo(tester), 1, reason: '往后切章应停在目标章第 1 页');

    // ③ 字母键 n 也能切下一章
    await press(LogicalKeyboardKey.keyN);
    await settleChapter();
    expect(_chapNo(tester), greaterThan(c1), reason: 'n 没有切到下一章');

    // ④ Ctrl+← 回上一章。注意语义：切章落在**章首**（跟点目录跳章一致），
    //    只有「章首再往回翻页」才落在上一章的末页（读起来才连贯）。
    await ctrl(LogicalKeyboardKey.arrowLeft);
    await settleChapter();
    expect(_chapNo(tester), c1, reason: 'Ctrl+← 没有回到上一章');
    expect(_pageNo(tester), 1, reason: 'Ctrl+← 跳到上一章应停在该章第 1 页');

    // ⑤ 章首再按 ←（连续往回读）→ 落到上一章最后一页
    await press(LogicalKeyboardKey.arrowLeft);
    await settleChapter();
    expect(_chapNo(tester), lessThan(c1), reason: '章首按 ← 没有退到上一章');
    expect(_pageNo(tester), _pageTotal(tester), reason: '章首按 ← 应落在上一章的最后一页');

    // ⑥ Ctrl+Home / Ctrl+End 全书首末章
    await ctrl(LogicalKeyboardKey.home);
    await settleChapter();
    expect(_chapNo(tester), 1, reason: 'Ctrl+Home 没有回到第 1 章');
    await ctrl(LogicalKeyboardKey.end);
    await settleChapter();
    expect(_chapNo(tester), epub.chapters.length, reason: 'Ctrl+End 没有跳到最后一章');

    // ⑦ 目录抽屉打开后自动定位到当前章。
    // 跳到末章后，列表若没自动滚动，当前章的项根本不会被构建（懒加载），这里就会找不到。
    await tester.tap(find.byTooltip('目录'));
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsOneWidget, reason: '目录抽屉没打开');
    // 懒加载列表里只有滚进视口的项才会被构建。当前章能出现在已构建集合里、
    // 并且位置落在 Drawer 可视范围内，才算「打开目录就知道自己在哪一章」。
    // 用 key 取章节项（抽屉顶部还有「返回上一页」这类非章节项，不能按索引数）。
    final tocTilesFinder = find.descendant(
      of: find.byType(Drawer),
      matching: find.byWidgetPredicate((w) {
        final k = w.key;
        return w is ListTile && k is ValueKey<String> && k.value.startsWith('toc-');
      }),
    );
    final all = tester.widgetList<ListTile>(tocTilesFinder).toList();
    final selIdx = all.indexWhere((t) => t.selected);
    expect(selIdx, greaterThanOrEqualTo(0),
        reason: '目录里找不到高亮当前章 —— 自动定位没生效（共 ${epub.chapters.length} 章，末章还没被构建）');
    final dr = tester.getRect(find.byType(Drawer));
    final tr = tester.getRect(tocTilesFinder.at(selIdx));
    expect(tr.bottom, greaterThan(dr.top), reason: '当前章被滚到了视口上方之外');
    expect(tr.top, lessThan(dr.bottom), reason: '当前章被滚到了视口下方之外');
  });

  // -------------------------------------------------------------------------
  // 阅读页：返回书架
  // -------------------------------------------------------------------------
  testWidgets('阅读页：返回入口（左上返回键 / Alt+← / 抽屉返回项）都能回到书架', (tester) async {
    final book = readerBook;
    if (book == null) {
      markTestSkipped('书库为空');
      return;
    }
    store.setSettings(const ReaderSettings());
    tester.view.physicalSize = const Size(900, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 造出「书架 → 阅读页」两层路由，才能验证 pop 真的回到了书架。
    // 之前阅读页上没有任何返回入口：Scaffold 设了 drawer 就会把 AppBar 的 leading
    // 自动换成抽屉汉堡按钮，于是「返回」这个位置被「目录」占了。
    const shelfMarker = '书架占位页';
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (c) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(c).push(
                  MaterialPageRoute(builder: (_) => ReaderPage(book: book, store: store))),
              child: const Text(shelfMarker),
            ),
          ),
        ),
      ),
    ));

    Future<void> openBook() async {
      await tester.tap(find.text(shelfMarker));
      await tester.pump();
      await pumpUntil(tester, () => find.byType(PageView).evaluate().isNotEmpty);
      await tester.pump();
      await tester.pump();
    }

    // ① 左上角返回按钮
    await openBook();
    final backBtn = find.byTooltip('返回上一页（Alt + ←）');
    expect(backBtn, findsOneWidget,
        reason: '阅读页左上角没有返回按钮 —— 这正是「进了书出不来」的原因');
    await tester.tap(backBtn);
    await tester.pumpAndSettle();
    expect(find.text(shelfMarker), findsOneWidget, reason: '点返回按钮没回到书架');
    expect(find.byType(PageView), findsNothing, reason: '返回后阅读页还在');

    // ② Alt + ←（Windows 上通用的「后退」）
    await openBook();
    tester.widget<Focus>(find.byKey(const ValueKey('reader-keys'))).focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(find.text(shelfMarker), findsOneWidget, reason: 'Alt+← 没回到书架');

    // ③ 目录抽屉顶部的「返回上一页」
    await openBook();
    await tester.tap(find.byTooltip('目录'));
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsOneWidget, reason: '目录抽屉没打开');
    await tester.tap(find.descendant(of: find.byType(Drawer), matching: find.text('返回上一页')));
    await tester.pumpAndSettle();
    expect(find.text(shelfMarker), findsOneWidget, reason: '抽屉里的返回项没回到书架');
  });

  // -------------------------------------------------------------------------
  // 阅读页：排版
  // -------------------------------------------------------------------------
  testWidgets('阅读页：字号/行距会重新分页，主题切换改底色', (tester) async {
    final book = readerBook;
    if (book == null) {
      markTestSkipped('书库为空');
      return;
    }
    store.setSettings(const ReaderSettings());
    await openReader(tester, book);

    final pagesBefore = _pageTotal(tester);
    expect(pagesBefore, greaterThan(1));

    await tester.tap(find.byTooltip('排版'));
    await tester.pumpAndSettle();
    expect(find.text('字号'), findsOneWidget);
    expect(find.text('行距'), findsOneWidget);
    expect(find.text('主题'), findsOneWidget);
    final sheetSliders =
        find.descendant(of: find.byType(BottomSheet), matching: find.byType(Slider));
    expect(sheetSliders, findsNWidgets(2), reason: '排版面板里应有字号/行距两个滑杆');

    // 字号拉大 → 页数变多
    await tester.drag(sheetSliders.first, const Offset(600, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(store.settings.fontScale, greaterThan(1.0), reason: '字号没有变大');
    final pagesBigger = _pageTotal(tester);
    expect(pagesBigger, greaterThan(pagesBefore), reason: '字号变大后页数没增加');

    // 行距拉大
    final lhBefore = store.settings.lineHeight;
    await tester.drag(sheetSliders.at(1), const Offset(600, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(store.settings.lineHeight, greaterThan(lhBefore), reason: '行距没有变大');
    expect(_pageTotal(tester), greaterThanOrEqualTo(pagesBigger), reason: '行距变大后页数反而减少');

    // 主题切「黑」
    await tester.tap(find.text('黑'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(store.settings.theme, ReaderTheme.dark, reason: '主题没切到黑');
    expect(tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
        const Color(0xFF14161A), reason: '深色主题没有应用到页面底色');

    // 切回「白」
    await tester.tap(find.text('白'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(store.settings.theme, ReaderTheme.light);
    expect(tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
        const Color(0xFFFCFCFA), reason: '白色主题没有应用到页面底色');
  });

  // -------------------------------------------------------------------------
  // 名录页
  // -------------------------------------------------------------------------
  testWidgets('名录页：11348 本可检索 / 已入库标记 / 详情可跳读', (tester) async {
    if (shelf.isEmpty) {
      markTestSkipped('书库为空');
      return;
    }
    await bootApp(tester);

    expect(Catalog.instance.count, 11348);
    expect(Catalog.instance.categories.length, greaterThan(300));

    await tester.tap(find.text('名录'));
    await tester.pumpAndSettle();
    expect(find.text('输入关键词开始检索'), findsOneWidget);

    final entry = Catalog.instance.byId(shelf.first.fileId);
    expect(entry, isNotNull, reason: '本地书在名录里找不到条目');
    await tester.enterText(
      find.descendant(of: find.byType(CatalogPage), matching: find.byType(TextField)),
      entry!.title,
    );
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('命中 '), findsOneWidget);
    expect(find.text('已入库'), findsWidgets, reason: '本地已有的书没有「已入库」标记');
    expect(find.byType(ListTile), findsWidgets);

    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('文件 ID：'), findsOneWidget, reason: '详情弹层没打开');
    expect(find.text('开始阅读'), findsOneWidget, reason: '已入库的书没有「开始阅读」入口');

    await tester.tap(find.text('开始阅读'));
    await pumpUntil(tester, () => find.byType(ReaderPage).evaluate().isNotEmpty);
    expect(find.byType(ReaderPage), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // 设置页
  // -------------------------------------------------------------------------
  testWidgets('设置页：书库信息 / 名录统计 / 默认排版可改', (tester) async {
    if (shelf.isEmpty) {
      markTestSkipped('书库为空');
      return;
    }
    store.setSettings(const ReaderSettings());
    await bootApp(tester);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('书架 ${shelf.length} 本'), findsOneWidget);
    expect(find.textContaining('名录收录 ${Catalog.instance.count} 本'), findsOneWidget);
    expect(find.text(_libRoot), findsOneWidget, reason: '书库目录没有回填');

    final fsBefore = store.settings.fontScale;
    final settingsSliders =
        find.descendant(of: find.byType(SettingsPage), matching: find.byType(Slider));
    await tester.drag(settingsSliders.first, const Offset(500, 0));
    await tester.pump();
    expect(store.settings.fontScale, greaterThan(fsBefore), reason: '设置页改字号没生效');

    await tester.tap(find.text('黑').last);
    await tester.pump();
    expect(store.settings.theme, ReaderTheme.dark, reason: '设置页改主题没生效');
  });
}
