import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as htmlp;
import 'package:xml/xml.dart';

// ---------------------------------------------------------------------------
// 内容块模型：EPUB 是 HTML+CSS 打包，我们不做 CSS 保真渲染，
// 而是把每一章抽成结构化块，用自己的排版系统呈现。这样字号/主题/行距才真正可控。
// ---------------------------------------------------------------------------

enum BlockKind { heading, paragraph, quote, listItem, image, divider, pre }

class Run {
  final String text;
  final bool bold;
  final bool italic;
  const Run(this.text, {this.bold = false, this.italic = false});
}

class Block {
  final BlockKind kind;
  final List<Run> runs;
  final int level; // heading 级别 1..6；listItem/itemDepth
  final Uint8List? image;
  final double aspect; // 图片 宽/高

  const Block(this.kind, {this.runs = const [], this.level = 0, this.image, this.aspect = 1.0});

  String get text => runs.map((r) => r.text).join();
}

class EpubChapter {
  final String title;
  final String href;
  const EpubChapter(this.title, this.href);
}

class EpubBook {
  final String title;
  final String author;
  final String language;
  final List<EpubChapter> chapters;
  final Uint8List? cover;
  final double coverAspect;

  /// 内部持有 zip；章节正文按需解析并缓存。
  final Archive _arc;
  final Map<String, List<Block>> _cache = {};
  final Map<String, Uint8List?> _imgCache = {};

  EpubBook({
    required this.title,
    required this.author,
    required this.language,
    required this.chapters,
    required this.cover,
    required this.coverAspect,
    required Archive arc,
    // 命名参数不能用 this._arc 形式（私有名不能做命名参数），只能显式赋值
    // ignore: prefer_initializing_formals
  }) : _arc = arc;

  /// 某个 EPUB 内部路径的原始字节。
  Uint8List? rawOf(String path) {
    if (_imgCache.containsKey(path)) return _imgCache[path];
    final f = _findEntry(path);
    Uint8List? out;
    if (f != null) {
      final c = f.content;
      if (c is Uint8List) {
        out = c;
      } else if (c is List<int>) {
        out = Uint8List.fromList(c);
      }
    }
    _imgCache[path] = out;
    return out;
  }

  ArchiveFile? _findEntry(String path) {
    final norm = _norm(path);
    for (final f in _arc.files) {
      if (_norm(f.name) == norm) return f;
    }
    // 退一步：按结尾匹配（有些 epub 的容器路径有前缀差异）
    for (final f in _arc.files) {
      if (_norm(f.name).endsWith('/$norm')) return f;
    }
    return null;
  }

  /// 解析第 index 章为内容块（带缓存）。
  List<Block> blocksOf(int index) {
    if (index < 0 || index >= chapters.length) return const [];
    final href = chapters[index].href;
    final hit = _cache[href];
    if (hit != null) return hit;
    final blocks = _parseChapter(href);
    _cache[href] = blocks;
    return blocks;
  }

  List<Block> _parseChapter(String href) {
    final raw = rawOf(href);
    if (raw == null) return const [Block(BlockKind.paragraph, runs: [Run('（该章节内容缺失）')])];
    String html;
    try {
      html = utf8.decode(raw, allowMalformed: true);
    } catch (_) {
      html = String.fromCharCodes(raw);
    }
    dom.Document doc;
    try {
      doc = htmlp.parse(html);
    } catch (_) {
      return [Block(BlockKind.paragraph, runs: [Run(html.replaceAll(RegExp(r'<[^>]+>'), ''))])];
    }
    final body = doc.body ?? doc.documentElement;
    if (body == null) return const [];
    final out = <Block>[];
    _walk(body, out, href);
    return out;
  }

