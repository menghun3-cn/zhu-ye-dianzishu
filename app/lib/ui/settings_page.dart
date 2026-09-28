import 'dart:io';

import 'package:flutter/material.dart';

import '../models.dart';
import '../services/catalog.dart';
import '../services/store.dart';

class SettingsPage extends StatefulWidget {
  final Store store;
  final int shelfCount;
  final Future<void> Function() onRescan;
  const SettingsPage({
    super.key,
    required this.store,
    required this.shelfCount,
    required this.onRescan,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late TextEditingController _root;

  @override
  void initState() {
    super.initState();
    _root = TextEditingController(text: widget.store.libraryRoot);
  }

  @override
  void dispose() {
    _root.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.store.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _SectionTitle('书库'),
          TextField(
            controller: _root,
            decoration: InputDecoration(
              labelText: '书库目录',
              helperText: '放 <文件ID>.zip 的目录，例如 E:\\chinabook',
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: IconButton(
                icon: const Icon(Icons.check),
                tooltip: '保存并重新扫描',
                onPressed: () async {
                  widget.store.setLibraryRoot(_root.text.trim());
                  await widget.onRescan();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('已保存，当前书架 ${widget.shelfCount} 本')),
                    );
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => widget.onRescan(),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('重新扫描书库'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.library_books_outlined),
              title: Text('书架 ${widget.shelfCount} 本'),
              subtitle: Text('名录收录 ${Catalog.instance.count} 本 · ${Catalog.instance.categories.length} 个分类'),
            ),
          ),
          const SizedBox(height: 20),
          const _SectionTitle('默认排版'),
          ListTile(
            title: const Text('字号'),
            subtitle: Slider(
              value: s.fontScale,
              min: 0.75,
              max: 2.0,
              divisions: 25,
              label: s.fontScale.toStringAsFixed(2),
              onChanged: (v) => widget.store.setSettings(s.copyWith(fontScale: v)),
            ),
            trailing: Text('${(s.fontScale * 100).round()}%'),
          ),
          ListTile(
            title: const Text('行距'),
            subtitle: Slider(
              value: s.lineHeight,
              min: 1.3,
              max: 2.4,
              divisions: 22,
              label: s.lineHeight.toStringAsFixed(2),
              onChanged: (v) => widget.store.setSettings(s.copyWith(lineHeight: v)),
            ),
            trailing: Text(s.lineHeight.toStringAsFixed(1)),
          ),
          ListTile(
            title: const Text('主题'),
            trailing: SegmentedButton<ReaderTheme>(
              segments: const [
                ButtonSegment(value: ReaderTheme.light, label: Text('白')),
                ButtonSegment(value: ReaderTheme.sepia, label: Text('黄')),
                ButtonSegment(value: ReaderTheme.dark, label: Text('黑')),
              ],
              selected: {s.theme},
              onSelectionChanged: (v) => widget.store.setSettings(s.copyWith(theme: v.first)),
            ),
          ),
          const SizedBox(height: 20),
          const _SectionTitle('书签'),
          if (widget.store.bookmarks.isEmpty)
            const ListTile(dense: true, title: Text('还没有书签', style: TextStyle(color: Colors.grey))),
          ...widget.store.bookmarks.take(50).map((b) => ListTile(
                dense: true,
                leading: const Icon(Icons.bookmark, size: 18),
                title: Text(b.chapterTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(b.excerpt, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                trailing: IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () => widget.store.removeBookmark(b),
                ),
              )),
          const SizedBox(height: 20),
          const _SectionTitle('关于'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('竹叶阅读', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  const Text(
                    '跨端 EPUB 阅读器（Windows / Android / iOS）。\n'
                    '本地书来自城通网盘书包：一个 zip 内含同一本书的 epub / mobi / azw3，'
                    '阅读时只取 epub 那一份，其余格式保留在包里不解析。',
                    style: TextStyle(fontSize: 12, height: 1.6),
                  ),
                  const SizedBox(height: 8),
                  Text('数据目录：${widget.store.dir.path}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
                  Text('平台：${Platform.operatingSystem}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(
          text,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.primary,
            fontSize: 13,
            letterSpacing: 0.6,
          ),
        ),
      );
}
