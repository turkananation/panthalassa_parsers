import 'dart:convert';
import 'dart:typed_data';

import 'package:panthalassa_parsers/panthalassa_parsers.dart';
import 'package:test/test.dart';

Uint8List _html(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  final registry = ParserRegistry.standard();

  group('HTML', () {
    test('detects doctype html', () {
      final r = registry.parse(
        _html('''
<!DOCTYPE html>
<html><head><title>Test Page</title></head>
<body><h1>Hello</h1><p>World</p></body>
</html>
'''),
      );
      expect(r.format, DocumentFormat.html);
      expect(r.metadata['title'], 'Test Page');
      expect(r.text, contains('Hello'));
      expect(r.text, contains('World'));
      expect(r.documentId, r.digest!.sha256);
    });

    test('detects open html tag', () {
      final r = registry.parse(_html('<html><body>Plain HTML</body></html>'));
      expect(r.format, DocumentFormat.html);
      expect(r.text, contains('Plain HTML'));
    });

    test('extracts headings as outline', () {
      final r = registry.parse(
        _html('''
<!DOCTYPE html>
<html>
<h1>Main Title</h1>
<h2>Subtitle</h2>
<h3>Deep</h3>
</html>
'''),
        options: const ParseOptions(includeOutline: true),
      );
      expect(r.outline, hasLength(3));
      expect(r.outline[0].title, 'Main Title');
      expect(r.outline[0].level, 1);
      expect(r.outline[1].level, 2);
      expect(r.outline[2].level, 3);
    });

    test('extracts links', () {
      final r = registry.parse(
        _html('''
<!DOCTYPE html>
<html><body>
<a href="https://example.com">Example</a>
<a href="/relative">Relative</a>
</body></html>
'''),
      );
      expect(r.metadata['links'], isNotEmpty);
      final links = r.metadata['links'] as List;
      expect(links.first['href'], 'https://example.com');
      expect(links.first['text'], 'Example');
    });

    test('extracts tables', () {
      final r = registry.parse(
        _html('''
<!DOCTYPE html>
<html><body>
<table>
<tr><td>A1</td><td>B1</td></tr>
<tr><td>A2</td><td>B2</td></tr>
</table>
</body></html>
'''),
        options: const ParseOptions(includeTables: true),
      );
      expect(r.tables, isNotEmpty);
      expect(r.tables.first.rows, hasLength(2));
      expect(r.tables.first.rows[0], contains('A1'));
    });

    test('strips script and style', () {
      final r = registry.parse(
        _html('''
<!DOCTYPE html>
<html>
<script>alert("evil");</script>
<style>body { color: red; }</style>
<body>Visible text</body>
</html>
'''),
      );
      expect(r.text, contains('Visible text'));
      expect(r.text, isNot(contains('alert')));
      expect(r.text, isNot(contains('color')));
    });

    test('decodes HTML entities', () {
      final r = registry.parse(
        _html('''
<!DOCTYPE html>
<html><body>Tom &amp; Jerry &nbsp; &copy;</body></html>
'''),
      );
      expect(r.text, contains('Tom & Jerry '));
      expect(r.text, contains('©'));
    });

    test('warns on external resources', () {
      final r = registry.parse(
        _html('''
<!DOCTYPE html>
<html><body>
<img src="image.png">
<link href="style.css">
</body></html>
'''),
      );
      expect(r.warnings, isNotEmpty);
      expect(r.warnings.first.code, 'html.external_resources');
    });

    test('hints route .html to html', () {
      final r = registry.parse(
        _html('<!DOCTYPE html><html><body>hi</body></html>'),
        hints: const DocumentHints(filename: 'page.html'),
      );
      expect(r.format, DocumentFormat.html);
    });

    test('rejects non-HTML text', () {
      expect(
        () => registry.parse(utf8.encode('just plain text')),
        throwsA(isA<UnsupportedFormatException>()),
      );
    });

    test('carries both digests', () {
      final r = registry.parse(
        _html('<!DOCTYPE html><html><body>test</body></html>'),
      );
      expect(r.sha512, hasLength(128));
      expect(r.sha384, hasLength(96));
    });
  });
}
