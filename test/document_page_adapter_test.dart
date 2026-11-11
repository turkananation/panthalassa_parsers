import 'dart:convert';
import 'dart:typed_data';

import 'package:panthalassa_parsers/panthalassa_parsers.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final registry = ParserRegistry.standard();

  test('renders semantic HTML plus embedded SVG visual pages', () {
    final result = registry.parse(buildSimplePdf(showText: 'Adapter Page'));
    final ir = DocumentIr.fromParseResult(result);
    final visual = ir.toVisualDocument();

    final adapter = const DocumentPageAdapter();
    final html = adapter.render(ir: ir, visual: visual);

    expect(html, startsWith('<!doctype html>'));
    expect(html, contains('Adapter Page'));
    expect(html, contains('Format: pdf'));
    expect(html, contains('viewBox="0 0 612 792"'));
    expect(html, contains('Adapter Page'));
    expect(html, contains('<section class="panthalassa-visuals">'));
    expect(html, contains('<svg class="panthalassa-visual-page"'));
  });

  test('omits the visuals section when visual is empty', () {
    final result = registry.parse(
      Uint8List.fromList(utf8.encode('{"hello":"world"}')),
    );
    final ir = DocumentIr.fromParseResult(result);
    final html = const DocumentPageAdapter().render(ir: ir);

    expect(html, startsWith('<!doctype html>'));
    expect(html, contains('Format: json'));
    expect(html, isNot(contains('<section class="panthalassa-visuals">')));

    final noVisual = const DocumentPageAdapter().render(
      ir: ir,
      visual: const VisualDocument(
        sourceFormat: DocumentFormat.json,
        pages: [],
      ),
    );
    expect(noVisual, isNot(contains('<section class="panthalassa-visuals">')));
  });

  test('omits metadata block with includeMetadata: false', () {
    final result = registry.parse(buildSimplePdf(showText: 'Meta Page'));
    final ir = DocumentIr.fromParseResult(result);
    final html = const DocumentPageAdapter().render(
      ir: ir,
      options: const RenderOptions(includeMetadata: false),
    );
    expect(html, isNot(contains('<div class="panthalassa-metadata">')));
  });

  test('uses a heading as the page title', () {
    final ir = const DocumentIr(
      sourceFormat: DocumentFormat.pdf,
      metadata: {},
      body: [
        HeadingBlock(level: 1, text: [TextRun('Report Title')]),
        ParagraphBlock([TextRun('Body text')]),
      ],
    );
    final html = const DocumentPageAdapter().render(ir: ir);
    expect(html, contains('<title>Report Title</title>'));
    expect(html, contains('<div class="panthalassa-title">Report Title</div>'));
  });

  test('falls back to a default title when there is no heading', () {
    final result = registry.parse(buildSimplePdf(showText: 'Report Title'));
    final ir = DocumentIr.fromParseResult(result);
    final html = const DocumentPageAdapter().render(ir: ir);
    expect(html, contains('<title>panthalassa document</title>'));
    expect(html, contains('Report Title'));
  });
}
