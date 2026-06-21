import 'package:panthalassa_parsers/panthalassa_parsers.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final registry = ParserRegistry.standard();

  test('simple-font encoding: WinAnsi base + /Differences, no ToUnicode', () {
    final r = registry.parse(buildEncodedTextPdf());
    expect(r.format, DocumentFormat.pdf);
    // WinAnsi octal-escaped bytes \351 -> é.
    expect(r.text, contains('Résumé'));
    // Differences codes 1,2 -> Euro, trademark via glyph-name resolution.
    expect(r.text, contains('€'));
    expect(r.text, contains('™'));
  });

  test('Type0/Identity-H font with 2-byte ToUnicode maps composite codes', () {
    final r = registry.parse(buildType0Pdf());
    expect(r.format, DocumentFormat.pdf);
    expect(r.text, contains('Hi'));
  });

  test('Form XObject text is recovered via the Do operator', () {
    final r = registry.parse(buildFormXObjectPdf(showText: 'Nested Form Text'));
    expect(r.format, DocumentFormat.pdf);
    expect(r.text, contains('Nested Form Text'));
  });

  test('inline image (BI/ID/EI) is skipped without corrupting surrounding text', () {
    final r = registry.parse(buildInlineImagePdf());
    expect(r.format, DocumentFormat.pdf);
    expect(r.text, contains('Before Image'));
    expect(r.text, contains('After Image'));
    // The bait bytes inside the image ("BT", "(x)") must not leak into output.
    expect(r.text, isNot(contains('(x)')));
  });

  _pdfA3Tests();
}

// Appended: PDF/A-3 embedded-file extraction.
void _pdfA3Tests() {
  final registry = ParserRegistry.standard();
  test('PDF/A-3 associated embedded XML is detected and its text harvested', () {
    final r = registry.parse(buildPdfA3WithEmbeddedXml());
    expect(r.format, DocumentFormat.pdf);
    expect(r.metadata['pdfA3'], true);
    final files = r.metadata['embeddedFiles'] as List;
    expect(files, hasLength(1));
    final f = files.first as Map;
    expect(f['name'], 'factur-x.xml');
    expect(f['relationship'], 'Alternative');
    // Both the page text and the embedded invoice XML are present.
    expect(r.text, contains('Invoice 2026-001'));
    expect(r.text, contains('Esambo Interserve Ltd'));
    expect(r.text, contains('1500.00'));
  });
}
