import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhu_ye_reader/models.dart';
import 'package:zhu_ye_reader/services/catalog.dart';
import 'package:zhu_ye_reader/services/covers.dart';
import 'package:zhu_ye_reader/services/epub.dart';
import 'package:zhu_ye_reader/services/library.dart';
import 'package:zhu_ye_reader/services/paginator.dart';
import 'package:zhu_ye_reader/ui/reader.dart';

/// 分页 ↔ 渲染一致性回归测试。
///
/// 守住的不变量：**Paginator 量出来的页高 == `_PageContent` 真正渲染出来的页高**。
/// 破了这个不变量，页底就会 `RenderFlex overflowed`，最后一行被裁掉
/// （历史上反复出现：文字页溢出 34px / 23px / 19px，全是被这个不变量漏掉的）。
///
/// 坑：`testWidgets` 里的假时钟会卡住真实文件 IO —— 解析 EPUB 必须放在 `setUpAll`
/// （那是真异步环境），`testWidgets` 里只做「渲染 + 断言」。
const _libRoot = r'E:\chinabook';
const _w = 856.0;
const _h = 1368.0;

const _typo = ReaderTypography(
  fontSize: 18,
  lineHeight: 1.8,
  textColor: Color(0xFF1B1B1B),
  mutedColor: Color(0xFF8A8A8A),
);

typedef _Sample = (String label, List<Block> blocks);

List<_Sample> _realSamples = const [];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    CoverCache.disabledForTest = true;
    await Catalog.load();
    if (!Directory(_libRoot).existsSync()) return;

    final shelf = LibraryService.scan(_libRoot, Catalog.instance);
    if (shelf.isEmpty) return;

    // 先在整库上等距抽样，量一下每本书「落地章」页数，再挑页数最多的 3 本 ——
    // 页数多的章才最容易踩到分页边界（早先随机挑了最厚的一本，9 章加起来才 12 页，
    // 等于没压到分页器）。
    final bySize = [...shelf]..sort((a, b) => a.sizeBytes.compareTo(b.sizeBytes));
    final probe = <(int, ShelfBook)>[];
    for (var i = 0; i < bySize.length; i += 3) {
      final b = bySize[i];
      final eb = await LibraryService.openBook(b);
      final land = firstReadableChapter(eb);
      probe.add(
          (Paginator(width: _w, height: _h, typo: _typo).paginate(eb.blocksOf(land)).length, b));
    }
    probe.sort((a, b) => b.$1.compareTo(a.$1));

    final out = <_Sample>[];
    for (final p in probe.take(3)) {
      final book = p.$2;
      final epub = await LibraryService.openBook(book);
      final land = firstReadableChapter(epub);
      for (var ch = land; ch < land + 3 && ch < epub.chapters.length; ch++) {
        final pages = Paginator(width: _w, height: _h, typo: _typo).paginate(epub.blocksOf(ch));
        for (var i = 0; i < pages.length; i++) {
          if (pages[i].isEmpty) continue;
          out.add(('${book.title} 第 ${ch + 1} 章 第 ${i + 1}/${pages.length} 页', pages[i]));
        }
      }
    }
    _realSamples = out;
  });

  /// 把一页正文按**真实排版**渲染出来，返回是否溢出。
  ///
  /// 注意：溢出不会体现在 size 上（Column 的 size 恒等于约束 1368），
  /// 只会由 RenderFlex 在 layout/paint 阶段报 assertion，被测试框架记成「待处理异常」。
  Future<bool> renderPage(WidgetTester tester, List<Block> blocks) async {
    while (tester.takeException() != null) {}
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(colorSchemeSeed: const Color(0xFF2E7D32), useMaterial3: true),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: _w,
            height: _h,
            child: buildPageContentForTest(
              blocks: blocks,
              typo: _typo,
              pal: ReaderPalette.of(ReaderTheme.light),
              maxHeight: _h,
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    return tester.takeException() != null;
  }

  testWidgets('合成边界块逐页无溢出（列表项 / 引用 / 分隔线 / 代码块 / 各级标题 / 超长块切页）',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    List<Block> para(String s) => [Block(BlockKind.paragraph, runs: [Run(s)])];
    final long = '在悲剧选择中，社会分配悲剧有四个策略：市场化分配、政治分配、抽签、以及惯例。'
        '市场化分配是分散决策，但价高者得这一机制，不可避免地把资源导向出价最高的人。';

    final suites = <String, List<Block>>{
      '纯段落': [
        for (var i = 0; i < 120; i++) Block(BlockKind.paragraph, runs: [Run('$long（第 $i 段）')]),
      ],
      '列表项': [for (var i = 0; i < 90; i++) Block(BlockKind.listItem, runs: [Run('列表项 $i：$long')])],
      '引用': [for (var i = 0; i < 75; i++) Block(BlockKind.quote, runs: [Run('引用 $i：$long')])],
      '分隔线': [for (var i = 0; i < 60; i++) ...[Block(BlockKind.divider), ...para(long)]],
      '代码块': [
        for (var i = 0; i < 75; i++)
          Block(BlockKind.pre, runs: [Run('final x$i = "$long"; // code line')]),
      ],
      '各级标题': [
        for (var i = 0; i < 90; i++)
          Block(BlockKind.heading, level: (i % 5) + 1, runs: [Run('第 $i 节 标题$long')]),
      ],
      '混排（标题+正文+列表+引用+分隔线）': [
        for (var i = 0; i < 40; i++) ...[
          Block(BlockKind.heading, level: (i % 3) + 1, runs: [Run('第 $i 章 $long')]),
          ...para(long),
          Block(BlockKind.listItem, runs: [Run(long)]),
          Block(BlockKind.quote, runs: [Run(long)]),
          Block(BlockKind.divider),
        ],
      ],
      '超长单块（5000 字按字符切页）': [Block(BlockKind.paragraph, runs: [Run('啊' * 5000)])],
    };

    final bad = <String>[];
    var pages = 0;
    for (final e in suites.entries) {
      final list = Paginator(width: _w, height: _h, typo: _typo).paginate(e.value);
      for (var i = 0; i < list.length; i++) {
        if (list[i].isEmpty) continue;
        pages++;
        if (await renderPage(tester, list[i])) bad.add('${e.key} 第 ${i + 1}/${list.length} 页');
      }
    }
    expect(pages, greaterThan(50), reason: '合成用例的页数太少，没真正压到分页器');
    expect(bad, isEmpty, reason: '这些页在真实渲染下溢出了：\n${bad.join('\n')}');
  });

  testWidgets('真实书包逐页渲染无溢出（落地章起 3 章 × 3 本）', (tester) async {
    if (_realSamples.isEmpty) {
      markTestSkipped('书库不存在或为空：$_libRoot');
      return;
    }
    tester.view.physicalSize = const Size(900, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final bad = <String>[];
    var pages = 0;
    for (final s in _realSamples) {
      pages++;
      if (await renderPage(tester, s.$2)) bad.add(s.$1);
    }
    expect(pages, greaterThan(20), reason: '样本页太少，没能真正验证');
    expect(bad, isEmpty, reason: '真实章节里有 ${bad.length} 页渲染溢出：\n${bad.take(20).join('\n')}');
  });
}
