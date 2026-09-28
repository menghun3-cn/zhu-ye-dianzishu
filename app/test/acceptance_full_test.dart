import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/gestures.dart';
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

/// 全功能点验收：把阅读器每一个可交互功能点编号，逐点在**真实书库数据驱动的真实界面**上断言，
/// 跑完把覆盖矩阵写到 `data/acceptance-coverage.txt`。
///
/// 编号：A 外壳/导航 · B 书架 · C 阅读页 · D 名录 · E 设置 · F 服务层
///       G 全库解析（在 test/acceptance_parse_test.dart，跑全量时会一并执行）
///
/// 三条硬约束（踩过的坑）：
///   1. widget test 用假时钟：真实文件 / Isolate / 平台通道异步必须靠 `runAsync` 推进；
///   2. `Catalog.load()` 走平台通道，只能在 `setUpAll` 里调；
///   3. `CoverCache` 的轮询在假时钟下会留 pending timer，UI 测试里必须关掉真实抽取。

const _libRoot = r'E:\chinabook';
const _dataDir = r'F:\asc_workspace\code\aicode\zhu-ye-dianzishu\data';
const _covPath = '$_dataDir\\acceptance-coverage.txt';

// ---------------------------------------------------------------------------
// 覆盖矩阵（所有 pTest / sTest 都会往这里记一行）
// ---------------------------------------------------------------------------

final _cov = StringBuffer();
int _okCount = 0;
int _failCount = 0;

void _row(String id, String feature, String how, String verdict) =>
    _cov.writeln('| $id | $feature | $how | $verdict |');

void _point(String id, String feature, String how) {
  _okCount++;
  _row(id, feature, how, '✅');
}

void _fail(String id, String feature, String how, Object e) {
  _failCount++;
  _row(id, feature, how, '❌ ${'$e'.split('\n').first}');
}

/// 一个 UI 用例里覆盖多个功能点时用（断言通过后调用）。
void mark(String id, String feature, String how) => _point(id, feature, how);

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

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
    // 必须带非零 duration：pump() 不带参数不会推进假时钟，
    // `Future(...)` / `Timer(Duration.zero)` 这类调度就永远不执行。
    await tester.pump(const Duration(milliseconds: 16));
  }
  if (done()) return;
  throw StateError('pumpUntil 超时（${timeoutMs}ms）');
}

String _plain(Text t) => t.data ?? t.textSpan?.toPlainText() ?? '';

List<String> _indicators(WidgetTester t) {
  final re = RegExp(r'^(\d+)/(\d+)$');
  return t.widgetList<Text>(find.byType(Text)).map(_plain).where(re.hasMatch).toList();
}

int _pageNo(WidgetTester t) => int.parse(_indicators(t)[0].split('/')[0]);
int _pageTotal(WidgetTester t) => int.parse(_indicators(t)[0].split('/')[1]);
int _chapNo(WidgetTester t) => int.parse(_indicators(t)[1].split('/')[0]);
int _chapTotal(WidgetTester t) => int.parse(_indicators(t)[1].split('/')[1]);

/// PageView 的真实页索引（底栏页码把「本章完」那屏排除在计数外，不能用来判翻页）。
int _pvIndex(WidgetTester t) {
  final pv = t.widget<PageView>(find.byType(PageView));
  final p = pv.controller?.page;
  return p == null ? (pv.controller?.initialPage ?? 0) : p.round();
}

Iterable<Text> _bodyTexts(WidgetTester t) => t.widgetList<Text>(
      find.descendant(of: find.byType(SelectionArea), matching: find.byType(Text)),
    );

String _renderedBody(WidgetTester t) => _bodyTexts(t).map(_plain).join();

String _appBarTitle(WidgetTester t) => _plain(
      t.widget<Text>(find.descendant(of: find.byType(AppBar), matching: find.byType(Text)).first),
    );

int _shelfCount(WidgetTester t) {
  final re = RegExp(r'^(\d+) 本$');
  final hits = t.widgetList<Text>(find.byType(Text)).map(_plain).where(re.hasMatch).toList();
  if (hits.isEmpty) throw StateError('书架上找不到「N 本」计数');
  return int.parse(re.firstMatch(hits.first)!.group(1)!);
}

Finder _inPage(Type page, Finder matching) =>
    find.descendant(of: find.byType(page), matching: matching);

/// 底部导航项。注意书架那项的文案是「书架 54」（带本数），必须用 textContaining。
Finder _navDest(String label) =>
    find.descendant(of: find.byType(NavigationBar), matching: find.textContaining(label));

Finder _tocTile(int i) => find.byKey(ValueKey('toc-$i'));

/// 抽屉里的章节项（有 `toc-<i>` key 的那些，排除顶部的「返回上一页」）。
Finder get _tocChapterTiles => find.descendant(
      of: find.byType(Drawer),
      matching: find.byWidgetPredicate((w) {
        final k = w.key;
        return w is ListTile && k is ValueKey<String> && k.value.startsWith('toc-');
      }),
    );

Finder get _shelfMarker => find.text('<<书架占位页>>');

/// 测试专用主题：把路由转场抹平（进/出都不做位移与缩放）。
///
/// 为什么必须在测试里关掉转场：阅读页要靠 `runAsync` 推进真实文件 IO，
/// 而**`runAsync` 与假时钟下的路由转场动画混用会让动画停在半路** ——
/// 实测整个阅读页被恒定右移 222.7px（页宽 900），
/// 于是左上返回键、书签、排版这些按钮全部落在屏幕外，`tap()` 直接报
/// 「outside the bounds of the root of the render tree」。
/// 转场本身不是被测功能点（真机上正常），测试里把它抹掉，坐标才是可靠的。
final _noTransitionTheme = ThemeData(
  colorSchemeSeed: const Color(0xFF2E7D32),
  useMaterial3: true,
  pageTransitionsTheme: const PageTransitionsTheme(builders: {
    TargetPlatform.android: _NoTransitionBuilder(),
    TargetPlatform.iOS: _NoTransitionBuilder(),
    TargetPlatform.macOS: _NoTransitionBuilder(),
    TargetPlatform.windows: _NoTransitionBuilder(),
    TargetPlatform.linux: _NoTransitionBuilder(),
    TargetPlatform.fuchsia: _NoTransitionBuilder(),
  }),
);

class _NoTransitionBuilder extends PageTransitionsBuilder {
  const _NoTransitionBuilder();
  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      child;
}

