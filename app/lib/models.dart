/// 竹叶阅读 —— 领域模型
///
/// 术语对齐 CONTEXT.md：
///  书目条目 BookEntry  —— 名录里的一条元数据（24,071 条）
///  书包     BookPack   —— 一个 zip 文件，内含同一本书的多格式（11,348 个）
///  书架     ShelfBook  —— 你本地实际拥有的那一份（zip 或独立 epub）
library;

/// 名录里的一本书（按 file_id 去重后）。
class CatalogEntry {
  final String fileId; // 城通的数字文件 ID，也是本地 zip 的文件名
  final String title;
  final String author;
  final String category;
  final int duplicates; // 在名录里被重复收录的次数
  final List<String> aliases; // 重复条目的其他书名，用于搜索命中

  const CatalogEntry({
    required this.fileId,
    required this.title,
    required this.author,
    required this.category,
    required this.duplicates,
    required this.aliases,
  });

  factory CatalogEntry.fromJson(String fileId, Map<String, dynamic> j) {
    return CatalogEntry(
      fileId: fileId,
      title: (j['t'] ?? '').toString(),
      author: (j['a'] ?? '').toString(),
      category: (j['c'] ?? '').toString(),
      duplicates: (j['n'] as num?)?.toInt() ?? 1,
      aliases: ((j['x'] as List?) ?? const []).map((e) => e.toString()).toList(),
    );
  }

  /// 搜索用的合并文本（标题 + 别名 + 作者）。
  String get searchBlob => '$title\u0001$author\u0001${aliases.join('\u0001')}';
}

/// 书架上的一项：本地真实存在的书。
class ShelfBook {
  final String fileId;
  final String path; // zip 或 epub 的绝对路径
  final String title;
  final String author;
  final String category;
  final int sizeBytes;
  final bool isZip; // true=城通书包(内含 epub)，false=直接是 epub

  const ShelfBook({
    required this.fileId,
    required this.path,
    required this.title,
    required this.author,
    required this.category,
    required this.sizeBytes,
    required this.isZip,
  });

  String get id => fileId;
}

/// 章节目录项。
class ChapterRef {
  final String title;
  final String href; // 相对 OPF 解析后的 EPUB 内部路径
  const ChapterRef(this.title, this.href);
}

/// 阅读进度。
class BookProgress {
  final int chapterIndex;
  final int pageIndex;
  final int updatedAt;

  const BookProgress({
    required this.chapterIndex,
    required this.pageIndex,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'c': chapterIndex,
        'p': pageIndex,
        't': updatedAt,
      };

  factory BookProgress.fromJson(Map<String, dynamic> j) => BookProgress(
        chapterIndex: (j['c'] as num?)?.toInt() ?? 0,
        pageIndex: (j['p'] as num?)?.toInt() ?? 0,
        updatedAt: (j['t'] as num?)?.toInt() ?? 0,
      );
}

/// 书签。
class Bookmark {
  final String fileId;
  final int chapterIndex;
  final String chapterTitle;
  final int pageIndex;
  final String excerpt;
  final int createdAt;

  const Bookmark({
    required this.fileId,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.pageIndex,
    required this.excerpt,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'f': fileId,
        'c': chapterIndex,
        'ct': chapterTitle,
        'p': pageIndex,
        'e': excerpt,
        't': createdAt,
      };

  factory Bookmark.fromJson(Map<String, dynamic> j) => Bookmark(
        fileId: (j['f'] ?? '').toString(),
        chapterIndex: (j['c'] as num?)?.toInt() ?? 0,
        chapterTitle: (j['ct'] ?? '').toString(),
        pageIndex: (j['p'] as num?)?.toInt() ?? 0,
        excerpt: (j['e'] ?? '').toString(),
        createdAt: (j['t'] as num?)?.toInt() ?? 0,
      );
}

/// 阅读器的排版设置。
enum ReaderTheme { light, sepia, dark }

class ReaderSettings {
  final double fontScale; // 0.8 ~ 2.0
  final double lineHeight; // 1.4 ~ 2.2
  final ReaderTheme theme;

  const ReaderSettings({
    this.fontScale = 1.0,
    this.lineHeight = 1.8,
    this.theme = ReaderTheme.light,
  });

  ReaderSettings copyWith({double? fontScale, double? lineHeight, ReaderTheme? theme}) =>
      ReaderSettings(
        fontScale: fontScale ?? this.fontScale,
        lineHeight: lineHeight ?? this.lineHeight,
        theme: theme ?? this.theme,
      );

  Map<String, dynamic> toJson() => {
        'fs': fontScale,
        'lh': lineHeight,
        'th': theme.index,
      };

  factory ReaderSettings.fromJson(Map<String, dynamic> j) => ReaderSettings(
        fontScale: (j['fs'] as num?)?.toDouble() ?? 1.0,
        lineHeight: (j['lh'] as num?)?.toDouble() ?? 1.8,
        theme: ReaderTheme.values[(j['th'] as num?)?.toInt() ?? 0],
      );
}