  void _walk(dom.Element el, List<Block> out, String base) {
    for (final node in el.nodes) {
      if (node is dom.Text) {
        final t = _clean(node.text);
        if (t.isNotEmpty) {
          out.add(Block(BlockKind.paragraph, runs: [Run(t)]));
        }
        continue;
      }
      if (node is! dom.Element) continue;
      final tag = node.localName?.toLowerCase() ?? '';
      if (tag == 'script' || tag == 'style' || tag == 'head') continue;

      if (RegExp(r'^h[1-6]$').hasMatch(tag)) {
        final runs = _inline(node, base, out);
        final t = runs.map((r) => r.text).join();
        if (t.isNotEmpty) {
          out.add(Block(BlockKind.heading, runs: runs, level: int.parse(tag.substring(1))));
        }
      } else if (tag == 'p') {
        final runs = _inline(node, base, out);
        final t = runs.map((r) => r.text).join();
        if (t.isNotEmpty) out.add(Block(BlockKind.paragraph, runs: runs));
      } else if (tag == 'blockquote') {
        final runs = _inline(node, base, out);
        final t = runs.map((r) => r.text).join();
        if (t.isNotEmpty) out.add(Block(BlockKind.quote, runs: runs));
      } else if (tag == 'li') {
        final runs = _inline(node, base, out);
        final t = runs.map((r) => r.text).join();
        if (t.isNotEmpty) out.add(Block(BlockKind.listItem, runs: runs));
      } else if (tag == 'hr') {
        out.add(const Block(BlockKind.divider));
      } else if (tag == 'pre') {
        final t = node.text.trimRight();
        if (t.isNotEmpty) out.add(Block(BlockKind.pre, runs: [Run(t)]));
      } else if (tag == 'img' || tag == 'image') {
        // 'image' 是 SVG 里的写法：calibre 生成的封面页固定长这样
        //   <svg><image xlink:href="cover.jpeg"/></svg>
        // 不认它的话封面页解析出来就是 0 个块（打开书一片空白）。
        final b = _imageBlock(node, base);
        if (b != null) out.add(b);
      } else if (tag == 'br') {
        // 独立 br 忽略
      } else {
        // div / section / article / span / table / 其他容器 → 递归
        _walk(node, out, base);
      }
    }
  }

  List<Run> _inline(dom.Element el, String base, List<Block> out) {
    final runs = <Run>[];
    void emit(String text, {bool bold = false, bool italic = false}) {
      final t = _clean(text);
      if (t.isEmpty) return;
      if (runs.isNotEmpty && runs.last.bold == bold && runs.last.italic == italic) {
        runs[runs.length - 1] = Run(runs.last.text + t, bold: bold, italic: italic);
      } else {
        runs.add(Run(t, bold: bold, italic: italic));
      }
    }

    void walk(dom.Node n, bool bold, bool italic) {
      if (n is dom.Text) {
        emit(n.text, bold: bold, italic: italic);
        return;
      }
      if (n is! dom.Element) return;
      final tag = n.localName?.toLowerCase() ?? '';
      if (tag == 'script' || tag == 'style') return;
      if (tag == 'br') {
        emit('\n', bold: bold, italic: italic);
        return;
      }
      if (tag == 'img' || tag == 'image') {
        final b = _imageBlock(n, base);
        if (b != null) out.add(b);
        return;
      }
      final nb = bold || tag == 'b' || tag == 'strong';
      final ni = italic || tag == 'i' || tag == 'em';
      for (final c in n.nodes) {
        walk(c, nb, ni);
      }
    }

    for (final c in el.nodes) {
      walk(c, false, false);
    }
    return runs.where((r) => r.text.isNotEmpty).toList();
  }

  /// 取元素属性。
  ///
  /// 坑：`package:html` 里带命名空间的属性（SVG 的 `xlink:href`）在 `attributes` 里的
  /// key 不是字符串而是带命名空间的对象，`attributes['xlink:href']` 取不到值。
  /// calibre 生成的封面页正是 `<image xlink:href="cover.jpeg"/>`，
  /// 取不到 src 就整页解析成 0 个块（表现为打开书一片空白）。
  String? _attr(dom.Element el, String name) {
    final direct = el.attributes[name];
    if (direct != null) return direct;
    for (final e in el.attributes.entries) {
      final s = e.key.toString();
      if (s == name || s.endsWith(':$name')) return e.value;
    }
    return null;
  }

