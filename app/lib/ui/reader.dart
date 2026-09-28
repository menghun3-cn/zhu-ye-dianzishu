import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../services/epub.dart';
import '../services/library.dart';
import '../services/paginator.dart';
import '../services/store.dart';

class ReaderPalette {
  final Color bg;
  final Color fg;
  final Color muted;
  final Color bar;
  const ReaderPalette(this.bg, this.fg, this.muted, this.bar);

  static ReaderPalette of(ReaderTheme t) {
    switch (t) {
      case ReaderTheme.light:
        return const ReaderPalette(Color(0xFFFCFCFA), Color(0xFF1B1B1B), Color(0xFF8A8A8A), Color(0xFFFFFFFF));
      case ReaderTheme.sepia:
        return const ReaderPalette(Color(0xFFF4ECD8), Color(0xFF3B2F1E), Color(0xFF8C7B5E), Color(0xFFEFE6D0));
      case ReaderTheme.dark:
        return const ReaderPalette(Color(0xFF14161A), Color(0xFFC8CBD0), Color(0xFF6C727C), Color(0xFF1C1F24));
    }
  }
}

class ReaderPage extends StatefulWidget {
  final ShelfBook book;
  final Store store;
  const ReaderPage({super.key, required this.book, required this.store});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  EpubBook? _book;
  String? _error;
  int _chapter = 0;
  int _page = 0;
  List<List<Block>> _pages = const [];
  PageController? _pc;
  Size _contentSize = Size.zero;

  /// 上一轮分页用的文本缩放。系统字体缩放变了要重新分页，
  /// 否则「按老缩放量的行数」和「按新缩放渲染的行数」对不上 → 页底溢出。
  TextScaler _scaler = TextScaler.noScaling;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _keys = FocusNode(debugLabel: 'reader');
  final _tocCtrl = ScrollController();
  bool _showBars = true;

  /// 目录每一项的固定高度。固定下来，ScrollController 才能把「当前章」精确滚到眼前，
  /// 而不是让用户在几百章的列表里手滚。
  static const double _tocItemExtent = 44;

  /// 跨章到「上一章最后一页」时，总页数要等分页跑完才知道，
  /// 先记个标记，_repaginate 算出页表后再落到末页。
  bool _pendingAtEnd = false;

  /// 按下时的局部坐标，用于在 pointerUp 里判断「点按」还是「拖动」。
  Offset? _downPos;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final b = await LibraryService.openBook(widget.book);
      if (!mounted) return;
      final p = widget.store.progressOf(widget.book.fileId);
      final resume = (p?.chapterIndex ?? 0).clamp(0, (b.chapters.length - 1).clamp(0, 1 << 30));
      // 卷首基本都是封面页/版权页（只有图、没有文字）。落在这类页面上等于让用户一打开
      // 就看见"啥也没有"，所以直接推到第一个有文字的章节。
      final ch = _firstReadableFrom(b, resume);
      setState(() {
        _book = b;
        _chapter = ch;
        _page = ch == resume ? (p?.pageIndex ?? 0) : 0;
      });
      if (ch != resume) widget.store.setProgress(widget.book.fileId, ch, 0);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// 从 from 起往后找第一个真正有文字的章节（封面/版权这类纯图页会被跳过）。
  /// 实在找不到就退回第一个非空章节，再不行就停在 from。
  int _firstReadableFrom(EpubBook b, int from) => firstReadableChapter(b, from: from);

  ReaderTypography _typo() {
    final s = widget.store.settings;
    final pal = ReaderPalette.of(s.theme);
    return ReaderTypography(
      fontSize: 18.0 * s.fontScale,
      lineHeight: s.lineHeight,
      textColor: pal.fg,
      mutedColor: pal.muted,
    );
  }

