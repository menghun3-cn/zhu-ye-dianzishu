import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhu_ye_reader/services/epub.dart';
import 'package:zhu_ye_reader/services/paginator.dart';

/// 端到端回归：拿**真实下载下来的城通书包**跑一遍完整阅读链路
/// zip → 抽出 epub → 解析 OPF/NCX → 结构化 Block → 分页。
///
/// 书库目录不存在时（例如换机器 / CI）自动跳过，不会让测试变红。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const root = r'E:\chinabook';

  test('真实书包：zip → epub → 结构化块 → 分页', () {
    final dir = Directory(root);
    if (!dir.existsSync()) {
      markTestSkipped('书库目录不存在，跳过：$root');
      return;
    }
    final zips = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.zip'))
        .toList()
      ..sort((a, b) => a.lengthSync().compareTo(b.lengthSync()));
    if (zips.isEmpty) {
      markTestSkipped('书库里还没有书包，跳过');
      return;
    }

    // 取体积最大的一本，对解析和分页的压力最大
    final f = zips.last;
    final packBytes = f.readAsBytesSync();
    final epubBytes = extractEpubFromPack(packBytes);
    expect(epubBytes.length, greaterThan(1000));

    final book = openEpub(epubBytes);
    expect(book.title, isNotEmpty, reason: 'OPF 里应能取到书名');
    expect(book.chapters, isNotEmpty, reason: 'spine/NCX 应解析出章节');

    const typo = ReaderTypography(
      fontSize: 18,
      lineHeight: 1.8,
      textColor: Color(0xFF111111),
      mutedColor: Color(0xFF888888),
    );
    final pg = Paginator(width: 360, height: 640, typo: typo);

    var pages = 0;
    var chars = 0;
    for (var i = 0; i < book.chapters.length; i++) {
      final blocks = book.blocksOf(i);
      final p = pg.paginate(blocks);
      expect(p, isNotEmpty, reason: '第 $i 章至少要产出一页');
      pages += p.length;
      chars += blocks.map((b) => b.text).join().length;
    }
    expect(chars, greaterThan(500), reason: '整本正文应有实际内容');

    // ignore: avoid_print
    print('REAL PACK OK  file=${f.uri.pathSegments.last} '
        'title="${book.title}" chapters=${book.chapters.length} '
        'pages=$pages chars=$chars '
        'packMB=${(packBytes.length / 1048576).toStringAsFixed(2)}');
  });
}