  Block? _imageBlock(dom.Element img, String base) {
    final src = _attr(img, 'src') ?? _attr(img, 'xlink:href') ?? _attr(img, 'href');
    if (src == null || src.isEmpty) return null;
    if (src.startsWith('data:')) {
      final i = src.indexOf('base64,');
      if (i < 0) return null;
      try {
        final bytes = base64Decode(src.substring(i + 7));
        return Block(BlockKind.image, image: bytes, aspect: 0.75);
      } catch (_) {
        return null;
      }
    }
    final path = _resolve(base, src);
    final bytes = rawOf(path);
    if (bytes == null || bytes.isEmpty) return null;
    return Block(BlockKind.image, image: bytes, aspect: _aspectOf(bytes));
  }

  List<ChapterRefLite>? _pendingToc;

  void attachToc(List<ChapterRefLite> toc) => _pendingToc = toc;

  List<ChapterRefLite>? get toc => _pendingToc;
}

/// 供内部使用的最小章节引用（避免 models.dart 循环依赖）。
class ChapterRefLite {
  final String title;
  final String href;
  const ChapterRefLite(this.title, this.href);
}

class _OpfItem {
  final String id;
  final String href;
  final String mediaType;
  final String properties;
  const _OpfItem(this.id, this.href, this.mediaType, this.properties);
}

String _norm(String p) {
  var s = p.replaceAll('\\', '/');
  if (s.startsWith('/')) s = s.substring(1);
  // 必须折叠 '..'：EPUB 的封面/插图大量写成 '../Images/cover.jpg' 这类相对路径，
  // 不折叠的话 resolve 出来的路径在 zip 里根本不存在 → 封面和插图会整片消失
  // （表现为“封面页解析出 0 个块”，阅读器打开就是白屏）。
  final out = <String>[];
  for (final seg in s.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    out.add(seg);
  }
  return out.join('/');
}

String _dirOf(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i);
}

String _resolve(String base, String rel) {
  if (rel.startsWith('/')) return _norm(rel);
  var path = rel;
  final q = path.indexOf('?');
  if (q >= 0) path = path.substring(0, q);
  final h = path.indexOf('#');
  if (h >= 0) path = path.substring(0, h);
  var decoded = path;
  try {
    decoded = Uri.decodeFull(path);
  } catch (_) {}
  return _norm('${_dirOf(base)}/$decoded');
}

String _clean(String s) => s.replaceAll('\u00a0', ' ').replaceAll(RegExp(r'[ \t\r]+'), ' ').trim();

/// 从图片字节里读宽高（支持 PNG / JPEG / GIF / WEBP）。
double _aspectOf(Uint8List b) {
  try {
    // PNG
    if (b.length > 24 && b[0] == 0x89 && b[1] == 0x50) {
      final w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
      final h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
      if (w > 0 && h > 0) return w / h;
    }
    // GIF
    if (b.length > 10 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
      final w = b[6] | (b[7] << 8);
      final h = b[8] | (b[9] << 8);
      if (w > 0 && h > 0) return w / h;
    }
    // JPEG
    if (b.length > 4 && b[0] == 0xFF && b[1] == 0xD8) {
      var i = 2;
      while (i + 9 < b.length) {
        if (b[i] != 0xFF) {
          i++;
          continue;
        }
        final m = b[i + 1];
        if (m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) {
          final h = (b[i + 5] << 8) | b[i + 6];
          final w = (b[i + 7] << 8) | b[i + 8];
          if (w > 0 && h > 0) return w / h;
        }
        final len = (b[i + 2] << 8) | b[i + 3];
        if (len <= 0) break;
        i += 2 + len;
      }
    }
  } catch (_) {}
  return 0.75;
}

// ---------------------------------------------------------------------------
// EPUB 打开入口
// ---------------------------------------------------------------------------

