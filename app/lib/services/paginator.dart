import 'package:flutter/widgets.dart';

import 'epub.dart';

/// 分页引擎。
///
/// EPUB 的 CSS 我们不做保真渲染，所以分页也在自己的排版体系里做：
/// 把每个内容块用 TextPainter 量高度，累加进当前页；放不下的块按字符二分切分，
/// 跨页接着排。图片按纵横比折算高度。
class Paginator {
  final double width;
  final double height;
  final ReaderTypography typo;

  /// 文本缩放。**必须和渲染侧一模一样**（阅读页把 `MediaQuery.textScalerOf(context)` 传进来，
  /// 并且 `Text.rich` 也用同一个），否则系统字体放大时「量出来的行数 < 实际行数」→ 页底溢出。
  final TextScaler textScaler;

  Paginator({
    required this.width,
    required this.height,
    required this.typo,
    this.textScaler = TextScaler.noScaling,
  });

  /// 图片最高占页面高度的比例。渲染侧（`reader.dart` 的 _PageContent）必须用同一个上限，
  /// 否则分页算出来的高度和实际渲染高度不一致，图片会撑破页面。
  static const imgMaxFrac = 0.45;

  /// 渲染侧（`reader.dart` 的 `_PageContent._text`）列表项的符号 + 两个空格。
  static const bullet = '·  ';

  double? _bulletW;

  /// 「·  」的真实宽度。**不能拍脑袋按 1.1 个字号算**：
  /// 不同字体差得远（测试字体里每个字形都是一个 fontSize 宽的正方形，
  /// '·  ' 就是 3 个字宽；微软雅黑里只有半个字宽）。
  /// 猜小了 → 量出来的文本比实际宽 → 实际多折一行 → 页底溢出。
  double _bulletWidth() => _bulletW ??= () {
        final tp = TextPainter(
          text: TextSpan(text: bullet, style: typo.body),
          textDirection: TextDirection.ltr,
          textScaler: textScaler,
        )..layout();
        final w = tp.width;
        tp.dispose();
        return w;
      }();

  double _blockHeight(Block b, double w) {
    switch (b.kind) {
      case BlockKind.divider:
        // 渲染侧是 Padding(vertical: 14) + Divider()，而 Divider 自带 16px 高度，
        // 实际占 14+16+14 = 44。这里若按 28 算，每遇到一条分隔线就会多塞 16px 内容。
        return 44;
      case BlockKind.image:
        // 渲染侧是 Padding(vertical: 8) + ConstrainedBox + AspectRatio，上下各 8 → 16。
        return _imageHeight(b, w) + 16;
      default:
        return _measure(b, w) + _spacing(b);
    }
  }

  double _imageHeight(Block b, double w) {
    final aspect = b.aspect <= 0 ? 1.0 : b.aspect;
    var h = w / aspect;
    final cap = height * imgMaxFrac;
    if (h > cap) h = cap;
    return h;
  }

  double _spacing(Block b) {
    switch (b.kind) {
      case BlockKind.heading:
        return typo.fontSize * (b.level <= 1 ? 1.6 : 1.1);
      case BlockKind.paragraph:
        return typo.fontSize * 0.75;
      case BlockKind.quote:
        return typo.fontSize * 0.8;
      case BlockKind.listItem:
        return typo.fontSize * 0.5;
      case BlockKind.pre:
        // 渲染侧 pre 落在 default 分支 —— 下边距和普通段落一样是 0.75 个字号
        // （之前写的是 0.7，每段 pre 都少算 0.05 个字号）。
        return typo.fontSize * 0.75;
      default:
        return 6;
    }
  }

  /// 块内文本的实际可用宽度（标题/引用有额外边距）。
  double _innerWidth(Block b) {
    switch (b.kind) {
      case BlockKind.quote:
        // 渲染侧左右内边距是 fontSize + fontSize*0.5
        return width - typo.fontSize * 1.5;
      case BlockKind.listItem:
        // 渲染侧是 Row['·  ', Expanded(text)]，左边距 fontSize*0.6，
        // 再加符号本身的真实宽度（必须实测，见 _bulletWidth）。
        return width - typo.fontSize * 0.6 - _bulletWidth();
      case BlockKind.pre:
        // 渲染侧 pre 走的是 default 分支（只有下边距、没有额外左右边距），
        // 所以正文宽度就是整个 width。
        return width;
      default:
        return width;
    }
  }

