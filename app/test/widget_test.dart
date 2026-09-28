import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhu_ye_reader/services/epub.dart';
import 'package:zhu_ye_reader/services/paginator.dart';

ReaderTypography typo() => const ReaderTypography(
      fontSize: 18,
      lineHeight: 1.8,
      textColor: Color(0xFF111111),
      mutedColor: Color(0xFF888888),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Paginator', () {
    test('长段落跨页切分，且一个字都不丢', () {
      final text = '汉字分页测试' * 600;
      final blocks = [Block(BlockKind.paragraph, runs: [Run(text)])];
      final pages = Paginator(width: 320, height: 480, typo: typo()).paginate(blocks);

      expect(pages.length, greaterThan(1));
      final joined = pages.expand((p) => p).map((b) => b.text).join();
      expect(joined, text, reason: '切页后拼接必须与原文完全一致');
    });

    test('短段落仍在一页内', () {
      final blocks = [Block(BlockKind.paragraph, runs: [const Run('很短的一段话。')])];
      final pages = Paginator(width: 320, height: 480, typo: typo()).paginate(blocks);
      expect(pages.length, 1);
      expect(pages.first.first.text, '很短的一段话。');
    });

    test('段落样式在切分后保留', () {
      final runs = [
        const Run('加粗部分', bold: true),
        Run('普通部分' * 300),
      ];
      final pages = Paginator(width: 300, height: 400, typo: typo())
          .paginate([Block(BlockKind.paragraph, runs: runs)]);

      expect(pages.first.first.runs.first.bold, isTrue);
      final total = pages.expand((p) => p).map((b) => b.text).join();
      expect(total, '加粗部分${'普通部分' * 300}');
    });

    test('空章节产出单张空页，不会崩', () {
      final pages = Paginator(width: 320, height: 480, typo: typo()).paginate(const []);
      expect(pages.length, 1);
      expect(pages.first, isEmpty);
    });

    test('图片块按纵横比占位，超高时被限制', () {
      final blocks = [Block(BlockKind.image, aspect: 0.2)]; // 极端竖长图
      final pages = Paginator(width: 320, height: 480, typo: typo()).paginate(blocks);
      expect(pages.length, 1);
      expect(pages.first.first.kind, BlockKind.image);
    });
  });
}