/// 打开一个 EPUB 字节流。
EpubBook openEpub(Uint8List epubBytes) {
  final arc = ZipDecoder().decodeBytes(epubBytes, verify: false);

  ArchiveFile? find(String name) {
    final n = _norm(name);
    for (final f in arc.files) {
      if (_norm(f.name) == n) return f;
    }
    return null;
  }

  Uint8List? bytesOf(ArchiveFile? f) {
    if (f == null) return null;
    final c = f.content;
    if (c is Uint8List) return c;
    if (c is List<int>) return Uint8List.fromList(c);
    return null;
  }

  // ① container.xml → OPF 路径
  final container = bytesOf(find('META-INF/container.xml'));
  String opfPath = '';
  if (container != null) {
    try {
      final doc = XmlDocument.parse(utf8.decode(container, allowMalformed: true));
      for (final e in doc.findAllElements('rootfile')) {
        final p = e.getAttribute('full-path');
        if (p != null && p.isNotEmpty) {
          opfPath = p;
          break;
        }
      }
    } catch (_) {}
  }
  if (opfPath.isEmpty) {
    // 兜底：找一个 .opf
    for (final f in arc.files) {
      if (_norm(f.name).toLowerCase().endsWith('.opf')) {
        opfPath = f.name;
        break;
      }
    }
  }
  if (opfPath.isEmpty) {
    throw const FormatException('EPUB 缺少 OPF（container.xml 不可解析）');
  }

  final opfBytes = bytesOf(find(opfPath));
  if (opfBytes == null) throw const FormatException('EPUB 的 OPF 文件读不到');
  final opf = XmlDocument.parse(utf8.decode(opfBytes, allowMalformed: true));

  String meta(String name) {
    for (final e in opf.findAllElements(name).followedBy(opf.findAllElements('dc:$name'))) {
      final t = e.innerText.trim();
      if (t.isNotEmpty) return t;
    }
    return '';
  }

  final manifest = <String, _OpfItem>{};
  final byHref = <String, _OpfItem>{};
  for (final it in opf.findAllElements('item')) {
    final id = it.getAttribute('id') ?? '';
    final href = it.getAttribute('href') ?? '';
    if (id.isEmpty || href.isEmpty) continue;
    final item = _OpfItem(
      id,
      _resolve(opfPath, href),
      it.getAttribute('media-type') ?? '',
      it.getAttribute('properties') ?? '',
    );
    manifest[id] = item;
    byHref[item.href] = item;
  }

  final spine = <String>[];
  for (final e in opf.findAllElements('itemref')) {
    final idref = e.getAttribute('idref');
    if (idref != null) spine.add(idref);
  }

  // ② 目录：EPUB3 nav 优先，其次 toc.ncx
  List<ChapterRefLite> toc = [];
  _OpfItem? navItem;
  for (final it in manifest.values) {
    if (it.properties.split(' ').contains('nav') || it.mediaType == 'application/xhtml+xml' && it.id.toLowerCase() == 'nav') {
      navItem = it;
      break;
    }
  }
  if (navItem != null) {
    final nb = bytesOf(find(navItem.href));
    if (nb != null) {
      try {
        final doc = htmlp.parse(utf8.decode(nb, allowMalformed: true));
        for (final a in doc.querySelectorAll('nav a')) {
          final href = a.attributes['href'];
          if (href == null || href.isEmpty) continue;
          toc.add(ChapterRefLite(a.text.trim(), _resolve(navItem.href, href)));
        }
      } catch (_) {}
    }
  }
  if (toc.isEmpty) {
    _OpfItem? ncx;
    for (final it in manifest.values) {
      if (it.mediaType.contains('dtbncx') || it.href.toLowerCase().endsWith('.ncx')) {
        ncx = it;
        break;
      }
    }
    if (ncx != null) {
      final nb = bytesOf(find(ncx.href));
      if (nb != null) {
        try {
          final doc = XmlDocument.parse(utf8.decode(nb, allowMalformed: true));
          for (final np in doc.findAllElements('navPoint')) {
            final label = np.findAllElements('text').isNotEmpty
                ? np.findAllElements('text').first.innerText.trim()
                : '';
            final src = np.findAllElements('content').isNotEmpty
                ? (np.findAllElements('content').first.getAttribute('src') ?? '')
                : '';
            if (src.isEmpty) continue;
            toc.add(ChapterRefLite(label, _resolve(ncx.href, src)));
          }
        } catch (_) {}
      }
    }
  }

  // ③ 章节：以 spine 为准（保证阅读顺序完整），TOC 提供标题
  final titleByHref = <String, String>{};
  for (final t in toc) {
    titleByHref.putIfAbsent(_norm(t.href), () => t.title);
  }
  final chapters = <EpubChapter>[];
  for (final idref in spine) {
    final it = manifest[idref];
    if (it == null) continue;
    if (!(it.mediaType.contains('xhtml') || it.mediaType.contains('html') || it.href.toLowerCase().endsWith('.html') || it.href.toLowerCase().endsWith('.xhtml'))) {
      continue;
    }
    final t = titleByHref[_norm(it.href)] ?? '';
    chapters.add(EpubChapter(t, it.href));
  }
  if (chapters.isEmpty) {
    for (final t in toc) {
      chapters.add(EpubChapter(t.title, t.href));
    }
  }

  // ④ 封面
  Uint8List? cover;
  for (final it in manifest.values) {
    if (it.properties.split(' ').contains('cover-image')) {
      cover = bytesOf(find(it.href));
      if (cover != null) break;
    }
  }
  if (cover == null) {
    for (final e in opf.findAllElements('meta')) {
      if ((e.getAttribute('name') ?? '') == 'cover') {
        final cid = e.getAttribute('content');
        if (cid != null && manifest.containsKey(cid)) {
          cover = bytesOf(find(manifest[cid]!.href));
        }
        break;
      }
    }
  }

  final book = EpubBook(
    title: meta('title'),
    author: meta('creator'),
    language: meta('language'),
    chapters: chapters,
    cover: cover,
    coverAspect: cover == null ? 0.7 : _aspectOf(cover),
    arc: arc,
  );
  book.attachToc(toc);
  return book;
}

