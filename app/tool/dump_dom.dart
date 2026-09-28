import 'dart:io';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as htmlp;

/// 临时工具：把一份 XHTML 解析后的 DOM 结构打出来，用于排查为什么解析不出内容块。
/// 用法：`dart run tool/dump_dom.dart <文件路径>`
void main(List<String> args) {
  final path = args.isNotEmpty
      ? args[0]
      : r'C:\Users\admin\AppData\Local\Temp\pk2\titlepage.xhtml';
  final f = File(path);
  if (!f.existsSync()) {
    stdout.writeln('NOT FOUND: $path');
    return;
  }
  final html = f.readAsStringSync();
  stdout.writeln('---- raw (first 400) ----');
  stdout.writeln(html.length > 400 ? html.substring(0, 400) : html);

  final doc = htmlp.parse(html);
  final b = StringBuffer();
  void walk(dom.Node n, int d) {
    final pad = '  ' * d;
    if (n is dom.Element) {
      final oh = n.outerHtml;
      final snip = oh.length > 130 ? '${oh.substring(0, 130)}...' : oh;
      b.writeln('$pad<${n.localName}> ns=${n.namespaceUri} attrs=${n.attributes.keys.toList()} :: $snip');
    } else if (n is dom.Text) {
      final t = n.text.trim();
      if (t.isNotEmpty) {
        b.writeln('$pad#text "${t.length > 40 ? t.substring(0, 40) : t}"');
      }
    }
    for (final c in n.nodes) {
      walk(c, d + 1);
    }
  }

  walk(doc, 0);
  stdout.writeln('---- dom ----');
  stdout.writeln(b.toString());
}
