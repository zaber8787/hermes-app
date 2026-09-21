import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/features/chat/linkify.dart';

void main() {
  group('linkifyBareUrls', () {
    test('bare http url becomes angle autolink', () {
      expect(
        linkifyBareUrls('下載 http://127.0.0.1:8699/a.apk 很棒的'),
        '下載 <http://127.0.0.1:8699/a.apk> 很棒的',
      );
    });

    test('existing markdown link untouched', () {
      const s = '[官網](https://example.com/x) 完工';
      expect(linkifyBareUrls(s), s);
    });

    test('url inside inline code untouched', () {
      const s = '用 `curl https://example.com` 抓';
      expect(linkifyBareUrls(s), s);
    });

    test('url inside fenced code untouched', () {
      const s = '```\nwget https://example.com/f.zip\n```';
      expect(linkifyBareUrls(s), s);
    });

    test('trailing punctuation stays outside the link', () {
      expect(
        linkifyBareUrls('看 https://example.com/a。還有逗號, 結尾 https://b.com.'),
        '看 <https://example.com/a>。還有逗號, 結尾 <https://b.com>.',
      );
    });

    test('url in parentheses keeps closing paren out', () {
      expect(
        linkifyBareUrls('（https://example.com/x）'),
        '（<https://example.com/x>）',
      );
    });

    test('bare url at line start links', () {
      expect(
        linkifyBareUrls('https://example.com 是入口'),
        '<https://example.com> 是入口',
      );
    });

    test('angle autolink already present is not doubled', () {
      const s = '見 <https://example.com> 內';
      expect(linkifyBareUrls(s), s);
    });

    test('url with query string kept whole', () {
      expect(
        linkifyBareUrls('http://host:8642/x?a=1&b=2 ok'),
        '<http://host:8642/x?a=1&b=2> ok',
      );
    });

    test('no false positive on file paths', () {
      const s = '檔名 /tmp/example/x.txt 與 C:\\a 不動';
      expect(linkifyBareUrls(s), s);
    });

    test('fullwidth colon glued before url still links (v0.10 regression)', () {
      expect(
        linkifyBareUrls('v0.10 上線：http://127.0.0.1:8699/a-debug.apk'),
        'v0.10 上線：<http://127.0.0.1:8699/a-debug.apk>',
      );
    });

    test('CJK word glued before url links', () {
      expect(
        linkifyBareUrls('但https://x.com/a 有'),
        '但<https://x.com/a> 有',
      );
    });

    test('url glued to CJK bracket on both sides', () {
      expect(
        linkifyBareUrls('「http://a.b:8699/x.apk」裡面'),
        '「<http://a.b:8699/x.apk>」裡面',
      );
    });

    test('url glued to curly quote edge does not swallow quote', () {
      expect(
        linkifyBareUrls('看"http://a.b/x"裡面'),
        '看"<http://a.b/x>"裡面',
      );
    });
  });
}
