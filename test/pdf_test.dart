import 'package:panthalassa_parsers/panthalassa_parsers.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final registry = ParserRegistry.standard();

  test('extracts text from an uncompressed content stream', () {
    final r = registry.parse(buildSimplePdf(showText: 'Vote Awake'));
    expect(r.format, DocumentFormat.pdf);
    expect(r.metadata['pageCount'], 1);
    expect(r.metadata['pdfVersion'], '1.7');
    expect(r.text, contains('Vote Awake'));
    expect(r.warnings, isEmpty);
  });

  test('extracts text through the FlateDecode (inflate) path', () {
    final r = registry.parse(
      buildSimplePdf(showText: 'Panthalassa Vault', compress: true),
    );
    expect(r.format, DocumentFormat.pdf);
    expect(r.text, contains('Panthalassa Vault'));
  });

  test('decodes literal-string escapes (regression: backslash handling)', () {
    // Parentheses inside a string must be escaped; they should survive decoding.
    final r = registry.parse(buildSimplePdf(showText: r'A \(B\) C'));
    expect(r.text, contains('A (B) C'));
  });

  test('parses a content stream split across multiple show operators', () {
    final r = registry.parse(buildSimplePdf(showText: 'County Budget 2026'));
    expect(r.text, contains('County Budget 2026'));
  });

  test('PDF-1: resolves an object-stream PDF via the cross-reference stream', () {
    final r = registry.parse(buildObjStmPdf(showText: 'Object Streams Resolved'));
    expect(r.format, DocumentFormat.pdf);
    expect(r.metadata['pageCount'], 1);
    expect(r.text, contains('Object Streams Resolved'));
    expect(r.warnings, isEmpty);
  });
}