/// 从城通书包（zip）里取出 EPUB 字节。包内同时有 azw3/epub/mobi 三种格式。
Uint8List extractEpubFromPack(Uint8List packBytes) {
  final arc = ZipDecoder().decodeBytes(packBytes, verify: false);
  ArchiveFile? best;
  for (final f in arc.files) {
    if (!f.isFile) continue;
    final n = f.name.toLowerCase();
    if (n.endsWith('.epub')) {
      best = f;
      break;
    }
  }
  if (best == null) throw const FormatException('书包里没有 .epub');
  final c = best.content;
  if (c is Uint8List) return c;
  if (c is List<int>) return Uint8List.fromList(c);
  throw const FormatException('书包内的 epub 读取失败');
}

/// 判断一章是不是「目录页」：calibre 转出来的书常带这样一章，
/// 正文就是一列光秃秃的数字/极短词（1 2 3 … 28 致 谢）。
/// 落在它上面等于一打开书就看到废页，所以选落脚点时要跳过。
/// 判据：非标题段落 ≥6 个，且其中 ≥60% 长度 ≤4 字。
bool looksLikeTocChapter(List<Block> blocks) {
  final paras = blocks
      .where((b) => b.kind != BlockKind.image && b.kind != BlockKind.heading)
      .toList();
  if (paras.length < 6) return false;
  var short = 0;
  for (final b in paras) {
    if (b.text.trim().length <= 4) short++;
  }
  return short / paras.length >= 0.6;
}

/// 阅读器打开书的落脚点（reader 与验收测试共用，保证两边判定一致）：
/// ① 第一个「有文字且不是目录页」的章节；
/// ② 退而求其次：第一个有文字的章节（哪怕像目录页）；
/// ③ 再退：第一个非空章节；④ 实在不行停在 [from]。
int firstReadableChapter(EpubBook b, {int from = 0}) {
  for (var i = from; i < b.chapters.length; i++) {
    final bl = b.blocksOf(i);
    if (bl.any((x) => x.kind != BlockKind.image) && !looksLikeTocChapter(bl)) {
      return i;
    }
  }
  for (var i = from; i < b.chapters.length; i++) {
    if (b.blocksOf(i).any((x) => x.kind != BlockKind.image)) return i;
  }
  for (var i = from; i < b.chapters.length; i++) {
    if (b.blocksOf(i).isNotEmpty) return i;
  }
  return from;
}
