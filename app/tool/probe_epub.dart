import 'dart:io';

import 'package:zhu_ye_reader/services/epub.dart';

/// 临时工具：对单个 epub 文件跑真实解析路径，打印每章产出的块。
/// 用法：`dart run tool/probe_epub.dart <epub 或 zip 路径>`
void main(List<String> args) {
  final path = args.isNotEmpty
      ? args[0]
      : r'C:\Users\admin\AppData\Local\Temp\pk2\unzipped.zip';
  final f = File(path);
  if (!f.existsSync()) {
    stdout.writeln('NOT FOUND: $path');
    return;
  }
  final bytes = f.readAsBytesSync();
  final book = openEpub(bytes);
  stdout.writeln('title="${book.title}" chapters=${book.chapters.length} cover=${book.cover?.length ?? -1}');
  final n = book.chapters.length < 5 ? book.chapters.length : 5;
  for (var i = 0; i < n; i++) {
    final ch = book.chapters[i];
    final bl = book.blocksOf(i);
    stdout.writeln('ch$i href=${ch.href} title="${ch.title}" blocks=${bl.length} '
        'kinds=${bl.map((b) => b.kind.name).join(",")}');
    for (final b in bl.take(3)) {
      final t = b.text;
      stdout.writeln('     [${b.kind.name}] text="${t.length > 40 ? t.substring(0, 40) : t}" img=${b.image?.length ?? 0}');
    }
  }
  stdout.writeln('raw cover.jpeg = ${book.rawOf('cover.jpeg')?.length}');
  stdout.writeln('raw text/part0004.html = ${book.rawOf('text/part0004.html')?.length}');
}
