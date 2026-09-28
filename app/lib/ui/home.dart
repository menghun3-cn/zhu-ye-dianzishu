import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models.dart';
import '../services/catalog.dart';
import '../services/covers.dart';
import '../services/library.dart';
import '../services/store.dart';
import 'reader.dart';
import 'settings_page.dart';

class HomeShell extends StatefulWidget {
  final Store store;
  const HomeShell({super.key, required this.store});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  List<ShelfBook> _shelf = const [];
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _rescan();
    widget.store.addListener(_onStore);
  }

  void _onStore() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStore);
    super.dispose();
  }

  Future<void> _rescan() async {
    setState(() => _scanning = true);
    final cat = Catalog.instance;
    final list = await Future(() => LibraryService.scan(widget.store.libraryRoot, cat));
    if (!mounted) return;
    setState(() {
      _shelf = list;
      _scanning = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          ShelfPage(
            store: widget.store,
            shelf: _shelf,
            scanning: _scanning,
            onRescan: _rescan,
          ),
          CatalogPage(store: widget.store, shelf: _shelf),
          SettingsPage(store: widget.store, shelfCount: _shelf.length, onRescan: _rescan),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.menu_book_outlined),
            selectedIcon: const Icon(Icons.menu_book),
            label: '书架${_shelf.isEmpty ? '' : ' ${_shelf.length}'}',
          ),
          const NavigationDestination(icon: Icon(Icons.travel_explore_outlined), selectedIcon: Icon(Icons.travel_explore), label: '名录'),
          const NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: '设置'),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 书架
// ---------------------------------------------------------------------------

class ShelfPage extends StatefulWidget {
  final Store store;
  final List<ShelfBook> shelf;
  final bool scanning;
  final Future<void> Function() onRescan;
  const ShelfPage({
    super.key,
    required this.store,
    required this.shelf,
    required this.scanning,
    required this.onRescan,
  });

  @override
  State<ShelfPage> createState() => _ShelfPageState();
}

class _ShelfPageState extends State<ShelfPage> {
  String _q = '';
  String _cat = '全部';
  bool _grid = false;

  List<ShelfBook> get _filtered {
    final kw = _q.trim().toLowerCase();
    return widget.shelf.where((b) {
      if (_cat != '全部' && b.category != _cat) return false;
      if (kw.isEmpty) return true;
      return b.title.toLowerCase().contains(kw) ||
          b.author.toLowerCase().contains(kw) ||
          b.fileId.contains(kw);
    }).toList();
  }

  List<String> get _cats {
    final s = <String>{};
    for (final b in widget.shelf) {
      if (b.category.isNotEmpty) s.add(b.category);
    }
    // 「全部」必须排在最前面：直接整体 sort 的话，中文分类名按码点会排到它前面。
    final l = s.toList()..sort();
    return ['全部', ...l];
  }

  @override
  Widget build(BuildContext context) {
    final items = _filtered;
    return Scaffold(
      appBar: AppBar(
        title: const Text('书架'),
        actions: [
          IconButton(
            tooltip: _grid ? '列表' : '网格',
            icon: Icon(_grid ? Icons.view_list : Icons.grid_view),
            onPressed: () => setState(() => _grid = !_grid),
          ),
          IconButton(
            tooltip: '重新扫描书库',
            icon: widget.scanning
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            onPressed: widget.scanning ? null : () => widget.onRescan(),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: '在书架上搜索书名 / 作者',
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: _cats
                  .map((c) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(c, style: const TextStyle(fontSize: 12)),
                          selected: _cat == c,
                          onSelected: (_) => setState(() => _cat = c),
                        ),
                      ))
                  .toList(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text('${items.length} 本', style: Theme.of(context).textTheme.bodySmall),
                const Spacer(),
                if (widget.store.libraryRoot.isEmpty)
                  Text('未设置书库目录', style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: widget.shelf.isEmpty
                ? _EmptyShelf(scanning: widget.scanning, root: widget.store.libraryRoot)
                : (items.isEmpty
                    ? const Center(child: Text('没有匹配的书'))
                    : (_grid
                        ? GridView.builder(
                            padding: const EdgeInsets.all(12),
                            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 150,
                              childAspectRatio: 0.58,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                            ),
                            itemCount: items.length,
                            itemBuilder: (c, i) => _GridTile(store: widget.store, book: items[i]),
                          )
                        : ListView.builder(
                            itemCount: items.length,
                            itemBuilder: (c, i) => _ShelfRow(store: widget.store, book: items[i]),
                          ))),
          ),
        ],
      ),
    );
  }
}