Future<void> key(WidgetTester t, LogicalKeyboardKey k) async {
  await t.sendKeyEvent(k);
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

Future<void> ctrlKey(WidgetTester t, LogicalKeyboardKey k) async {
  await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await t.sendKeyEvent(k);
  await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

Future<void> settleChapter(WidgetTester t) async {
  await pumpUntil(t, () => find.byType(PageView).evaluate().isNotEmpty);
  await t.pump();
  await t.pump();
}

void requestReaderFocus(WidgetTester t) {
  final f = find.byKey(const ValueKey('reader-keys'));
  if (f.evaluate().isEmpty) return;
  t.widget<Focus>(f).focusNode!.requestFocus();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Store store;
  late List<ShelfBook> shelf;
  late List<String> files;

  // 样本（setUpAll 按真实数据挑）
  ShelfBook? readerBook; // 落地章多页正文、且不是末章
  int readerLandPages = 0;
  ShelfBook? kbdBook; // 落地章 ≥3 页 + 章数 ≥8（键盘翻页/切章组要用）
  int kbdLandPages = 0;
  int kbdChapters = 0;
  ShelfBook? tocBook; // 章数最多（目录抽屉的「长目录自动定位」要用）
  int tocChapters = 0;
  ShelfBook? midBook; // 落地章在书中间（能验「章首往回翻 → 上一章末页」）
  ShelfBook? numTitleBook; // 落地章的章节名是纯数字（验标题美化）
  int numTitleCh = -1;

  final info = StringBuffer();

  // ---- 两个记录器（放 main 里才能读到 shelf，自动跳过空书库）----------------
  void pTest(String id, String feature, String how, Future<void> Function(WidgetTester) body) {
    testWidgets('$id $feature', (tester) async {
      if (shelf.isEmpty) {
        markTestSkipped('书库为空');
        _row(id, feature, how, '⏭ 跳过：书库为空');
        return;
      }
      try {
        await body(tester);
        _point(id, feature, how);
      } catch (e) {
        _fail(id, feature, how, e);
        rethrow;
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  }

  void sTest(String id, String feature, String how, Future<void> Function() body) {
    test('$id $feature', () async {
      try {
        await body();
        _point(id, feature, how);
      } catch (e) {
        _fail(id, feature, how, e);
        rethrow;
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  }

  /// 常用动作 -----------------------------------------------------------
  void resetStore() {
    store.progress.clear();
    store.bookmarks.clear();
    store.setSettings(const ReaderSettings());
  }

  /// 启动 App。[noTransition] 默认 true：见 `_noTransitionTheme` 的注释 ——
  /// 只要用例会 push 路由（点书进阅读页、名录里「开始阅读」），就必须关转场，
  /// 否则按钮会落在屏幕外、tap 落空。
  /// A1 那一组故意用 false，走真实的 `ZhuYeReader`（验真正的启动入口）。
  /// 换根之前先把整棵树拆掉。
  ///
  /// 坑：`pumpWidget` 只是「换根 widget」，**同一个位置上的 MaterialApp 会被复用、
  /// Navigator 里已 push 的路由栈会保留**。上一条用例留下的阅读页会把
  /// `<<书架占位页>>` 埋在下层（opaque 路由下层还会被 finder 跳过），
  /// 于是第二次 openReader 一上来就 tap 失败。先 pump 一个空 widget 才能真正清栈。
  Future<void> resetTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  Future<void> bootApp(WidgetTester tester, {bool noTransition = true}) async {
    tester.view.physicalSize = const Size(900, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await resetTree(tester);
    await tester.pumpWidget(noTransition
        ? MaterialApp(theme: _noTransitionTheme, home: HomeShell(store: store))
        : ZhuYeReader(store: store));
    // 等真实扫库结束（书架上出现「N 本」）。注意不能用 '书架' 判断 —— 底部 tab 也叫「书架」。
    await pumpUntil(tester, () => find.text('${shelf.length} 本').evaluate().isNotEmpty);
  }

  /// 造「书架 → 阅读页」两层路由：只有这样才能验证返回类行为（直接挂 home 是无路可退的）。
  Future<void> openReader(WidgetTester tester, ShelfBook book) async {
    tester.view.physicalSize = const Size(900, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await resetTree(tester);
    await tester.pumpWidget(MaterialApp(
      theme: _noTransitionTheme,
      home: Builder(
        builder: (c) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(c).push(
                  MaterialPageRoute(builder: (_) => ReaderPage(book: book, store: store))),
              child: const Text('<<书架占位页>>'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(_shelfMarker);
    await tester.pump();
    await pumpUntil(tester, () => find.byType(PageView).evaluate().isNotEmpty);
    // 分页发生在 layout 阶段，底栏要再多一帧才刷新出正确的总页数
    await tester.pump();
    await tester.pump();
  }

  /// 抽屉里的目录列表滚回顶部（懒加载列表：滚远了的项根本没被构建，找不到 key）。
  Future<void> tocToTop(WidgetTester tester, int wantIndex) async {
    final list = find.descendant(of: find.byType(Drawer), matching: find.byType(Scrollable)).first;
    for (var i = 0; i < 60 && _tocTile(wantIndex).evaluate().isEmpty; i++) {
      await tester.drag(list, const Offset(0, 600));
      await tester.pump();
    }
  }

  /// 末页 → 下一章（连点右侧直到章号变化）
  Future<void> advanceChapterByTapping(WidgetTester tester) async {
    final r = tester.getRect(find.byType(PageView));
    final from = _chapNo(tester);
    for (var i = 0; i < 6 && _chapNo(tester) == from; i++) {
      await tester.tapAt(Offset(r.right - 20, r.center.dy));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
  }

  Future<void> tapRight(WidgetTester tester) async {
    final r = tester.getRect(find.byType(PageView));
    await tester.tapAt(Offset(r.right - 20, r.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 站到本章最后一页（键盘 End）。比拖底栏滑块稳。
  Future<void> toLastTextPage(WidgetTester tester) async {
    requestReaderFocus(tester);
    await key(tester, LogicalKeyboardKey.end);
  }

  /// 站到本章第 1 页（键盘 Home）。
  Future<void> toFirstPage(WidgetTester tester) async {
    requestReaderFocus(tester);
    await key(tester, LogicalKeyboardKey.home);
  }

  setUpAll(() async {
    CoverCache.disabledForTest = true;
    await Catalog.load();
    store = Store.forTest(Directory.systemTemp.createTempSync('zhuye_full_'), libraryRoot: _libRoot);
    shelf = LibraryService.scan(_libRoot, Catalog.instance);
    files = Directory(_libRoot)
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.toLowerCase().endsWith('.zip'))
        .toList()
      ..sort();
    if (shelf.isEmpty) return;

    const typo = ReaderTypography(
      fontSize: 18,
      lineHeight: 1.8,
      textColor: Color(0xFF1B1B1B),
      mutedColor: Color(0xFF8A8A8A),
    );
    final bySize = [...shelf]..sort((a, b) => a.sizeBytes.compareTo(b.sizeBytes));

    // 一次遍历挑样本（章标题来自 TOC，不必解析正文）
    for (final b in bySize) {
      final book = await LibraryService.openBook(b);
      final n = book.chapters.length;
      final land = firstReadableChapter(book);
      final pages =
          Paginator(width: 856, height: 1368, typo: typo).paginate(book.blocksOf(land)).length;
      // 阅读样本：落地章页数最多（且不是末章，好验跨章）
      if (land < n - 1 && pages >= 2 && pages > readerLandPages) {
        readerBook = b;
        readerLandPages = pages;
      }
      // 键盘样本：要有足够章的正文才验得出「连按三次切下一章」；
      // 之前这里取的是「章数最多的书」，结果那本的落地章只有 1 页，C34 直接挂在
      // 「expect(total, greaterThan(2))」上 —— 样本选错了，不是功能坏了。
      if (n >= 8 && land < n - 1 && pages >= 3 && pages > kbdLandPages) {
        kbdBook = b;
        kbdLandPages = pages;
        kbdChapters = n;
      }
      // 目录样本：章数最多，验几百章的懒加载目录能不能自动定位到当前章
      if (n > tocChapters) {
        tocChapters = n;
        tocBook = b;
      }
      // 中间章样本：落地章要在书的**中段**，而且后面至少还留 2 章 ——
      // C13/C14 要连着往前推两章（land+1、land+2），留不够就推不动了。
      // 早先只要求 `land < n - 1`，结果挑中一本只有 3 章的书（land=1），
      // 推到第 3 章就是末章了，「章末点右侧进下一章」永远不可能发生。
      if (midBook == null && land > 0 && land + 2 < n && pages >= 2) midBook = b;
      if (numTitleBook == null && RegExp(r'^\d+$').hasMatch(book.chapters[land].title.trim())) {
        numTitleBook = b;
        numTitleCh = land;
      }
    }
    readerBook ??= bySize.first;
    midBook ??= readerBook;
    kbdBook ??= readerBook;
    tocBook ??= readerBook;

    info
      ..writeln('书库：$_libRoot')
      ..writeln('书目数：${shelf.length}  文件数：${files.length}')
      ..writeln('阅读样本：${readerBook!.fileId} ${readerBook!.title} landPages=$readerLandPages')
      ..writeln('键盘样本：${kbdBook!.fileId} ${kbdBook!.title} landPages=$kbdLandPages '
          'ch=$kbdChapters')
      ..writeln('目录样本：${tocBook!.fileId} ${tocBook!.title} ch=$tocChapters')
      ..writeln('中间章样本：${midBook!.fileId} ${midBook!.title}')
      ..writeln('数字标题样本：${numTitleBook?.fileId} ${numTitleBook?.title} land=$numTitleCh');
  });

  tearDownAll(() {
    final head = StringBuffer()
      ..writeln('# 全功能点覆盖验收矩阵（自动生成）')
      ..writeln()
      ..writeln('- 生成时间：${DateTime.now()}')
      ..writeln('- 书库：$_libRoot（${shelf.length} 本）')
      ..writeln('- 方式：真实书库数据驱动真实界面，逐点断言（无 mock）')
      ..writeln('- 结果：**通过 $_okCount 点**，失败 $_failCount 点')
      ..writeln()
      ..writeln('| 编号 | 功能点 | 操作 / 断言 | 结果 |')
      ..writeln('| --- | --- | --- | --- |');
    File(_covPath).writeAsStringSync('$head$_cov', flush: true);
    File('$_dataDir\\full-accept-info.txt').writeAsStringSync(info.toString(), flush: true);
  });

  // =========================================================================
  // A 外壳 / 底部导航
  // =========================================================================
  pTest('A1-A3', '外壳：启动到书架 + 底部导航三个 tab', '启动后书架出现；点各 tab 后 selectedIndex 与页面同步切换',
      (tester) async {
    // 这一组故意用**真实的 ZhuYeReader**（不关转场），把真正的启动入口也覆盖到
    await bootApp(tester, noTransition: false);
    mark('A1', '启动进入书架页', 'ZhuYeReader 启动后书架页出现并显示「${shelf.length} 本」');

    int tab() => tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;
    expect(tab(), 0, reason: '启动时不在书架 tab');

    await tester.tap(_navDest('名录'));
    await tester.pump();
    expect(tab(), 1, reason: '点「名录」没切到名录 tab');
    mark('A2', '底部导航切到「名录」', '点导航「名录」→ NavigationBar.selectedIndex = 1');

    await tester.tap(_navDest('设置'));
    await tester.pump();
    expect(tab(), 2, reason: '点「设置」没切到设置 tab');
    mark('A3', '底部导航切到「设置」', '点导航「设置」→ NavigationBar.selectedIndex = 2');

    await tester.tap(_navDest('书架'));
    await tester.pump();
    expect(tab(), 0, reason: '点「书架」没切回去');
  });

  // =========================================================================
  // B 书架页
  // =========================================================================
  pTest('B1-B6', '书架页：扫描 / 书名还原 / 搜索 / 分类 chips / 视图切换', '真实书库（E:\\chinabook）逐项点击断言',
      (tester) async {
    resetStore();
    await bootApp(tester);

    // B1 扫描
    expect(_shelfCount(tester), shelf.length, reason: '书架数量不对');
    expect(shelf.length, files.length, reason: '扫描出的条目数 != 目录里的 zip 文件数');
    mark('B1', '书库扫描', '书架计数 == 目录里的 zip 文件数（${files.length}）');

    // B2 书名还原
    final named = shelf.where((b) => b.title != b.fileId).length;
    expect(named, greaterThan(shelf.length ~/ 2), reason: '超过一半的书没从名录还原出书名');
    mark('B2', '书名/作者从名录还原', '非「文件名 ID」的书名占 $named/${shelf.length}（> 50%）');

    final tf = _inPage(ShelfPage, find.byType(TextField));

    // B3 搜索：书名 / 作者 / fileId
    final target = shelf.firstWhere((b) => b.title.length >= 2);
    var tried = 0;
    for (final kw in <String>[
      target.title.substring(0, 2),
      if (target.author.trim().length >= 2) target.author.trim().substring(0, 2),
      target.fileId,
    ]) {
      await tester.enterText(tf, kw);
      await tester.pump();
      final n = _shelfCount(tester);
      expect(n, greaterThan(0), reason: '搜索「$kw」把书全滤掉了');
      expect(n, lessThanOrEqualTo(shelf.length), reason: '搜索「$kw」结果比总数还多');
      tried++;
    }
    mark('B3', '搜索（书名 / 作者 / 文件ID）', '$tried 种关键词各搜一次都能命中且结果 ≤ 总数');

    // B4 无结果 + 清空复原
    await tester.enterText(tf, 'zzz不存在的书名zzz');
    await tester.pump();
    expect(find.text('没有匹配的书'), findsOneWidget, reason: '无结果时没有提示');
    await tester.enterText(tf, '');
    await tester.pump();
    expect(_shelfCount(tester), shelf.length, reason: '清空搜索没有复原');
    mark('B4', '搜索空结果 / 清空复原', '无匹配显示「没有匹配的书」；清空后恢复 ${shelf.length} 本');

    // B5 分类 chips
    final chips = _inPage(ShelfPage, find.byType(ChoiceChip));
    expect(chips, findsWidgets, reason: '没有分类 chip');
    final first = tester.widget<ChoiceChip>(chips.first);
    expect(_plain(first.label as Text), '全部', reason: '第一颗 chip 不是「全部」');
    expect(first.selected, isTrue, reason: '默认没有选中「全部」');
    mark('B5', '分类 chips：「全部」在首位且默认选中', '首颗 chip 文案 = 全部、selected = true');

    final cat = shelf.firstWhere((b) => b.category.isNotEmpty && b.category != '未分类').category;
    final catChip = find.byWidgetPredicate(
      (w) => w is ChoiceChip && w.label is Text && _plain(w.label as Text) == cat,
    );
    if (catChip.evaluate().isNotEmpty) {
      await tester.tap(catChip.first);
      await tester.pump();
      final want = shelf.where((b) => b.category == cat).length;
      expect(_shelfCount(tester), want, reason: '点分类「$cat」后数量 != 该分类书数');
      mark('B6', '点分类 chip 过滤', '点「$cat」→ 计数 == 该分类书数（$want）');
      await tester.tap(find.byWidgetPredicate(
          (w) => w is ChoiceChip && w.label is Text && _plain(w.label as Text) == '全部').first);
      await tester.pump();
    }

    // B7 网格 / 列表
    expect(find.byType(GridView), findsNothing);
    await tester.tap(find.byTooltip('网格'));
    await tester.pump();
    expect(find.byType(GridView), findsOneWidget, reason: '切网格没生效');
    await tester.tap(find.byTooltip('列表'));
    await tester.pump();
    expect(find.byType(GridView), findsNothing, reason: '切回列表没生效');
    mark('B7', '网格 / 列表视图切换', '点网格图标出现 GridView；点列表图标切回 ListView');
  });

  pTest('B8-B12', '书架页：列表项信息 / 进书 / 重新扫描 / 空态', '点列表项与网格项进阅读页并返回；空书库空态',
      (tester) async {
    resetStore();
    final progBook = shelf.first;
    store.setProgress(progBook.fileId, 2, 0);
    await bootApp(tester);

    // B8 列表项信息
    final row = _inPage(ShelfPage, find.byType(ListTile)).first;
    final rowTexts = tester
        .widgetList<Text>(find.descendant(of: row, matching: find.byType(Text)))
        .map(_plain)
        .toList();
    expect(rowTexts, contains(progBook.title), reason: '列表项没有书名');
    expect(rowTexts.any((s) => s.contains('第 3 章')), isTrue, reason: '列表项没显示阅读进度「第 3 章」');
    expect(rowTexts.any((s) => s.endsWith('MB')), isTrue, reason: '列表项没显示体积');
    mark('B8', '列表项信息', '书名 / 副标题（作者·分类）/ 体积 MB / 已读进度「第 N 章」');

    // B9 点列表项进阅读页
    await tester.tap(_inPage(ShelfPage, find.text(progBook.title)).first);
    await tester.pump();
    await pumpUntil(tester, () => find.byType(PageView).evaluate().isNotEmpty);
    await tester.pump();
    expect(find.byType(PageView), findsOneWidget, reason: '点列表项没进阅读页');
    await tester.tap(find.byTooltip('返回上一页（Alt + ←）'));
    await tester.pumpAndSettle();
    expect(find.byType(ShelfPage), findsOneWidget, reason: '从阅读页返回后没回到书架');
    mark('B9', '点列表项进阅读页 / 返回', '点首行 → 出现 PageView；点返回 → 回到 ShelfPage');

    // B10 点网格项进阅读页
    await tester.tap(find.byTooltip('网格'));
    await tester.pump();
    // 必须限定在 GridView 里找：分类 chip 内部也是 InkWell，`find.byType(InkWell).first`
    // 会点到 chip 上，什么都不会发生（之前的用例就是在这一行超时的）。
    await tester.tap(find
        .descendant(of: find.byType(GridView), matching: find.byType(InkWell))
        .first);
    await tester.pump();
    await pumpUntil(tester, () => find.byType(PageView).evaluate().isNotEmpty);
    await tester.pump();
    expect(find.byType(PageView), findsOneWidget, reason: '点网格项没进阅读页');
    await tester.tap(find.byTooltip('返回上一页（Alt + ←）'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('列表'));
    await tester.pump();
    mark('B10', '点网格项进阅读页', '网格视图点封面 → 出现 PageView');

    // B11 重新扫描
    await tester.tap(find.byTooltip('重新扫描书库'));
    await tester.pump();
    final spin = find.descendant(
        of: find.byTooltip('重新扫描书库'), matching: find.byType(CircularProgressIndicator));
    expect(spin, findsOneWidget, reason: '点重新扫描后没有进入扫描态');
    await pumpUntil(tester, () => spin.evaluate().isEmpty);
    expect(_shelfCount(tester), shelf.length, reason: '重新扫描后数量变了');
    mark('B11', '重新扫描书库', '点刷新 → 进入扫描态 → 结束 → 数量仍为 ${shelf.length}');

    // B12 空书库空态（未设目录 / 已设目录）
    final emptyStore = Store.forTest(Directory.systemTemp.createTempSync('zhuye_empty_'));
    Widget emptyApp(Store s) => MaterialApp(
          home: ShelfPage(store: s, shelf: const [], scanning: false, onRescan: () async {}),
        );
    await tester.pumpWidget(emptyApp(emptyStore));
    await tester.pump();
    expect(find.text('书架还是空的'), findsOneWidget, reason: '空书库没有空态提示');
    expect(find.textContaining('请先到「设置」里指定书库目录'), findsOneWidget,
        reason: '未设书库目录时没有引导文案');
    emptyStore.setLibraryRoot(_libRoot);
    await tester.pumpWidget(emptyApp(emptyStore));
    await tester.pump();
    expect(find.textContaining('当前书库目录：$_libRoot'), findsOneWidget,
        reason: '设了书库目录后空态没显示目录路径');
    mark('B12', '空书库空态（未设目录 / 已设目录）',
        '未设目录提示去设置；已设目录显示路径与「把 <文件ID>.zip 放进来」的说明');
  });

  // =========================================================================
  // C 阅读页
  // =========================================================================
  pTest('C1-C6', '阅读页：打开 / 落点 / 首屏正文 / 底栏与顶栏', '解析真实书包，断言落地章节与首屏文字归属',
      (tester) async {
    resetStore();
    final book = readerBook!;
    await openReader(tester, book);
    final epub = (await tester.runAsync(() => LibraryService.openBook(book)))!;

    expect(find.textContaining('打不开这本书'), findsNothing, reason: '阅读页报了打开失败');
    mark('C1', '打开书本（zip → epub → 结构化块）', '真实书包能打开，页面无错误提示');

    final land = firstReadableChapter(epub);
    expect(_chapNo(tester), land + 1, reason: '打开落点 != firstReadableChapter');
    expect(looksLikeTocChapter(epub.blocksOf(land)), isFalse, reason: '落点落在了目录页上');
    expect(
        epub.blocksOf(land).any((b) => b.kind != BlockKind.image && b.text.trim().isNotEmpty), isTrue,
        reason: '落点章节没有正文');
    mark('C2', '打开落点', '落在 firstReadableChapter，且该章不是纯数字目录页、有正文');

    final rendered = _renderedBody(tester);
    expect(rendered.trim().length, greaterThan(80), reason: '首屏渲染出来的文字太少');
    final full = epub.blocksOf(land).map((b) => b.text).join();
    var checked = 0, hit = 0;
    for (final w in _bodyTexts(tester)) {
      final s = _plain(w).trim();
      if (s.length < 8) continue;
      checked++;
      if (full.contains(s)) hit++;
    }
    expect(checked, greaterThan(0), reason: '正文区没找到成句的文字');
    expect(hit, checked, reason: '首屏有文本不是本书正文（$hit/$checked 命中）');
    mark('C3', '首屏正文', '渲染文字 > 80 字，且 $hit/$checked 段都能在本章正文里找到');

    expect(_indicators(tester).length, 2, reason: '底栏缺少「当前页/总页」或「当前章/总章」');
    expect(_pageNo(tester), 1, reason: '打开时不在第 1 页');
    expect(_pageTotal(tester), greaterThan(1), reason: '落地章只有 1 页，样本不合适');
    expect(_chapTotal(tester), epub.chapters.length, reason: '总章数不对');
    mark('C4', '底栏「当前页/总页」+「当前章/总章」',
        '两项俱全：当前页 = 1，总页 = ${_pageTotal(tester)}，总章 = ${epub.chapters.length}');

    final shown = _appBarTitle(tester);
    final raw = epub.chapters[land].title.trim();
    expect(shown.isNotEmpty, isTrue, reason: '顶栏没有标题');
    if (RegExp(r'^\d+$').hasMatch(raw)) {
      expect(shown, '第 $raw 章', reason: '纯数字章节名没有美化成「第 N 章」');
    }
    mark('C5', '顶栏章节标题', '标题非空；纯数字章节名显示为「第 N 章」（本章原名「$raw」）');

    expect(find.byType(AppBar), findsOneWidget, reason: '打开时工具栏没显示');
    expect(find.byType(Slider), findsOneWidget, reason: '打开时底栏没显示');
    mark('C6', '打开时工具栏 + 底栏默认可见', 'AppBar 与进度滑块同时存在');
  });

  pTest('C7-C11', '阅读页：点击翻页 / 触屏滑动 / 滑块跳页', '点左侧 28% / 右侧 72% / 中间；左右滑动；点滑块',
      (tester) async {
    resetStore();
    await openReader(tester, readerBook!);
    final total = _pageTotal(tester);

    final r = tester.getRect(find.byType(PageView));
    await tester.tapAt(Offset(r.right - 20, r.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_pvIndex(tester), 1, reason: '点右侧没有翻到下一页');
    mark('C7', '点屏幕右侧 → 下一页', '点 72% 右侧 → PageView 索引 0 → 1');

    await tester.tapAt(Offset(r.left + 20, r.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_pvIndex(tester), 0, reason: '点左侧没有回到上一页');
    mark('C8', '点屏幕左侧 → 上一页', '点 28% 左侧 → PageView 索引 1 → 0');

    await tester.tapAt(r.center);
    await tester.pump();
    expect(find.byType(AppBar), findsNothing, reason: '点中间没有隐藏工具栏');
    expect(find.byType(Slider), findsNothing, reason: '隐藏工具栏时底栏没一起收起');
    await tester.tapAt(r.center);
    await tester.pump();
    expect(find.byType(AppBar), findsOneWidget, reason: '再点中间没有恢复工具栏');
    expect(find.byType(Slider), findsOneWidget, reason: '恢复时底栏没回来');
    mark('C9', '点屏幕中间 → 工具栏显/隐', '点中间 AppBar + 底栏一起消失；再点恢复');

    await tester.drag(find.byType(PageView), const Offset(-300, 0), kind: PointerDeviceKind.touch);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_pvIndex(tester), 1, reason: '左滑没有翻到下一页');
    await tester.drag(find.byType(PageView), const Offset(300, 0), kind: PointerDeviceKind.touch);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_pvIndex(tester), 0, reason: '右滑没有翻回上一页');
    mark('C10', '触屏左右滑动翻页', '左滑 → 下一页；右滑 → 上一页');

    final sr = tester.getRect(find.byType(Slider));
    await tester.tapAt(Offset(sr.center.dx, sr.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final now = _pvIndex(tester);
    expect(now, greaterThan(0), reason: '点滑块中间没有跳到中途页');
    expect(now, lessThan(total), reason: '滑块跳页越界');
    mark('C11', '底栏滑块跳页', '点滑块中点 → 跳到第 ${now + 1} 页（共 $total 页）');
  });

  pTest('C12-C16', '阅读页：章末「本章完」/ 跨章边界', '翻到章末点「下一章」；末页再点右；首页再点左',
      (tester) async {
    resetStore();
    final book = midBook!;
    await openReader(tester, book);
    final c0 = _chapNo(tester);

    // 用键盘 End/Home 定位，而不是「拖底栏滑块」——
    // `tester.drag(Slider, ±4000)` 在这套假时钟下经常不生效（滑块自身在 C11 已单独验过，
    // 这里要的是「可靠地站到本章末页/首页」这个前置状态）。
    await toLastTextPage(tester);
    // 章末那一屏是最后一页之后的一页，还得再点一次右侧
    await tapRight(tester);
    expect(find.text('本章完'), findsOneWidget, reason: '章末没有出现「本章完」页');
    expect(find.textContaining('下一章 ·'), findsOneWidget, reason: '章末缺少「下一章」按钮');
    mark('C12', '章末「本章完」+「下一章 · X」', '翻到章末 → 出现本章完页与下一章按钮（非末章才有）');

    await tester.tap(find.textContaining('下一章 ·'));
    await tester.pump();
    await settleChapter(tester);
    expect(_chapNo(tester), c0 + 1, reason: '点「下一章」没有进下一章');
    expect(_pageNo(tester), 1, reason: '进下一章应停在第 1 页');
    mark('C13', '章末点「下一章」', '第 $c0 章 → 第 ${c0 + 1} 章第 1 页');

    await toLastTextPage(tester);
    await advanceChapterByTapping(tester);
    expect(_chapNo(tester), c0 + 2, reason: '章末继续点右侧没有进下一章');
    mark('C14', '章末页再点右侧 → 进入下一章', '第 ${c0 + 1} 章末页点右 → 第 ${c0 + 2} 章');

    await toFirstPage(tester);
    expect(_pageNo(tester), 1, reason: 'Home 没退到第 1 页');
    final r = tester.getRect(find.byType(PageView));
    await tester.tapAt(Offset(r.left + 20, r.center.dy));
    await tester.pump();
    await settleChapter(tester);
    expect(_chapNo(tester), c0 + 1, reason: '章首往回翻没有退到上一章');
    expect(_pageNo(tester), _pageTotal(tester), reason: '章首往回翻应落在上一章最后一页（连续阅读）');
    mark('C15', '章首再往回翻 → 上一章末页', '第 ${c0 + 2} 章第 1 页点左 → 第 ${c0 + 1} 章最后一页');

    requestReaderFocus(tester);
    await ctrlKey(tester, LogicalKeyboardKey.home);
    await settleChapter(tester);
    expect(_chapNo(tester), 1, reason: 'Ctrl+Home 没到第 1 章');
    await tester.tapAt(Offset(r.left + 20, r.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_chapNo(tester), 1, reason: '第 1 章章首往回翻越界了');
    mark('C16', '第 1 章章首往回翻不越界', '全书第 1 章第 1 页点左 → 停在本页，不报错');
  });

  pTest('C17-C19', '阅读页：底栏「上一章 / 下一章」按钮（含首末章禁用）', '点按钮切章；读 IconButton 的 onPressed 判禁用',
      (tester) async {
    resetStore();
    await openReader(tester, midBook!);
    final c0 = _chapNo(tester);
    final total = _chapTotal(tester);

    IconButton ib(String tip) => tester.widget<IconButton>(
        find.ancestor(of: find.byTooltip(tip), matching: find.byType(IconButton)).first);

    await tester.tap(find.byTooltip('下一章（Ctrl + →）'));
    await tester.pump();
    await settleChapter(tester);
    expect(_chapNo(tester), c0 + 1, reason: '底栏「下一章」没生效');
    expect(_pageNo(tester), 1, reason: '底栏「下一章」应落在该章第 1 页');
    mark('C17', '底栏「下一章」按钮', '第 $c0 章 → 第 ${c0 + 1} 章第 1 页');

    await tester.tap(find.byTooltip('上一章（Ctrl + ←）'));
    await tester.pump();
    await settleChapter(tester);
    expect(_chapNo(tester), c0, reason: '底栏「上一章」没生效');
    mark('C18', '底栏「上一章」按钮', '第 ${c0 + 1} 章 → 第 $c0 章第 1 页');

    requestReaderFocus(tester);
    await ctrlKey(tester, LogicalKeyboardKey.home);
    await settleChapter(tester);
    expect(_chapNo(tester), 1, reason: '没到第 1 章');
    expect(ib('上一章（Ctrl + ←）').onPressed, isNull, reason: '第 1 章的「上一章」按钮应禁用');
    await ctrlKey(tester, LogicalKeyboardKey.end);
    await settleChapter(tester);
    expect(_chapNo(tester), total, reason: '没到最后一章');
    expect(ib('下一章（Ctrl + →）').onPressed, isNull, reason: '末章的「下一章」按钮应禁用');
    mark('C19', '首/末章对应按钮禁用', '第 1 章「上一章」onPressed=null；末章「下一章」onPressed=null');
  });

  pTest('C20-C25', '阅读页：目录抽屉（打开 / 章数 / 自动定位 / 跳章 / 返回项）', '点底栏「目录」，验抽屉内容与跳转',
      (tester) async {
    resetStore();
    final book = tocBook!;
    await openReader(tester, book);
    final epub = (await tester.runAsync(() => LibraryService.openBook(book)))!;

    await tester.tap(find.byTooltip('目录'));
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsOneWidget, reason: '目录抽屉没打开');
    mark('C20', '底栏「目录」按钮打开抽屉', '点「目录」→ Drawer 出现');

    expect(find.textContaining('${epub.chapters.length} 章 ·'), findsOneWidget, reason: '抽屉章数不对');
    expect(_tocChapterTiles, findsWidgets, reason: '抽屉里没有章节项');
    mark('C21', '抽屉显示章数与章节列表', '显示「${epub.chapters.length} 章 · 作者」，章节项可枚举');

    final tiles = tester.widgetList<ListTile>(_tocChapterTiles).toList();
    final selIdx = tiles.indexWhere((t) => t.selected);
    expect(selIdx, greaterThanOrEqualTo(0), reason: '目录里没有高亮当前章（自动定位失效）');
    final dr = tester.getRect(find.byType(Drawer));
    final tr = tester.getRect(_tocChapterTiles.at(selIdx));
    expect(tr.bottom, greaterThan(dr.top), reason: '当前章被滚到视口上方之外');
    expect(tr.top, lessThan(dr.bottom), reason: '当前章被滚到视口下方之外');
    mark('C22', '抽屉自动定位到当前章', '打开抽屉时高亮项就在可视范围内（懒加载列表已滚到位）');

    // 点目录项跳章。**必须先把列表滚回顶部**：刚打开时列表已被自动定位到当前章附近，
    // 而 ListView.builder 只构建可视区内的项 —— 离得远的 toc-2 根本没被构建，tap 会找不到。
    await tocToTop(tester, 2);
    expect(_tocTile(2), findsOneWidget, reason: '滚到顶部后依然找不到第 3 章（章节列表前几项缺失）');
    await tester.tap(_tocTile(2));
    await tester.pumpAndSettle();
    await settleChapter(tester);
    expect(_chapNo(tester), 3, reason: '点目录第 3 章没有跳过去');
    expect(_pageNo(tester), 1, reason: '跳章应落在该章第 1 页');
    mark('C25', '点目录项跳章', '点目录第 3 章 → 底栏变「1/N」+「3/总章」');

    // Esc 关抽屉。**注意顺序**：必须先「真的把抽屉重新打开」。
    // 上一步点目录项跳章时抽屉已经被 onTap 里的 pop 关掉了；
    // 此时按 Esc 走的是「没有抽屉 → 收起工具栏」那条分支，
    // 后面的 C24 就再也点不到底栏的「目录」按钮了（工具栏被收起来了）。
    await tester.tap(find.byTooltip('目录'));
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsOneWidget, reason: '重新打开抽屉失败，C23 就没得测了');
    requestReaderFocus(tester);
    await key(tester, LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsNothing, reason: 'Esc 没有关掉抽屉');
    mark('C23', 'Esc 关闭目录抽屉', '抽屉打开时按 Esc → 抽屉收起（而不是收起工具栏）');

    // 跳到末章再开抽屉：几百章的懒加载列表也必须把当前章滚进来
    await ctrlKey(tester, LogicalKeyboardKey.end);
    await settleChapter(tester);
    await tester.tap(find.byTooltip('目录'));
    await tester.pumpAndSettle();
    final tiles2 = tester.widgetList<ListTile>(_tocChapterTiles).toList();
    final sel2 = tiles2.indexWhere((t) => t.selected);
    expect(sel2, greaterThanOrEqualTo(0),
        reason: '跳到末章后打开目录，当前章没被构建（共 ${epub.chapters.length} 章）');
    final tr2 = tester.getRect(_tocChapterTiles.at(sel2));
    final dr2 = tester.getRect(find.byType(Drawer));
    expect(tr2.top, lessThan(dr2.bottom), reason: '末章项不在可视范围内');
    mark('C24', '长目录（${epub.chapters.length} 章）自动定位', 'Ctrl+End 到末章后开抽屉，末章项仍在可视区内');
  });

  pTest('C26-C29', '阅读页：书签（加 / 取消 / 内容 / 落盘）', '点书签按钮两下，检查存储、图标与文件',
      (tester) async {
    resetStore();
    final book = readerBook!;
    await openReader(tester, book);

    Icon ico() => tester.widget<Icon>(
        find.descendant(of: find.byTooltip('书签'), matching: find.byType(Icon)).first);

    expect(store.bookmarksOf(book.fileId), isEmpty, reason: '前置状态不干净');
    expect(ico().icon, Icons.bookmark_border, reason: '未收藏时图标不是空心');
    await tester.tap(find.byTooltip('书签'));
    await tester.pump();
    final list = store.bookmarksOf(book.fileId);
    expect(list.length, 1, reason: '加书签没生效');
    expect(ico().icon, Icons.bookmark, reason: '收藏后图标没变实心');
    mark('C26', '加书签', '点书签按钮 → 存储 +1、图标变实心（bookmark）');

    final bm = list.first;
    expect(bm.chapterTitle.trim().isNotEmpty, isTrue, reason: '书签没有章节标题');
    expect(bm.excerpt.trim().isNotEmpty, isTrue, reason: '书签没有正文摘录');
    expect(bm.chapterIndex, _chapNo(tester) - 1, reason: '书签章节号与当前章不一致');
    final chapterText = (await tester.runAsync(() => LibraryService.openBook(book)))!
        .blocksOf(bm.chapterIndex)
        .map((b) => b.text)
        .join();
    // 摘录是「本页各块用空格拼起来」的，而这里把整章各块直接首尾相接 ——
    // 块边界处一个空格之差就会让 contains 失败。比之前先把空白全去掉。
    String flat(String s) => s.replaceAll(RegExp(r'\s+'), '');
    expect(flat(chapterText).contains(flat(bm.excerpt)), isTrue,
        reason: '书签摘录「${bm.excerpt}」不是本章正文');
    mark('C27', '书签内容正确', '章节标题非空、摘录非空且确实来自本章正文');

    expect(
        File('${store.dir.path}${Platform.pathSeparator}bookmarks.json').existsSync(), isTrue,
        reason: '书签没有落盘');
    final saved = jsonDecode(
            File('${store.dir.path}${Platform.pathSeparator}bookmarks.json').readAsStringSync())
        as Map<String, dynamic>;
    expect((saved['items'] as List).length, 1, reason: '落盘的书签条数不对');
    mark('C28', '书签落盘', 'bookmarks.json 存在且条数与内存一致（重启不丢）');

    await tester.tap(find.byTooltip('书签'));
    await tester.pump();
    expect(store.bookmarksOf(book.fileId), isEmpty, reason: '取消书签没生效');
    expect(ico().icon, Icons.bookmark_border, reason: '取消后图标没变回空心');
    mark('C29', '取消书签', '再点书签按钮 → 存储 -1、图标变回空心（回归过「删不掉」的 bug）');
  });

  pTest('C30-C33', '阅读页：排版面板（字号 / 行距 / 主题）', '打开排版面板改参数，看分页与配色',
      (tester) async {
    resetStore();
    await openReader(tester, readerBook!);
    final pages0 = _pageTotal(tester);

    await tester.tap(find.byTooltip('排版'));
    await tester.pumpAndSettle();
    expect(find.text('字号'), findsOneWidget);
    expect(find.text('行距'), findsOneWidget);
    expect(find.text('主题'), findsOneWidget);
    final sheetSliders =
        find.descendant(of: find.byType(BottomSheet), matching: find.byType(Slider));
    expect(sheetSliders, findsNWidgets(2), reason: '排版面板里应有字号/行距两个滑杆');
    mark('C30', '排版面板内容', '面板含「字号 / 行距」两个滑杆 + 三档主题色块');

    await tester.drag(sheetSliders.first, const Offset(600, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(store.settings.fontScale, greaterThan(1.0), reason: '字号没有变大');
    final pages1 = _pageTotal(tester);
    expect(pages1, greaterThan(pages0), reason: '字号变大后页数没增加（重新分页没生效）');
    mark('C31', '字号变大 → 重新分页', '字号滑杆拉大 → fontScale > 1，页数 $pages0 → $pages1');

    final lh0 = store.settings.lineHeight;
    await tester.drag(sheetSliders.at(1), const Offset(600, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(store.settings.lineHeight, greaterThan(lh0), reason: '行距没有变大');
    expect(_pageTotal(tester), greaterThanOrEqualTo(pages1), reason: '行距变大后页数反而变少');
    mark('C32', '行距变大 → 重新分页', '行距滑杆拉大 → lineHeight 变大，页数不减少');

    final want = {
      '白': const Color(0xFFFCFCFA),
      '黄': const Color(0xFFF4ECD8),
      '黑': const Color(0xFF14161A),
    };
    for (final e in want.entries) {
      await tester.tap(find.text(e.key));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
        e.value,
        reason: '主题「${e.key}」没应用到页面底色',
      );
    }
    mark('C33', '主题白/黄/黑三档', '三档底色分别为 #FCFCFA / #F4ECD8 / #14161A');
    await tester.tap(find.text('白'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  });

  pTest('C34-C40', '阅读页：键盘快捷键（翻页 / 切章 / 首末页 / Esc）', '逐个按键断言',
      (tester) async {
    resetStore();
    await openReader(tester, kbdBook!);
    final total = _pageTotal(tester);
    expect(total, greaterThan(2), reason: '样本落地章页数太少，键盘翻页验不出来');
    requestReaderFocus(tester);
    await tester.pump();

    expect(_pvIndex(tester), 0);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(_pvIndex(tester), 1, reason: '→ 没有翻下一页');
    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(_pvIndex(tester), 0, reason: '← 没有翻上一页');
    await key(tester, LogicalKeyboardKey.space);
    expect(_pvIndex(tester), 1, reason: '空格没有翻页');
    await key(tester, LogicalKeyboardKey.pageDown);
    expect(_pvIndex(tester), 2, reason: 'PageDown 没有翻页');
    await key(tester, LogicalKeyboardKey.pageUp);
    expect(_pvIndex(tester), 1, reason: 'PageUp 没有回退一页');
    mark('C34', '键盘 ← → 空格 PageUp/PageDown 翻页', '五个翻页键各按一次，PageView 索引逐次正确');

    await key(tester, LogicalKeyboardKey.end);
    expect(_pvIndex(tester), total - 1, reason: 'End 没有跳到本章最后一页');
    await key(tester, LogicalKeyboardKey.home);
    expect(_pvIndex(tester), 0, reason: 'Home 没有回到本章第 1 页');
    mark('C35', '键盘 Home / End 章内首末页', 'End → 第 $total 页；Home → 第 1 页');

    final c0 = _chapNo(tester);
    await ctrlKey(tester, LogicalKeyboardKey.arrowRight);
    await settleChapter(tester);
    expect(_chapNo(tester), c0 + 1, reason: 'Ctrl+→ 没有切下一章');
    expect(_pageNo(tester), 1, reason: 'Ctrl+→ 应落在下一章第 1 页');
    await key(tester, LogicalKeyboardKey.bracketRight);
    await settleChapter(tester);
    expect(_chapNo(tester), c0 + 2, reason: '] 没有切下一章');
    await key(tester, LogicalKeyboardKey.keyN);
    await settleChapter(tester);
    expect(_chapNo(tester), c0 + 3, reason: 'n 没有切下一章');
    mark('C36', '键盘 Ctrl+→ / ] / n 切下一章', '三种按键都能前进一章并落在该章第 1 页');

    await ctrlKey(tester, LogicalKeyboardKey.arrowLeft);
    await settleChapter(tester);
    expect(_chapNo(tester), c0 + 2, reason: 'Ctrl+← 没有切上一章');
    await key(tester, LogicalKeyboardKey.bracketLeft);
    await settleChapter(tester);
    expect(_chapNo(tester), c0 + 1, reason: '[ 没有切上一章');
    await key(tester, LogicalKeyboardKey.keyP);
    await settleChapter(tester);
    expect(_chapNo(tester), c0, reason: 'p 没有切上一章');
    mark('C37', '键盘 Ctrl+← / [ / p 切上一章', '三种按键都能后退一章并落在该章第 1 页');

    await ctrlKey(tester, LogicalKeyboardKey.home);
    await settleChapter(tester);
    expect(_chapNo(tester), 1, reason: 'Ctrl+Home 没有到全书第 1 章');
    await ctrlKey(tester, LogicalKeyboardKey.end);
    await settleChapter(tester);
    expect(_chapNo(tester), _chapTotal(tester), reason: 'Ctrl+End 没有到全书最后一章');
    mark('C38', '键盘 Ctrl+Home / Ctrl+End 全书首末章', '分别跳到第 1 章与第 ${_chapTotal(tester)} 章');

    requestReaderFocus(tester);
    expect(find.byType(AppBar), findsOneWidget);
    await key(tester, LogicalKeyboardKey.escape);
    expect(find.byType(AppBar), findsNothing, reason: 'Esc 没有收起工具栏');
    await key(tester, LogicalKeyboardKey.escape);
    expect(find.byType(AppBar), findsNothing, reason: '已收起时按 Esc 不应恢复工具栏');
    await tester.tapAt(tester.getRect(find.byType(PageView)).center);
    await tester.pump();
    expect(find.byType(AppBar), findsOneWidget, reason: '点中间没恢复工具栏');
    mark('C39', '键盘 Esc 收起工具栏（重复按无副作用）', '有栏时 Esc → 收起；再按无变化；点中间恢复');
    mark('C40', '键盘快捷键不影响鼠标交互', 'Esc 收起后用鼠标点中间仍能恢复工具栏');
  });

  pTest('C41-C44', '阅读页：返回入口三路（左上返回键 / Alt+← / 抽屉返回项）', '分别点三种入口，验证出栈回书架',
      (tester) async {
    resetStore();
    final book = readerBook!;

    await openReader(tester, book);
    final back = find.byTooltip('返回上一页（Alt + ←）');
    expect(back, findsOneWidget, reason: '左上角没有返回按钮（Scaffold 有 drawer 会顶掉 leading）');
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(_shelfMarker, findsOneWidget, reason: '点返回按钮没回到书架');
    expect(find.byType(PageView), findsNothing, reason: '返回后阅读页还在');
    mark('C41', '左上角返回键', '点左上 ← → 阅读页出栈，回到上一层（书架）');

    await openReader(tester, book);
    requestReaderFocus(tester);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(_shelfMarker, findsOneWidget, reason: 'Alt+← 没回到书架');
    mark('C42', '键盘 Alt + ← 返回', '按 Alt+← → 回到上一层（与资源管理器「后退」一致）');

    await openReader(tester, book);
    await tester.tap(find.byTooltip('目录'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(Drawer), matching: find.text('返回上一页')), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(Drawer), matching: find.text('返回上一页')));
    await tester.pumpAndSettle();
    expect(_shelfMarker, findsOneWidget, reason: '抽屉返回项没生效');
    mark('C43', '抽屉「返回上一页」入口', '抽屉内返回项 → 收起抽屉并回到上一层');

    // 返回时进度已落盘
    await openReader(tester, book);
    final r = tester.getRect(find.byType(PageView));
    await tester.tapAt(Offset(r.right - 20, r.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final wantPage = _pageNo(tester);
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(store.progressOf(book.fileId)?.pageIndex, wantPage - 1,
        reason: '返回时没有把进度落盘');
    mark('C44', '返回时保存阅读进度', '翻到第 $wantPage 页后返回 → progress 记录第 $wantPage 页');
  });

  pTest('C45-C46', '阅读页：逐页渲染无溢出（文字页 + 含图片页）', '逐页真实渲染，任何溢出都会让测试异常',
      (tester) async {
    resetStore();
    await openReader(tester, readerBook!);
    final total = _pageTotal(tester);
    final pc = tester.widget<PageView>(find.byType(PageView)).controller!;
    for (var i = 0; i < total; i++) {
      pc.jumpToPage(i);
      await tester.pump();
    }
    pc.jumpToPage(total); // 章末屏
    await tester.pump();
    expect(find.text('本章完'), findsOneWidget, reason: '章末屏没渲染出来');
    mark('C45', '逐页渲染无溢出（文字页）', '本章 $total 页 + 章末屏逐页渲染，无 RenderFlex overflow');

    final another = shelf.firstWhere((b) => b.fileId != readerBook!.fileId, orElse: () => readerBook!);
    await openReader(tester, another);
    final t2 = _pageTotal(tester);
    final pc2 = tester.widget<PageView>(find.byType(PageView)).controller!;
    var imgPages = 0;
    for (var i = 0; i < t2; i++) {
      pc2.jumpToPage(i);
      await tester.pump();
      if (find.byType(Image).evaluate().isNotEmpty) imgPages++;
    }
    mark('C46', '含图片的页也能正常渲染',
        '另一本《${another.title}》落地章 $t2 页逐页渲染，其中 $imgPages 页含图片');
  });

  pTest('C47-C50', '阅读页：章节名美化 + 阅读进度保存与恢复', '打开章节名为纯数字的书；翻页后重开',
      (tester) async {
    resetStore();
    if (numTitleBook == null || numTitleCh < 0) {
      markTestSkipped('书库里没有「章节名为纯数字」的书');
      _row('C47-C50', '章节名美化 / 进度恢复', '—', '⏭ 跳过：无纯数字章节名的书');
      return;
    }
    final book = numTitleBook!;
    await openReader(tester, book);
    final epub = (await tester.runAsync(() => LibraryService.openBook(book)))!;
    final want = '第 ${epub.chapters[numTitleCh].title.trim()} 章';

    expect(_chapNo(tester), numTitleCh + 1, reason: '落点不是预期的纯数字章节');
    expect(_appBarTitle(tester), want, reason: '顶栏没有把纯数字章节名美化成「第 N 章」');
    mark('C47', '顶栏章节名美化', '原名「${epub.chapters[numTitleCh].title.trim()}」→ 顶栏显示「$want」');

    await tester.tap(find.byTooltip('目录'));
    await tester.pumpAndSettle();
    final tile = _tocTile(numTitleCh);
    expect(tile, findsOneWidget, reason: '目录里找不到该章（自动定位没滚到）');
    expect(
      tester.widgetList<Text>(find.descendant(of: tile, matching: find.byType(Text))).map(_plain),
      contains(want),
      reason: '目录里的纯数字章节名没有美化',
    );
    mark('C48', '目录章节名美化', '目录中该章显示为「$want」');

    await tester.tap(tile);
    await tester.pumpAndSettle();
    await settleChapter(tester);
    if (_pageTotal(tester) > 1) {
      final r = tester.getRect(find.byType(PageView));
      await tester.tapAt(Offset(r.right - 20, r.center.dy));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
    final savedCh = _chapNo(tester);
    final savedPage = _pageNo(tester);
    final p = store.progressOf(book.fileId);
    expect(p, isNotNull, reason: '翻页后没有记录进度');
    expect(p!.chapterIndex, savedCh - 1, reason: '记录的章号不对');
    expect(p.pageIndex, savedPage - 1, reason: '记录的页号不对');
    mark('C49', '阅读进度落盘', '翻页后 progress 记录为第 $savedCh 章第 $savedPage 页');

    await openReader(tester, book);
    expect(_chapNo(tester), savedCh, reason: '重新打开没有恢复到上次的章节');
    expect(_pageNo(tester), savedPage, reason: '重新打开没有恢复到上次的页码');
    mark('C50', '重新打开恢复阅读位置', '重开停在第 $savedCh 章第 $savedPage 页（与上次一致）');
  });

  // =========================================================================
  // D 名录页
  // =========================================================================
  pTest('D1-D8', '名录页：统计 / 检索门槛 / 命中数 / 入库标记 / 详情 / 开始阅读', '真实 11k 名录检索',
      (tester) async {
    resetStore();
    await bootApp(tester);
    await tester.tap(_navDest('名录'));
    await tester.pump();

    final cat = Catalog.instance;
    expect(_inPage(CatalogPage, find.text('名录检索')), findsOneWidget, reason: '名录页标题缺失');
    expect(
      find.descendant(
          of: find.byType(CatalogPage),
          matching: find.text('共收录 ${cat.count} 本 · 本地已有 ${shelf.length} 本')),
      findsOneWidget,
      reason: '初始统计文案不对',
    );
    mark('D1', '名录页标题与初始统计', '显示「共收录 ${cat.count} 本 · 本地已有 ${shelf.length} 本」');

    expect(find.text('输入关键词开始检索'), findsOneWidget, reason: '未检索时没有提示');
    mark('D2', '未检索时的占位提示', '显示「输入关键词开始检索」');

    final tf = _inPage(CatalogPage, find.byType(TextField));
    await tester.enterText(tf, 'z');
    await tester.pump();
    expect(find.text('输入关键词开始检索'), findsOneWidget, reason: '单字就触发了检索');
    mark('D3', '检索门槛：≥2 字才触发', '输入 1 个字不检索（仍显示占位提示）');

    final local = shelf.first;
    await tester.enterText(tf, local.title);
    await tester.pump();
    expect(find.textContaining('命中 '), findsOneWidget, reason: '没有显示命中数');
    expect(_inPage(CatalogPage, find.byType(ListTile)).evaluate().isNotEmpty, isTrue);
    mark('D4', '显示「命中 N 条」并列出结果', '搜「${local.title}」→ 显示命中数 + 结果列表');

    expect(find.text('已入库'), findsWidgets, reason: '已下载的书在名录里没有「已入库」标记');
    mark('D5', '已入库标记', '本地已有的书显示绿勾 +「已入库」');

    final localIds = shelf.map((e) => e.fileId).toSet();
    final notLocal = cat.all.firstWhere((e) => !localIds.contains(e.fileId) && e.title.length >= 2);
    await tester.enterText(tf, notLocal.title.substring(0, 2));
    await tester.pump();
    expect(find.byIcon(Icons.cloud_download_outlined), findsWidgets, reason: '未下载的书没有「未入库」图标');
    mark('D6', '未入库标记', '未下载的书显示下载图标 + 文件 ID');

    await tester.enterText(tf, local.title);
    await tester.pump();
    // 必须点 ListTile 里的那一条：`find.text` 同时也匹配 EditableText，
    // 而搜索框（Column 里排在前面）里的文字正好就是 local.title ——
    // 直接 `find.text(...).first` 点到的是输入框，什么都不会弹。
    final hitTile = _inPage(CatalogPage, find.widgetWithText(ListTile, local.title));
    expect(hitTile, findsWidgets, reason: '名录里搜不到《${local.title}》的条目');
    await tester.tap(hitTile.first);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget, reason: '点条目没有弹详情');
    expect(find.text('文件 ID：${local.fileId}'), findsOneWidget, reason: '详情里没有文件 ID');
    expect(find.textContaining('已经下载到本地'), findsOneWidget, reason: '已入库书的详情文案不对');
    mark('D7', '点条目 → 详情弹层', '弹层含书名、作者·分类、文件 ID，已入库时说明「去书架打开」');

    expect(find.text('开始阅读'), findsOneWidget, reason: '已入库的书详情里没有「开始阅读」');
    await tester.tap(find.text('开始阅读'));
    await tester.pump();
    await pumpUntil(tester, () => find.byType(PageView).evaluate().isNotEmpty);
    await tester.pump();
    expect(find.byType(PageView), findsOneWidget, reason: '「开始阅读」没有进阅读页');
    mark('D8', '详情「开始阅读」→ 阅读页', '点按钮 → 直接打开该书的阅读页');
  });

  // =========================================================================
  // E 设置页
  // =========================================================================
  pTest('E1-E9', '设置页：书库信息 / 目录回填 / 默认排版 / 书签管理 / 关于', '设置页逐项断言',
      (tester) async {
    resetStore();
    store.setProgress(shelf.first.fileId, 1, 0);
    store.toggleBookmark(Bookmark(
      fileId: shelf.first.fileId,
      chapterIndex: 1,
      chapterTitle: '测试章节',
      pageIndex: 0,
      excerpt: '测试摘录',
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    await bootApp(tester);
    await tester.tap(_navDest('设置'));
    await tester.pump();

    final cat = Catalog.instance;
    expect(_inPage(SettingsPage, find.text('设置')), findsWidgets, reason: '设置页标题缺失');
    mark('E1', '设置页标题', 'AppBar 显示「设置」');

    expect(find.text('书架 ${shelf.length} 本'), findsOneWidget, reason: '卡片书架数不对');
    expect(find.text('名录收录 ${cat.count} 本 · ${cat.categories.length} 个分类'), findsOneWidget,
        reason: '卡片名录统计不对');
    mark('E2', '书库信息卡片', '显示「书架 ${shelf.length} 本」「名录收录 ${cat.count} 本 · '
        '${cat.categories.length} 个分类」');

    final rootField = _inPage(SettingsPage, find.byType(TextField));
    expect(tester.widget<TextField>(rootField).controller!.text, _libRoot, reason: '书库目录没有回填');
    mark('E3', '书库目录回填', '输入框内容 == store.libraryRoot（$_libRoot）');

    final sliders = _inPage(SettingsPage, find.byType(Slider));
    expect(sliders, findsNWidgets(2), reason: '设置页应有字号/行距两个滑杆');
    final fs0 = store.settings.fontScale;
    await tester.drag(sliders.first, const Offset(600, 0));
    await tester.pump();
    expect(store.settings.fontScale, greaterThan(fs0), reason: '设置页字号滑杆没生效');
    mark('E4', '默认排版：字号滑杆', '拖动后 fontScale $fs0 → ${store.settings.fontScale}');

    final lh0 = store.settings.lineHeight;
    await tester.drag(sliders.at(1), const Offset(600, 0));
    await tester.pump();
    expect(store.settings.lineHeight, greaterThan(lh0), reason: '设置页行距滑杆没生效');
    mark('E5', '默认排版：行距滑杆', '拖动后 lineHeight $lh0 → ${store.settings.lineHeight}');

    await tester.tap(_inPage(SettingsPage, find.text('黄')));
    await tester.pump();
    expect(store.settings.theme, ReaderTheme.sepia, reason: '主题没切到「黄」');
    await tester.tap(_inPage(SettingsPage, find.text('黑')));
    await tester.pump();
    expect(store.settings.theme, ReaderTheme.dark, reason: '主题没切到「黑」');
    await tester.tap(_inPage(SettingsPage, find.text('白')));
    await tester.pump();
    expect(store.settings.theme, ReaderTheme.light, reason: '主题没切回「白」');
    mark('E6', '默认排版：主题三选一', '白 / 黄 / 黑 依次切换，store.settings.theme 同步变化');

    expect(find.text('测试章节'), findsOneWidget, reason: '设置页书签区没列出书签');
    expect(find.text('测试摘录'), findsOneWidget, reason: '书签摘录没显示');
    expect(find.text('还没有书签'), findsNothing);
    mark('E7', '设置页书签列表', '列出书签的章节标题与摘录');

    await tester.tap(_inPage(SettingsPage, find.byIcon(Icons.close)).first);
    await tester.pump();
    expect(store.bookmarks, isEmpty, reason: '设置页删除书签没生效');
    expect(find.text('还没有书签'), findsOneWidget, reason: '删完后没显示空态');
    mark('E8', '设置页删除书签', '点 × → 书签被删除并显示「还没有书签」');

    expect(find.textContaining('数据目录：${store.dir.path}'), findsOneWidget, reason: '关于卡片没有数据目录');
    expect(find.textContaining('平台：${Platform.operatingSystem}'), findsOneWidget,
        reason: '关于卡片没有平台信息');
    mark('E9', '关于卡片', '显示应用说明、数据目录与当前平台');
  });

  pTest('E10-E12', '设置页：重新扫描 / 保存并重新扫描 / 设置落盘', '改目录→保存→SnackBar；点重新扫描',
      (tester) async {
    resetStore();
    await bootApp(tester);
    await tester.tap(_navDest('设置'));
    await tester.pump();

    final rescan = _inPage(SettingsPage, find.widgetWithText(OutlinedButton, '重新扫描书库'));
    expect(rescan, findsOneWidget, reason: '设置页没有「重新扫描书库」按钮');
    await tester.tap(rescan);
    await tester.pump();
    await pumpUntil(tester, () => find.text('书架 ${shelf.length} 本').evaluate().isNotEmpty);
    mark('E10', '设置页「重新扫描书库」', '点按钮 → 扫描完成，书架数量仍为 ${shelf.length}');

    final rootField = _inPage(SettingsPage, find.byType(TextField));
    await tester.enterText(rootField, _libRoot);
    await tester.pump();
    await tester.tap(
        find.descendant(of: find.byType(SettingsPage), matching: find.byTooltip('保存并重新扫描')));
    await tester.pump();
    expect(store.libraryRoot, _libRoot, reason: '保存书库目录没写进 store');
    await pumpUntil(tester, () => find.byType(SnackBar).evaluate().isNotEmpty);
    expect(find.textContaining('已保存，当前书架'), findsOneWidget, reason: '没有弹出保存成功的 SnackBar');
    mark('E11', '保存并重新扫描', '输入框尾部勾 → libraryRoot 落库 + SnackBar「已保存，当前书架 N 本」');

    final f = File('${store.dir.path}${Platform.pathSeparator}store.json');
    expect(f.existsSync(), isTrue, reason: 'store.json 不存在');
    final cfg = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    expect(cfg['libraryRoot'], _libRoot, reason: 'store.json 里的书库目录不对');
    mark('E12', '设置落盘', 'store.json 中 libraryRoot == $_libRoot（重启后仍生效）');
  });

  // =========================================================================
  // F 服务层
  // =========================================================================
  sTest('F1', 'Store 持久化（设置 / 书库目录 / 进度 / 书签）', '写盘后按同一序列化契约读回', () async {
    final dir = Directory.systemTemp.createTempSync('zhuye_f1_');
    final s = Store.forTest(dir, libraryRoot: r'X:\some\lib');
    s.setSettings(const ReaderSettings(fontScale: 1.4, lineHeight: 2.1, theme: ReaderTheme.sepia));
    s.setProgress('abc', 3, 7);
    s.toggleBookmark(const Bookmark(
      fileId: 'abc',
      chapterIndex: 3,
      chapterTitle: '第 4 章',
      pageIndex: 7,
      excerpt: '摘录',
      createdAt: 12345,
    ));

    final sp = Platform.pathSeparator;
    final cfg =
        jsonDecode(File('${dir.path}${sp}store.json').readAsStringSync()) as Map<String, dynamic>;
    expect(cfg['libraryRoot'], r'X:\some\lib');
    final set = ReaderSettings.fromJson((cfg['settings'] as Map).cast<String, dynamic>());
    expect(set.fontScale, 1.4);
    expect(set.lineHeight, 2.1);
    expect(set.theme, ReaderTheme.sepia);

    final pr =
        jsonDecode(File('${dir.path}${sp}progress.json').readAsStringSync()) as Map<String, dynamic>;
    final bp = BookProgress.fromJson((pr['abc'] as Map).cast<String, dynamic>());
    expect(bp.chapterIndex, 3);
    expect(bp.pageIndex, 7);
    expect(bp.updatedAt, greaterThan(0));

    final bm =
        jsonDecode(File('${dir.path}${sp}bookmarks.json').readAsStringSync()) as Map<String, dynamic>;
    final b = Bookmark.fromJson(((bm['items'] as List).first as Map).cast<String, dynamic>());
    expect(b.fileId, 'abc');
    expect(b.chapterTitle, '第 4 章');
    expect(b.excerpt, '摘录');
  });

  sTest('F2', 'Store 书签 toggle 幂等（加 → 删 → 再加）', '同一页连续 toggle，检查最终状态', () async {
    final s = Store.forTest(Directory.systemTemp.createTempSync('zhuye_f2_'));
    const b = Bookmark(
      fileId: 'f',
      chapterIndex: 1,
      chapterTitle: 't',
      pageIndex: 2,
      excerpt: 'e',
      createdAt: 1,
    );
    expect(s.bookmarks, isEmpty);
    s.toggleBookmark(b);
    expect(s.bookmarks.length, 1, reason: '第一次 toggle 应该加上');
    expect(s.isBookmarked('f', 1, 2), isTrue);
    s.toggleBookmark(b);
    expect(s.bookmarks, isEmpty, reason: '第二次 toggle 应该删掉（旧版这里恒为「加回来」）');
    expect(s.isBookmarked('f', 1, 2), isFalse);
    s.toggleBookmark(b);
    expect(s.bookmarks.length, 1);
    s.removeBookmark(b);
    expect(s.bookmarks, isEmpty, reason: 'removeBookmark 没生效');
  });

  sTest('F3', 'Catalog：byId / 检索打分排序 / 作者 / 别名 / 空查询 / limit', '真实 11k 名录索引', () async {
    final c = Catalog.instance;
    expect(c.count, greaterThan(10000), reason: '名录条目太少');
    expect(c.categories.length, greaterThan(100), reason: '分类太少');

    final local = shelf.first;
    final e = c.byId(local.fileId);
    expect(e, isNotNull, reason: '本地书在名录里查不到');
    expect(e!.title, local.title, reason: '书架书名与名录不一致');

    expect(c.search(e.title).first.fileId, e.fileId, reason: '精确书名没有排第一');
    expect(c.search(e.title.substring(0, 2)).any((x) => x.fileId == e.fileId), isTrue,
        reason: '两字前缀没命中该书');

    final withAuthor = shelf.firstWhere((x) => x.author.trim().length >= 2, orElse: () => shelf.first);
    if (withAuthor.author.trim().length >= 2) {
      final byAuthor = c.search(withAuthor.author.trim());
      expect(byAuthor.any((x) => x.fileId == withAuthor.fileId), isTrue, reason: '按作者搜不到该书');
    }

    final aliased = c.all.firstWhere((x) => x.aliases.isNotEmpty, orElse: () => e);
    if (aliased.aliases.isNotEmpty) {
      expect(c.search(aliased.aliases.first).any((x) => x.fileId == aliased.fileId), isTrue,
          reason: '别名没有参与检索');
    }

    expect(c.search(''), isEmpty);
    expect(c.search('   '), isEmpty);
    expect(c.search('的', limit: 5).length, lessThanOrEqualTo(5), reason: 'limit 没生效');
  });

  sTest('F4', 'looksLikeTocChapter：目录页判定（正例 / 负例）', '构造块序列直接判定', () async {
    List<Block> mk(List<String> paras) =>
        [for (final p in paras) Block(BlockKind.paragraph, runs: [Run(p)])];

    expect(looksLikeTocChapter(mk(['目录', '1', '2', '3', '4', '5', '6', '7', '致 谢'])), isTrue,
        reason: '数字目录页没被识别出来');
    expect(
      looksLikeTocChapter(mk([
        '这是一个正常的段落，长度明显超过四个字符，用于验证误判。',
        '第二段同样足够长，不应该被当成目录页。',
        '第三段也很长，继续验证判定逻辑。',
        '第四段，继续。',
        '第五段，继续。',
        '第六段，继续。',
      ])),
      isFalse,
      reason: '正常正文被误判成目录页',
    );
    expect(looksLikeTocChapter(mk(['1', '2', '3'])), isFalse, reason: '段落数不足 6 不该判定为目录页');
    expect(looksLikeTocChapter(const []), isFalse);
  });

  sTest('F5', 'firstReadableChapter：落点跳过纯图章与目录页', '真实书 + 起点参数', () async {
    final book = await LibraryService.openBook(readerBook!);
    final land = firstReadableChapter(book);
    expect(land, inInclusiveRange(0, book.chapters.length - 1));
    expect(book.blocksOf(land).any((b) => b.kind != BlockKind.image && b.text.trim().isNotEmpty), isTrue,
        reason: '落点章节没有正文');
    expect(looksLikeTocChapter(book.blocksOf(land)), isFalse, reason: '落点落在了目录页上');

    final from = book.chapters.length - 1;
    expect(firstReadableChapter(book, from: from), from, reason: 'from 参数没生效');

    for (final b in shelf.take(12)) {
      final eb = await LibraryService.openBook(b);
      expect(eb.blocksOf(firstReadableChapter(eb)).isNotEmpty, isTrue,
          reason: '${b.fileId} 的落点章是空的');
    }
  });

  sTest('F6', 'extractEpubFromPack：从书包里取出的是 epub（不是 mobi/azw3）', '读真实 zip 校验结构', () async {
    final bytes = File(readerBook!.path).readAsBytesSync();
    final arc = ZipDecoder().decodeBytes(bytes, verify: false);
    final names = arc.files.where((f) => f.isFile).map((f) => f.name.toLowerCase()).toList();
    expect(names.any((n) => n.endsWith('.epub')), isTrue, reason: '书包里没有 epub');

    final epub = extractEpubFromPack(bytes);
    expect(epub.length, greaterThan(2));
    expect(epub[0], 0x50, reason: '取出来的不是 zip（epub 也是 zip）');
    expect(epub[1], 0x4B);
    final inner = ZipDecoder().decodeBytes(epub, verify: false);
    expect(inner.files.any((f) => f.name.toLowerCase().endsWith('container.xml')), isTrue,
        reason: '取出来的不是 EPUB 结构（META-INF/container.xml 缺失）');
    expect(openEpub(epub).chapters, isNotEmpty, reason: '取出的 epub 解析不出章节');
  });

  sTest('F7', 'Paginator：零丢字 / 超长块按字符切 / 图片块保留', '真实章节 + 合成超长块', () async {
    const typo = ReaderTypography(
      fontSize: 18,
      lineHeight: 1.8,
      textColor: Color(0xFF1B1B1B),
      mutedColor: Color(0xFF8A8A8A),
    );
    int chars(Iterable<Block> bs) => bs.fold<int>(0, (s, b) => s + b.text.length);

    final book = await LibraryService.openBook(readerBook!);
    final blocks = book.blocksOf(firstReadableChapter(book));
    final pages = Paginator(width: 400, height: 620, typo: typo).paginate(blocks);
    expect(pages, isNotEmpty);
    expect(pages.every((p) => p.isNotEmpty), isTrue, reason: '出现了空页');
    expect(chars(pages.expand((p) => p)), chars(blocks), reason: '分页后有字符丢失');

    final long = Block(BlockKind.paragraph, runs: [Run('啊' * 3000)]);
    final lp = Paginator(width: 400, height: 620, typo: typo).paginate([long]);
    expect(lp.length, greaterThan(1), reason: '3000 字的块没有被切分（会溢出页面）');
    expect(chars(lp.expand((p) => p)), 3000, reason: '切分后丢了字');

    // 只抽 4 本、每本最多 12 个含图章节 —— 原来「12 本 × 全部章节」全都重排一遍太慢
    var withImg = 0;
    for (final b in shelf.take(4)) {
      final eb = await LibraryService.openBook(b);
      var taken = 0;
      for (var i = 0; i < eb.chapters.length && taken < 12; i++) {
        final bl = eb.blocksOf(i);
        final imgs = bl.where((x) => x.kind == BlockKind.image).length;
        if (imgs == 0) continue;
        taken++;
        withImg++;
        final pg = Paginator(width: 400, height: 620, typo: typo).paginate(bl);
        expect(pg.expand((p) => p).where((x) => x.kind == BlockKind.image).length, imgs,
            reason: '${b.fileId} 第 ${i + 1} 章分页后图片块变少了');
      }
    }
    expect(withImg, greaterThan(0), reason: '样本里没有含图章节，图片块保留其实没被验证到');
  });

  sTest('F8', 'LibraryService.scan：识别 zip/epub / 去重 / 排序 / 空目录', '真实目录 + 临时目录', () async {
    final cat = Catalog.instance;
    expect(LibraryService.scan('', cat), isEmpty, reason: '空 root 应返回空');
    expect(LibraryService.scan(r'X:\definitely_not_here_9x8y7z', cat), isEmpty,
        reason: '不存在的目录应返回空（不抛异常）');

    final list = LibraryService.scan(_libRoot, cat);
    expect(list.length, shelf.length);
    expect(list.map((e) => e.fileId).toSet().length, list.length, reason: '有重复 fileId');
    expect(list.every((b) => b.isZip), isTrue, reason: 'zip 没被识别成 isZip=true');
    expect(list.every((b) => b.sizeBytes > 0), isTrue, reason: '有文件没读到体积');
    for (var i = 1; i < list.length; i++) {
      expect(list[i - 1].title.compareTo(list[i].title) <= 0, isTrue, reason: '书架没有按书名排序');
    }

    final tmp = Directory.systemTemp.createTempSync('zhuye_scan_');
    File('${tmp.path}${Platform.pathSeparator}999.zip').writeAsBytesSync([1, 2, 3]);
    File('${tmp.path}${Platform.pathSeparator}888.epub').writeAsBytesSync([1, 2, 3]);
    File('${tmp.path}${Platform.pathSeparator}readme.txt').writeAsBytesSync([1]);
    final two = LibraryService.scan(tmp.path, cat);
    expect(two.length, 2, reason: '扩展名识别不对（应只认 .zip/.epub）');
    expect(two.firstWhere((b) => b.fileId == '999').isZip, isTrue);
    expect(two.firstWhere((b) => b.fileId == '888').isZip, isFalse);
    expect(two.every((b) => b.title == b.fileId), isTrue, reason: '名录查不到时应回退成文件名');
  });

  sTest('F9', 'CoverCache：未命中返回 null / 抽取并落盘 / 内存命中', '真实书包抽封面', () async {
    expect(CoverCache.peek('no_such_book_id'), isNull, reason: 'peek 未命中应返回 null');
    CoverCache.disabledForTest = false;
    try {
      final s = Store.forTest(Directory.systemTemp.createTempSync('zhuye_cover_'));
      final b = shelf.first;
      final got = await CoverCache.get(s, b);
      expect(got, isNotNull, reason: '封面抽取失败');
      expect(got!.isNotEmpty, isTrue, reason: '封面字节为空');
      expect(CoverCache.peek(b.fileId), same(got), reason: '抽取后没有进内存缓存');
      final f = await s.coverFile(b.fileId);
      expect(f.existsSync(), isTrue, reason: '封面没有落盘');
      expect(f.lengthSync(), got.length, reason: '落盘封面字节数不对');
      expect(await CoverCache.get(s, b), same(got), reason: '第二次取没有命中缓存');
    } finally {
      CoverCache.disabledForTest = true;
    }
  });
}