  TextStyle styleOf(Block b) => typo.styleFor(b.kind, b.level);

  double _measure(Block b, double w) {
    if (b.runs.isEmpty) return 0;
    final tp = TextPainter(
      text: blockSpan(b, typo),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      // 必须跟渲染侧一致：reader.dart 的 _PageContent 用的是 TextAlign.justify。
      // 两端对齐会改变中日韩文本的断行位置（字间距被拉伸），
      // 不跟上的话量出来的行数会比实际少一行，页底那行就被裁掉了（实测溢出 23px）。
      textAlign: TextAlign.justify,
    );
    tp.layout(maxWidth: w);
    final h = tp.height;
    tp.dispose();
    return h;
  }

  /// 主入口：把一章切成页。
  List<List<Block>> paginate(List<Block> blocks) {
    final pages = <List<Block>>[];
    var page = <Block>[];
    var used = 0.0;

    // 每页留一点点安全余量：TextPainter 量出来的高度和最终渲染之间总有
    // 几像素的字体度量差异（不同机器上的字体文件也不一样）。
    // 宁可每页少排小半行，也不要页底那行被裁掉。
    final avail = height - typo.fontSize * 0.4;

    void flush() {
      if (page.isNotEmpty) {
        pages.add(page);
        page = <Block>[];
        used = 0;
      }
    }

    for (final original in blocks) {
      var cur = original;
      // 防止极端情况死循环
      var guard = 0;
      while (guard++ < 400) {
        final w = _innerWidth(cur);
        final h = _blockHeight(cur, w);
        if (cur.kind == BlockKind.image) {
          if (used + h > avail && page.isNotEmpty) {
            flush();
            continue;
          }
          page.add(cur);
          used += h;
          break;
        }
        if (used + h <= avail) {
          page.add(cur);
          used += h;
          break;
        }
        if (page.isEmpty) {
          // 一整块都放不下 -> 按字符切
          final head = _splitHead(cur, w, avail);
          if (head == null || head.runs.isEmpty) {
            page.add(cur);
            used = avail;
            flush();
            break;
          }
          page.add(head);
          final consumed = _charsOf(head);
          flush();
          final tail = _dropRuns(cur, consumed);
          if (tail.runs.isEmpty) break;
          cur = tail;
          continue;
        }
        flush();
      }
    }
    flush();

    _fixOrphanHeadings(pages, avail);
    if (pages.isEmpty) pages.add(<Block>[]);
    return pages;
  }

  /// 一页「按本分页器自己的口径」占了多少高度。
  double _usedOf(List<Block> page) =>
      page.fold<double>(0, (s, b) => s + _blockHeight(b, _innerWidth(b)));

  /// 避免标题落在页尾：若某页最后一块是标题，把它挪到下一页开头。
  ///
  /// **必须确认下一页塞得下**：早期实现只是无条件 `insert(0, last)`，
  /// 下一页本来就已经排到 avail 了，硬插一个标题进去必然溢出（实测 34px）。
  void _fixOrphanHeadings(List<List<Block>> pages, double avail) {
    for (var i = 0; i < pages.length - 1; i++) {
      final p = pages[i];
      if (p.isEmpty) continue;
      final last = p.last;
      if (last.kind != BlockKind.heading || p.length <= 1) continue;
      final add = _blockHeight(last, _innerWidth(last));
      if (_usedOf(pages[i + 1]) + add > avail) continue; // 塞不下就别硬挪
      pages[i] = p.sublist(0, p.length - 1);
      pages[i + 1].insert(0, last);
    }
  }

  int _charsOf(Block b) => b.runs.fold<int>(0, (s, r) => s + r.text.length);