class _EmptyShelf extends StatelessWidget {
  final bool scanning;
  final String root;
  const _EmptyShelf({required this.scanning, required this.root});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_stories_outlined, size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(scanning ? '正在扫描书库…' : '书架还是空的', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              root.isEmpty ? '请先到「设置」里指定书库目录' : '当前书库目录：$root\n把下载好的 <文件ID>.zip 放进这个目录，然后重新扫描。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _CoverThumb extends StatelessWidget {
  final Store store;
  final ShelfBook book;
  final double width;
  final double height;
  const _CoverThumb({required this.store, required this.book, required this.width, required this.height});

  @override
  Widget build(BuildContext context) {
    final cached = CoverCache.peek(book.fileId);
    if (cached != null) return _img(cached);
    return FutureBuilder<Uint8List?>(
      future: CoverCache.get(store, book),
      builder: (c, snap) {
        final d = snap.data;
        if (d != null && d.isNotEmpty) return _img(d);
        return _placeholder(context);
      },
    );
  }

  Widget _img(Uint8List d) => ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.memory(
          d,
          width: width,
          height: height,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (c, e, s) => const SizedBox.shrink(),
        ),
      );

  Widget _placeholder(BuildContext context) {
    final t = book.title.trim();
    final ch = t.isEmpty ? '书' : t.substring(0, 1);
    final hue = (book.title.hashCode % 360).abs().toDouble();
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: HSLColor.fromAHSL(1, hue, 0.22, 0.82).toColor(),
      ),
      alignment: Alignment.center,
      child: Text(ch, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Color(0xFF3A3A3A))),
    );
  }
}

class _ShelfRow extends StatelessWidget {
  final Store store;
  final ShelfBook book;
  const _ShelfRow({required this.store, required this.book});

  @override
  Widget build(BuildContext context) {
    final prog = store.progressOf(book.fileId);
    return ListTile(
      leading: _CoverThumb(store: store, book: book, width: 42, height: 58),
      title: Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [if (book.author.isNotEmpty) book.author, book.category].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (prog != null)
            Text('第 ${prog.chapterIndex + 1} 章', style: const TextStyle(fontSize: 11)),
          Text(
            book.sizeBytes > 0 ? '${(book.sizeBytes / 1048576).toStringAsFixed(1)}MB' : '',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
      onTap: () {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (c) => ReaderPage(book: book, store: store),
        ));
      },
    );
  }
}

class _GridTile extends StatelessWidget {
  final Store store;
  final ShelfBook book;
  const _GridTile({required this.store, required this.book});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (c) => ReaderPage(book: book, store: store),
        ));
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (c, cons) => Center(
                child: _CoverThumb(store: store, book: book, width: cons.maxWidth, height: cons.maxHeight),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 名录（全部 11,348 本索引，含「已在本地」标记）
// ---------------------------------------------------------------------------

class CatalogPage extends StatefulWidget {
  final Store store;
  final List<ShelfBook> shelf;
  const CatalogPage({super.key, required this.store, required this.shelf});

  @override
  State<CatalogPage> createState() => _CatalogPageState();
}

class _CatalogPageState extends State<CatalogPage> {
  List<CatalogEntry> _results = const [];
  bool _searched = false;

  Set<String> get _localIds => widget.shelf.map((e) => e.fileId).toSet();

  void _run(String q) {
    setState(() {
      _searched = true;
      _results = q.trim().isEmpty ? const [] : Catalog.instance.search(q, limit: 300);
    });
  }

  @override
  Widget build(BuildContext context) {
    final local = _localIds;
    return Scaffold(
      appBar: AppBar(title: const Text('名录检索')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: TextField(
              autofocus: false,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: '在 ${Catalog.instance.count} 本书目里搜索',
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onSubmitted: _run,
              onChanged: (v) {
                if (v.trim().length >= 2 || v.trim().isEmpty) _run(v);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(
                  _searched ? '命中 ${_results.length} 条' : '共收录 ${Catalog.instance.count} 本 · 本地已有 ${local.length} 本',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: !_searched
                ? const Center(child: Text('输入关键词开始检索', style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (c, i) {
                      final e = _results[i];
                      final has = local.contains(e.fileId);
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          has ? Icons.check_circle : Icons.cloud_download_outlined,
                          color: has ? Colors.green : Theme.of(context).colorScheme.outline,
                          size: 20,
                        ),
                        title: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [
                            if (e.author.isNotEmpty) e.author,
                            e.category,
                            if (e.duplicates > 1) '名录收录 ×${e.duplicates}',
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: has
                            ? const Text('已入库', style: TextStyle(fontSize: 11, color: Colors.green))
                            : Text(e.fileId, style: const TextStyle(fontSize: 10, color: Colors.grey)),
                        onTap: () => _showDetail(e, has),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _showDetail(CatalogEntry e, bool has) {
    showModalBottomSheet(
      context: context,
      builder: (c) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(e.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text('${e.author} · ${e.category}'),
            const SizedBox(height: 6),
            Text('文件 ID：${e.fileId}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
            if (e.aliases.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('名录别名：${e.aliases.join(' / ')}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ),
            const SizedBox(height: 14),
            Text(
              has
                  ? '这本书已经下载到本地书库，去书架打开即可。'
                  : '还没下载。下载器是按文件名 <文件ID>.zip 落盘的，等它下到这本后重新扫描书库就会出现。',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 14),
            if (has)
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(c);
                  final b = widget.shelf.firstWhere((x) => x.fileId == e.fileId);
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => ReaderPage(book: b, store: widget.store),
                  ));
                },
                icon: const Icon(Icons.menu_book),
                label: const Text('开始阅读'),
              ),
          ],
        ),
      ),
    );
  }
}
