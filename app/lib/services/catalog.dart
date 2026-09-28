import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models.dart';

/// 名录索引：file_id -> CatalogEntry。
///
/// 数据来自 assets/catalog.json（由 tools/build_app_catalog.py 生成，
/// 从站点名录 all-books.json 的 24,071 条按 file_id 去重成 11,348 本）。
/// 只有这一个用途：把本地 zip 的文件名还原成书名/作者/分类。
class Catalog {
  final Map<String, CatalogEntry> _byId;
  final Set<String> _categories;

  Catalog._(this._byId, this._categories);

  static Catalog? _instance;
  static Catalog get instance {
    final c = _instance;
    if (c == null) {
      throw StateError('Catalog 尚未 load()');
    }
    return c;
  }

  int get count => _byId.length;
  Set<String> get categories => _categories;

  static Future<Catalog> load({String asset = 'assets/catalog.json'}) async {
    if (_instance != null) return _instance!;
    final raw = await rootBundle.loadString(asset);
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final books = data['books'] as Map<String, dynamic>;
    final byId = <String, CatalogEntry>{};
    final cats = <String>{};
    books.forEach((k, v) {
      final e = CatalogEntry.fromJson(k, v as Map<String, dynamic>);
      byId[k] = e;
      if (e.category.isNotEmpty) cats.add(e.category);
    });
    _instance = Catalog._(byId, cats);
    return _instance!;
  }

  CatalogEntry? byId(String fileId) => _byId[fileId];

  /// 全量遍历（用于名录检索页）。
  Iterable<CatalogEntry> get all => _byId.values;

  /// 按关键词检索：标题 / 别名 / 作者，返回分数排序后的结果。
  List<CatalogEntry> search(String q, {int limit = 200}) {
    final kw = q.trim().toLowerCase();
    if (kw.isEmpty) return const [];
    final hits = <MapEntry<CatalogEntry, int>>[];
    for (final e in _byId.values) {
      final t = e.title.toLowerCase();
      final a = e.author.toLowerCase();
      int score = 0;
      if (t == kw) {
        score = 100;
      } else if (t.startsWith(kw)) {
        score = 80;
      } else if (t.contains(kw)) {
        score = 60;
      } else if (a.contains(kw)) {
        score = 40;
      } else {
        for (final x in e.aliases) {
          if (x.toLowerCase().contains(kw)) {
            score = 30;
            break;
          }
        }
      }
      if (score > 0) hits.add(MapEntry(e, score));
    }
    hits.sort((x, y) {
      final c = y.value.compareTo(x.value);
      return c != 0 ? c : x.key.title.length.compareTo(y.key.title.length);
    });
    return hits.take(limit).map((e) => e.key).toList();
  }
}