  void _repaginate(Size size, TextScaler scaler) {
    final bk = _book;
    if (bk == null) return;
    if (_contentSize == size && _scaler == scaler && _pages.isNotEmpty) return;
    _contentSize = size;
    _scaler = scaler;
    final blocks = bk.blocksOf(_chapter);
    final p = Paginator(width: size.width, height: size.height, typo: _typo(), textScaler: scaler);
    final pages = p.paginate(blocks);
    final changed = pages.length != _pages.length;
    _pages = pages;
    if (_pendingAtEnd) {
      // 从「上一章」往回翻：落在新章的最后一页
      _pendingAtEnd = false;
      _page = pages.isEmpty ? 0 : pages.length - 1;
    } else if (_page >= pages.length) {
      _page = pages.length - 1;
    }
    if (_page < 0) _page = 0;
    _pc?.dispose();
    _pc = PageController(initialPage: _page);
    // 分页是在 layout 阶段（LayoutBuilder 的回调里）做的，这里不能直接 setState。
    // 但底栏（bottomNavigationBar）是在 build 阶段就构造好的，首帧拿到的还是空页表
    // （页码会显示成 "1/0"）。补一帧让页码立刻是对的。
    if (changed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  /// 跳到第 [i] 章。[atEnd] 为真时落在该章最后一页（用于「往回翻到上一章」）。
  void _gotoChapter(int i, {bool atEnd = false}) {
    final bk = _book;
    if (bk == null) return;
    if (i < 0 || i >= bk.chapters.length) return;
    // 跳过没有正文的章节（封面/版权/空白页），避免跳过去还是白屏。
    // 找的方向按「相对当前位置」定：往后跳就往后找，往回跳就往前找 ——
    // 若按 atEnd 定方向，从第 5 章往回跳时遇到第 4 章是空章会被推回第 5 章，等于没动。
    var target = i;
    if (i < _chapter) {
      while (target > 0 && bk.blocksOf(target).isEmpty) {
        target--;
      }
    } else {
      while (target < bk.chapters.length - 1 && bk.blocksOf(target).isEmpty) {
        target++;
      }
    }
    setState(() {
      _chapter = target;
      _page = 0;
      _pages = const [];
      _contentSize = Size.zero;
      _pendingAtEnd = atEnd;
    });
    widget.store.setProgress(widget.book.fileId, target, 0);
  }

  /// [notify] 只在 `dispose()` 里传 false：卸载阶段整棵树是「锁」的，
  /// 这时 notifyListeners 会让 HomeShell.setState 直接抛
  /// `setState() called when widget tree was locked`。
  void _save({bool notify = true}) {
    if (_pages.isEmpty) return;
    widget.store.setProgress(widget.book.fileId, _chapter, _page, notify: notify);
  }

  /// 返回书架。阅读页是 push 上来的，直接 pop 即可（进度已在 _save 里落盘）。
  /// 兜底判断 canPop：万一阅读页是被当根路由挂上去的（深链、测试里的直挂），
  /// 无路可退时保持原样，而不是抛异常。
  void _backToShelf() {
    _save();
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
  }

  String _chapterTitle(int i) {
    final bk = _book!;
    final t = bk.chapters[i].title.trim();
    final nice = _niceChapterTitle(t);
    if (nice != null) return nice;
    // 目录缺失时，用章节首个标题块兜底
    final blocks = bk.blocksOf(i);
    for (final b in blocks.take(6)) {
      if (b.kind == BlockKind.heading && b.text.trim().isNotEmpty) {
        final h = _niceChapterTitle(b.text.trim());
        if (h != null) return h;
      }
    }
    return '第 ${i + 1} 章';
  }

  /// 目录标题兜底美化。不少书源（calibre 转档）的 navLabel 就是光秃秃的
  /// "1"、"2"、"12 标题" —— 直接摆出来是一列数字，很难认。
  /// 这里把它抬成「第 N 章」/「第 N 章 · 标题」；其余标题原样返回。
  /// 返回 null 仅表示入参为空，调用方应继续走下一个兜底。
  String? _niceChapterTitle(String t) {
    if (t.isEmpty) return null;
    final m = RegExp(r'^(\d{1,4})(?:\s*[、.．:：]\s*|\s+)(.+)$').firstMatch(t);
    if (m != null) return '第 ${m.group(1)} 章 · ${(m.group(2) ?? '').trim()}';
    if (RegExp(r'^\d{1,4}$').hasMatch(t)) return '第 $t 章';
    return t;
  }

  @override
  void dispose() {
    // 卸载阶段树是锁的，这里只能「静默落盘」——不能广播（否则 HomeShell.setState 抛异常）。
    _save(notify: false);
    _pc?.dispose();
    _keys.dispose();
    _tocCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 用外层 Focus 收键盘事件（PC 端专属）：
    //   ← / PageUp 上一页   → / PageDown / 空格 下一页
    //   Ctrl+←（或 [ / p）上一章    Ctrl+→（或 ] / n）下一章
    //   Home 本章首页   End 本章末页   Ctrl+Home/Ctrl+End 全书首/末章   Esc 关抽屉/收起工具栏
    // 正文外面套着 SelectionArea，它只处理复制/全选这类键，
    // 其它键会沿焦点链往上冒泡，所以在外层 Focus 上收得到。
    return Focus(
      key: const ValueKey('reader-keys'),
      focusNode: _keys,
      autofocus: true,
      onKeyEvent: _onKey,
      child: _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    final pal = ReaderPalette.of(widget.store.settings.theme);
    final bk = _book;
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: pal.bg,
      drawer: bk == null ? null : _buildTocDrawer(pal),
      appBar: _showBars
          ? AppBar(
              backgroundColor: pal.bar,
              foregroundColor: pal.fg,
              elevation: 0,
              // 必须显式给 leading：Scaffold 只要设了 drawer，就会自动把 leading 换成
              // 「打开抽屉」的汉堡按钮 —— 于是阅读页上**没有任何返回书架的入口**
              // （只剩窗口右上角的关闭按钮，可那是退出整个应用）。
              // 目录改由底栏的「目录」按钮打开（Esc 也能关）。
              leading: IconButton(
                tooltip: '返回上一页（Alt + ←）',
                icon: const Icon(Icons.arrow_back),
                onPressed: _backToShelf,
              ),
              title: Text(
                bk == null ? widget.book.title : _chapterTitle(_chapter),
                style: const TextStyle(fontSize: 16),
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
                IconButton(
                  tooltip: '书签',
                  icon: Icon(_isBookmarked ? Icons.bookmark : Icons.bookmark_border),
                  onPressed: _toggleBookmark,
                ),
                IconButton(
                  tooltip: '排版',
                  icon: const Icon(Icons.text_fields),
                  onPressed: () => _openSettingsSheet(pal),
                ),
              ],
            )
          : null,
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('打不开这本书：\n$_error', style: TextStyle(color: pal.fg))))
          : bk == null
              ? Center(child: CircularProgressIndicator(color: pal.muted))
              : LayoutBuilder(builder: (ctx, c) {
                  const pad = EdgeInsets.fromLTRB(22, 12, 22, 12);
                  final size = Size(c.maxWidth - pad.horizontal, c.maxHeight - pad.vertical);
                  _repaginate(size, MediaQuery.textScalerOf(ctx));
                  final pc = _pc;
                  if (pc == null || _pages.isEmpty) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  // 用 Listener（原始指针事件）而不是 GestureDetector：
                  // 正文外面套了 SelectionArea，它内部注册了 Tap / Pan 识别器，
                  // 在手势竞技场里位于更内层、会把点按和横向拖动都抢走 ——
                  // 表现就是「点左右不翻页、点中间不切工具栏、滑动也不翻页」。
                  // Listener 不参与竞技场，因此必然能收到事件；PageView 则关掉自身滚动，
                  // 翻页统一由这里驱动（鼠标横向拖仍然是选中文字）。
                  return Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (e) => _downPos = e.localPosition,
                    onPointerCancel: (_) => _downPos = null,
                    onPointerUp: (e) {
                      final down = _downPos;
                      _downPos = null;
                      if (down == null) return;
                      final dx = e.localPosition.dx - down.dx;
                      final dy = e.localPosition.dy - down.dy;
                      final touch = e.kind == PointerDeviceKind.touch ||
                          e.kind == PointerDeviceKind.stylus ||
                          e.kind == PointerDeviceKind.invertedStylus;
                      if (touch && dx.abs() > 56 && dx.abs() > dy.abs() * 1.2) {
                        _turn(dx < 0 ? 1 : -1);
                        return;
                      }
                      if (dx.abs() > 12 || dy.abs() > 12) return; // 拖动（多半是在选字）
                      final w = c.maxWidth;
                      if (e.localPosition.dx < w * 0.28) {
                        _turn(-1);
                      } else if (e.localPosition.dx > w * 0.72) {
                        _turn(1);
                      } else if (_page < _pages.length) {
                        // 注意：章末那一屏（「本章完 / 下一章 · X」）不能走这里。
                        // 那一屏唯一的可点区域就是居中的「下一章」按钮，
                        // 而 Listener 是原始指针监听、不参与手势竞技场 ——
                        // 点按钮时它和按钮的 onTap 会**同时**触发，
                        // 结果就是「点下一章 → 章切了，工具栏也一起没了」。
                        setState(() => _showBars = !_showBars);
                      }
                    },
                    child: Padding(
                      padding: pad,
                      child: PageView.builder(
                        controller: pc,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: _pages.length + (_chapter < bk.chapters.length - 1 ? 1 : 0),
                        onPageChanged: (i) {
                          setState(() => _page = i);
                          _save();
                        },
                        itemBuilder: (ctx2, i) {
                          if (i >= _pages.length) {
                            return _ChapterEnd(
                              pal: pal,
                              nextTitle: _chapterTitle(_chapter + 1),
                              onNext: () => _gotoChapter(_chapter + 1),
                            );
                          }
                          final blocks = _pages[i];
                          if (blocks.isEmpty) {
                            // 兜底：真遇到没有正文的章节，给一句人话而不是一片空白
                            return Center(
                              child: Text(
                                '（这一页没有正文）\n可能只是封面页或空白页，翻下一页继续。',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: pal.muted, fontSize: 13, height: 1.8),
                              ),
                            );
                          }
                          return _PageContent(
                            blocks: blocks,
                            typo: _typo(),
                            pal: pal,
                            maxHeight: _contentSize.height,
                            textScaler: _scaler,
                          );
                        },
                      ),
                    ),
                  );
                }),
      bottomNavigationBar: _showBars && bk != null ? _buildBottomBar(pal) : null,
    );
  }

  bool get _isBookmarked =>
      widget.store.isBookmarked(widget.book.fileId, _chapter, _page);

  void _toggleBookmark() {
    final bk = _book;
    if (bk == null) return;
    String excerpt = '';
    if (_page < _pages.length) {
      final t = _pages[_page].map((b) => b.text).join(' ').trim();
      excerpt = t.length > 60 ? t.substring(0, 60) : t;
    }
    widget.store.toggleBookmark(Bookmark(
      fileId: widget.book.fileId,
      chapterIndex: _chapter,
      chapterTitle: _chapterTitle(_chapter),
      pageIndex: _page,
      excerpt: excerpt,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    setState(() {});
  }

  void _turn(int dir) {
    final pc = _pc;
    if (pc == null) return;
    final bk = _book;
    // 章节末尾那张「本章完 · 下一章」也是一屏，先翻到它，再往前才进下一章。
    final hasEnd = bk != null && _chapter < bk.chapters.length - 1;
    final total = _pages.length + (hasEnd ? 1 : 0);
    final target = _page + dir;
    if (target < 0) {
      // 本章第一页再往前翻 → 直接落在上一章的最后一页（读起来才连贯）
      if (dir < 0 && bk != null && _chapter > 0) {
        _gotoChapter(_chapter - 1, atEnd: true);
      }
      return;
    }
    if (target >= total) {
      if (dir > 0 && hasEnd) _gotoChapter(_chapter + 1);
      return;
    }
    pc.animateToPage(target, duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
  }

  /// 打开目录抽屉，并把「当前章」自动滚到眼前。
  /// 几百章的书（实测最长 245 章）靠手滚找位置太费劲。
  void _openToc() {
    _scaffoldKey.currentState?.openDrawer();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_tocCtrl.hasClients) return;
      final want = ((_chapter - 2).clamp(0, 1 << 30)) * _tocItemExtent;
      final max = _tocCtrl.position.maxScrollExtent;
      _tocCtrl.jumpTo(want > max ? max : want);
    });
  }

  /// PC 端键盘快捷键。阅读区被 SelectionArea 包着，它只处理复制/全选，
  /// 方向键这类会沿焦点链冒泡到这里，所以在外层 Focus 上收即可。
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final bk = _book;
    if (bk == null) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final hw = HardwareKeyboard.instance;
    final ctrl = hw.isControlPressed || hw.isMetaPressed;
    final last = bk.chapters.length - 1;

    if (k == LogicalKeyboardKey.escape) {
      if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
        _scaffoldKey.currentState?.closeDrawer();
      } else if (_showBars) {
        setState(() => _showBars = false);
      }
      return KeyEventResult.handled;
    }
    // Alt + ← ：返回书架（Windows 上「后退」的通用按键，和资源管理器/浏览器一致）
    if (k == LogicalKeyboardKey.arrowLeft && hw.isAltPressed) {
      _backToShelf();
      return KeyEventResult.handled;
    }
    // 翻页
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.pageUp) {
      if (ctrl) {
        _gotoChapter(_chapter - 1);
      } else {
        _turn(-1);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight ||
        k == LogicalKeyboardKey.pageDown ||
        k == LogicalKeyboardKey.space) {
      if (ctrl) {
        _gotoChapter(_chapter + 1);
      } else {
        _turn(1);
      }
      return KeyEventResult.handled;
    }
    // 切章
    if (k == LogicalKeyboardKey.bracketLeft || k == LogicalKeyboardKey.keyP) {
      _gotoChapter(_chapter - 1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.bracketRight || k == LogicalKeyboardKey.keyN) {
      _gotoChapter(_chapter + 1);
      return KeyEventResult.handled;
    }
    // 首/末
    if (k == LogicalKeyboardKey.home) {
      if (ctrl) {
        _gotoChapter(0);
      } else if (_pages.isNotEmpty) {
        _pc?.jumpToPage(0);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.end) {
      if (ctrl) {
        _gotoChapter(last);
      } else if (_pages.isNotEmpty) {
        _pc?.jumpToPage(_pages.length - 1);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _buildBottomBar(ReaderPalette pal) {
    final bk = _book!;
    final total = _pages.length;
    // 翻到「本章完」那一屏时 _page == _pages.length（越界一页），滑块必须钳住，
    // 否则 Slider 会因为 value > max 直接断言失败。
    final cur = total <= 0 ? 0 : _page.clamp(0, total - 1);
    // 必须给底栏一个固定高度：Slider 的 `computeDryLayout` 在「高度有界」时会直接返回
    // constraints.maxHeight，而 Scaffold 给 bottomNavigationBar 的约束是「宽紧、高松到整屏」，
    // 于是 Slider 把底栏撑到整屏高、正文区被压成 0 高 —— 表现为「打开书看不到正文」。
    return ColoredBox(
      color: pal.bar,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 52,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(Icons.menu_book, size: 20, color: pal.muted),
                  tooltip: '目录',
                  onPressed: _openToc,
                ),
                IconButton(
                  icon: Icon(Icons.keyboard_double_arrow_left, size: 20, color: pal.muted),
                  tooltip: '上一章（Ctrl + ←）',
                  visualDensity: VisualDensity.compact,
                  onPressed: _chapter > 0 ? () => _gotoChapter(_chapter - 1) : null,
                ),
                Expanded(
                  child: SizedBox(
                    height: 36,
                    child: Slider(
                      value: total <= 1 ? 0 : cur.toDouble(),
                      max: (total - 1).clamp(1, 1 << 30).toDouble(),
                      onChanged: (v) {
                        final i = v.round();
                        _pc?.jumpToPage(i);
                      },
                    ),
                  ),
                ),
                Text('${cur + 1}/$total', style: TextStyle(fontSize: 12, color: pal.muted)),
                const SizedBox(width: 8),
                Text('${_chapter + 1}/${bk.chapters.length}',
                    style: TextStyle(fontSize: 12, color: pal.muted)),
                IconButton(
                  icon: Icon(Icons.keyboard_double_arrow_right, size: 20, color: pal.muted),
                  tooltip: '下一章（Ctrl + →）',
                  visualDensity: VisualDensity.compact,
                  onPressed: _chapter < bk.chapters.length - 1
                      ? () => _gotoChapter(_chapter + 1)
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTocDrawer(ReaderPalette pal) {
    final bk = _book!;
    return Drawer(
      backgroundColor: pal.bar,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.book.title,
                      style: TextStyle(color: pal.fg, fontSize: 17, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text('${bk.chapters.length} 章 · ${widget.book.author}',
                      style: TextStyle(color: pal.muted, fontSize: 12)),
                ],
              ),
            ),
            const Divider(height: 1),
            // 抽屉里也留一个返回入口：底栏「目录」按钮是常用路径，
            // 打开抽屉的人多半是想离开这一章，顺手能直接退回去。
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: Icon(Icons.arrow_back, size: 18, color: pal.muted),
              title: Text('返回上一页', style: TextStyle(color: pal.fg, fontSize: 14)),
              onTap: () {
                Navigator.of(context).pop(); // 先收起抽屉
                _backToShelf();
              },
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                controller: _tocCtrl,
                itemExtent: _tocItemExtent,
                itemCount: bk.chapters.length,
                itemBuilder: (c, i) {
                  final sel = i == _chapter;
                  return ListTile(
                    key: ValueKey('toc-$i'),
                    dense: true,
                    selected: sel,
                    title: Text(
                      _chapterTitle(i),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: sel ? Theme.of(context).colorScheme.primary : pal.fg,
                        fontWeight: sel ? FontWeight.w700 : FontWeight.w400,
                        fontSize: 14,
                      ),
                    ),
                    onTap: () {
                      Navigator.of(context).pop();
                      _gotoChapter(i);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openSettingsSheet(ReaderPalette pal) {
    showModalBottomSheet(
      context: context,
      backgroundColor: pal.bar,
      builder: (c) {
        return StatefulBuilder(builder: (c2, setSheet) {
          final s = widget.store.settings;
          void upd(ReaderSettings ns) {
            widget.store.setSettings(ns);
            setSheet(() {});
            setState(() {
              _pages = const [];
              _contentSize = Size.zero;
            });
          }

          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('字号', style: TextStyle(color: pal.fg, fontWeight: FontWeight.w600)),
                Row(
                  children: [
                    Text('A', style: TextStyle(color: pal.muted, fontSize: 13)),
                    Expanded(
                      child: Slider(
                        value: s.fontScale,
                        min: 0.75,
                        max: 2.0,
                        divisions: 25,
                        label: s.fontScale.toStringAsFixed(2),
                        onChanged: (v) => upd(s.copyWith(fontScale: v)),
                      ),
                    ),
                    Text('A', style: TextStyle(color: pal.fg, fontSize: 22)),
                  ],
                ),
                const SizedBox(height: 4),
                Text('行距', style: TextStyle(color: pal.fg, fontWeight: FontWeight.w600)),
                Slider(
                  value: s.lineHeight,
                  min: 1.3,
                  max: 2.4,
                  divisions: 22,
                  label: s.lineHeight.toStringAsFixed(2),
                  onChanged: (v) => upd(s.copyWith(lineHeight: v)),
                ),
                const SizedBox(height: 8),
                Text('主题', style: TextStyle(color: pal.fg, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Row(
                  children: ReaderTheme.values.map((t) {
                    final p = ReaderPalette.of(t);
                    final sel = s.theme == t;
                    return Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: InkWell(
                        onTap: () => upd(s.copyWith(theme: t)),
                        child: Container(
                          width: 56,
                          height: 40,
                          decoration: BoxDecoration(
                            color: p.bg,
                            border: Border.all(
                              color: sel ? Theme.of(context).colorScheme.primary : pal.muted,
                              width: sel ? 2 : 1,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            switch (t) { ReaderTheme.light => '白', ReaderTheme.sepia => '黄', ReaderTheme.dark => '黑' },
                            style: TextStyle(color: p.fg, fontSize: 13),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          );
        });
      },
    );
  }
}

class _PageContent extends StatelessWidget {
  final List<Block> blocks;
  final ReaderTypography typo;
  final ReaderPalette pal;

  /// 正文可用高度（分页就是按它算的）。图片按它的 45% 封顶，必须跟 Paginator 一致，
  /// 否则分页以为图片很矮、渲染却很宽很高，页面会被撑破。
  final double maxHeight;

  /// 必须和 Paginator 用同一个（否则系统字体放大时行数对不上）。
  final TextScaler textScaler;

  const _PageContent({
    required this.blocks,
    required this.typo,
    required this.pal,
    required this.maxHeight,
    required this.textScaler,
  });

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      // 这一层 DefaultTextStyle 是**必需的**：`Text.rich` 会把 DefaultTextStyle 合进自己的
      // 样式里，而 Material 的 bodyMedium 带着 `letterSpacing: 0.25` / `height: 1.43` 这类值。
      // 分页测量是在「光秃秃的 typo 样式」上做的，渲染却额外吃了这些继承值 ——
      // 断行位置因此不同，实际多排一行，页底被裁掉（实测溢出 34px）。
      // 把会影响断行/行高的度量全部显式钉死，两边就一致了。
      child: DefaultTextStyle(
        style: typo.body.copyWith(
          letterSpacing: 0,
          wordSpacing: 0,
          fontWeight: FontWeight.normal,
          fontStyle: FontStyle.normal,
          leadingDistribution: TextLeadingDistribution.proportional,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final b in blocks) _block(b),
            const Spacer(),
          ],
        ),
      ),
    );
  }

  Widget _text(Block b) {
    // 样式树和分页测量共用 blockSpan，保证「量出来的行数 == 实际排出来的行数」。
    final child = Text.rich(
      blockSpan(b, typo),
      textAlign: TextAlign.justify,
      textScaler: textScaler,
    );
    switch (b.kind) {
      case BlockKind.quote:
        return Padding(
          padding: EdgeInsets.only(
            left: typo.fontSize,
            right: typo.fontSize * 0.5,
            bottom: typo.fontSize * 0.8,
          ),
          child: child,
        );
      case BlockKind.listItem:
        return Padding(
          padding: EdgeInsets.only(left: typo.fontSize * 0.6, bottom: typo.fontSize * 0.5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('·  ',
                  style: typo.body.copyWith(color: pal.muted), textScaler: textScaler),
              Expanded(child: child),
            ],
          ),
        );
      case BlockKind.heading:
        return Padding(
          padding: EdgeInsets.only(
            top: b.level <= 1 ? typo.fontSize * 0.6 : typo.fontSize * 0.4,
            bottom: typo.fontSize * (b.level <= 1 ? 1.0 : 0.6),
          ),
          child: child,
        );
      default:
        return Padding(padding: EdgeInsets.only(bottom: typo.fontSize * 0.75), child: child);
    }
  }

  Widget _block(Block b) {
    switch (b.kind) {
      case BlockKind.divider:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Divider(color: pal.muted.withValues(alpha: 0.35)),
        );
      case BlockKind.image:
        final img = b.image;
        if (img == null) return const SizedBox.shrink();
        final aspect = b.aspect <= 0 ? 1.0 : b.aspect;
        final cap = maxHeight <= 0 ? 320.0 : maxHeight * Paginator.imgMaxFrac;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: cap),
              child: AspectRatio(
                aspectRatio: aspect,
                child: Image.memory(
                  Uint8List.fromList(img),
                  fit: BoxFit.contain,
                  errorBuilder: (c, e, s) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        );
      default:
        return _text(b);
    }
  }
}

class _ChapterEnd extends StatelessWidget {
  final ReaderPalette pal;
  final String nextTitle;
  final VoidCallback onNext;
  const _ChapterEnd({required this.pal, required this.nextTitle, required this.onNext});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('本章完', style: TextStyle(color: pal.muted, fontSize: 14)),
          const SizedBox(height: 20),
          FilledButton.tonal(
            onPressed: onNext,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text('下一章 · $nextTitle', maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        ],
      ),
    );
  }
}

/// 仅测试用：把「一页正文」按阅读页**真实**的排版渲染出来。
///
/// 存在的意义是守住一条不变量：**分页引擎量出来的页高 == 真正渲染出来的页高**。
/// 这两者一旦不一致（样式树不同、padding 写错、图片封顶比例不同……），
/// 页底就会 `RenderFlex overflowed`，最后一行被裁掉 —— 这是本项目最容易反复复发的缺陷。
/// `test/pagination_render_parity_test.dart` 靠它逐页渲染真实章节并断言零溢出。
@visibleForTesting
Widget buildPageContentForTest({
  required List<Block> blocks,
  required ReaderTypography typo,
  required ReaderPalette pal,
  required double maxHeight,
  TextScaler textScaler = TextScaler.noScaling,
}) =>
    _PageContent(
      blocks: blocks,
      typo: typo,
      pal: pal,
      maxHeight: maxHeight,
      textScaler: textScaler,
    );