  /// 找出能塞进 maxH 的最长前缀（按字符二分）。
  Block? _splitHead(Block b, double w, double maxH) {
    final total = _charsOf(b);
    if (total <= 1) return null;
    var lo = 1;
    var hi = total;
    var best = 0;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      final cand = _takeRuns(b, mid);
      // 切出来的这一块是「本页的最后一块」，它自己那块下边距也会渲染出来，
      // 所以要连 _spacing 一起算进页高。只量文本高度的话，页底会多出半个字号。
      final mh = _measure(cand, w) + _spacing(b) + typo.fontSize * 0.35;
      if (mh <= maxH) {
        best = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (best <= 0) best = 1; // 保证前进
    if (best >= total) return null; // 其实放得下，交给调用方
    return candOf(b, best);
  }

  Block _takeRuns(Block b, int n) => candOf(b, n);

  /// 取前 n 个字符，保留原有 run 样式。
  Block candOf(Block b, int n) {
    final runs = <Run>[];
    var left = n;
    for (final r in b.runs) {
      if (left <= 0) break;
      if (r.text.length <= left) {
        runs.add(r);
        left -= r.text.length;
      } else {
        runs.add(Run(r.text.substring(0, left), bold: r.bold, italic: r.italic));
        left = 0;
      }
    }
    return Block(b.kind, runs: runs, level: b.level, image: b.image, aspect: b.aspect);
  }

  /// 丢掉前 n 个字符，保留剩余 run 样式。
  Block _dropRuns(Block b, int n) {
    final runs = <Run>[];
    var left = n;
    for (final r in b.runs) {
      if (left <= 0) {
        runs.add(r);
        continue;
      }
      if (r.text.length <= left) {
        left -= r.text.length;
      } else {
        runs.add(Run(r.text.substring(left), bold: r.bold, italic: r.italic));
        left = 0;
      }
    }
    return Block(b.kind, runs: runs, level: b.level, image: b.image, aspect: b.aspect);
  }
}

/// 排版参数：字号、行距、颜色，由阅读设置派生。
class ReaderTypography {
  final double fontSize;
  final double lineHeight;
  final Color textColor;
  final Color mutedColor;

  const ReaderTypography({
    required this.fontSize,
    required this.lineHeight,
    required this.textColor,
    required this.mutedColor,
  });

  TextStyle get body => TextStyle(
        fontSize: fontSize,
        height: lineHeight,
        color: textColor,
        // 中文字体优先，避免落到默认的纯西文字体导致字形难看
        fontFamilyFallback: const [
          'Microsoft YaHei',
          'PingFang SC',
          'Noto Sans CJK SC',
          'Source Han Sans SC',
          'SimSun',
        ],
      );

  TextStyle styleFor(BlockKind kind, int level) {
    switch (kind) {
      case BlockKind.heading:
        final scale = switch (level) {
          1 => 1.75,
          2 => 1.45,
          3 => 1.25,
          4 => 1.12,
          _ => 1.05,
        };
        return body.copyWith(
          fontSize: fontSize * scale,
          fontWeight: FontWeight.w700,
          height: lineHeight * 0.92,
        );
      case BlockKind.quote:
        return body.copyWith(color: mutedColor, fontStyle: FontStyle.italic);
      case BlockKind.listItem:
        return body;
      case BlockKind.pre:
        return body.copyWith(fontFamily: 'Consolas', fontFamilyFallback: const ['Consolas', 'Courier New']);
      default:
        return body;
    }
  }
}

/// 把一个块变成富文本 span。
///
/// **分页测量（`Paginator._measure`）和实际渲染（`reader.dart` 的 `_PageContent._text`）
/// 必须共用这一个函数。** 之前两边各写一份，样式树稍有不一致就会「量出来 N 行、实际排 N+1 行」，
/// 页底那行被裁掉（实测溢出 34px / 23px / 19px …）。
InlineSpan blockSpan(Block b, ReaderTypography typo) {
  final base = typo.styleFor(b.kind, b.level);
  return TextSpan(
    style: base,
    children: [
      for (final r in b.runs)
        TextSpan(
          text: r.text,
          // 只覆盖行内样式，其余（字号/行距/字体族）继承上面的 base
          style: TextStyle(
            fontWeight: r.bold ? FontWeight.bold : null,
            fontStyle: r.italic ? FontStyle.italic : null,
          ),
        ),
    ],
  );
}
