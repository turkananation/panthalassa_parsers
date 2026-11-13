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
    expect(html, contains('format-chip">pdf'));
    expect(html, contains('viewBox="0 0 612 792"'));
    expect(html, contains('class="panthalassa-visuals"'));
    expect(html, contains('data-page-label="Page 1"'));
    expect(html, contains('<svg class="panthalassa-visual-page"'));
    expect(html, contains('id="find-bar"'));
    expect(html, contains('id="lightbox"'));
    expect(html, contains('data-visual-svg'));
    expect(html, contains('data-visual-png'));
    expect(html, contains("const KEY_THEME = 'panthalassa-theme'"));
    expect(html, contains('tok-keyword'));
  });

  test('omits the visuals section when visual is empty', () {
    final result = registry.parse(
      Uint8List.fromList(utf8.encode('{"hello":"world"}')),
    );
    final ir = DocumentIr.fromParseResult(result);
    final html = const DocumentPageAdapter().render(ir: ir);

    expect(html, startsWith('<!doctype html>'));
    expect(html, contains('format-chip">json'));
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
    expect(html, isNot(contains('id="document-metadata"')));
    expect(html, isNot(contains('data-section-id="metadata"')));
  });

  test('renders a single metadata card and avoids a duplicate section', () {
    final result = registry.parse(buildSimplePdf(showText: 'Meta Page'));
    final ir = DocumentIr.fromParseResult(result);
    final html = const DocumentPageAdapter().render(ir: ir);

    expect(html, contains('id="document-metadata"'));
    expect(html, contains('class="meta-grid"'));
    expect(html, isNot(contains('data-section-id="metadata"')));
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
    expect(html, contains('title="Report Title">Report Title</div>'));
  });

  test('falls back to a default title when there is no heading', () {
    final result = registry.parse(buildSimplePdf(showText: 'Report Title'));
    final ir = DocumentIr.fromParseResult(result);
    final html = const DocumentPageAdapter().render(ir: ir);
    expect(html, contains('<title>panthalassa document</title>'));
    expect(html, contains('Report Title'));
  });

  test('renders collapsible field groups with stable heading ids', () {
    const ir = DocumentIr(
      sourceFormat: DocumentFormat.pdf,
      metadata: {},
      body: [
        FieldGroupBlock(
          name: 'Findings',
          children: [
            KeyValueBlock(key: 'Status', value: [TextRun('open')]),
          ],
        ),
        FieldGroupBlock(
          name: 'Findings',
          children: [
            KeyValueBlock(key: 'Owner', value: [TextRun('review')]),
          ],
        ),
      ],
    );
    final html = const DocumentPageAdapter().render(ir: ir);
    expect(html, contains('data-section-id="findings"'));
    expect(html, contains('data-section-id="findings-2"'));
    expect(html, contains('<div class="section-body">'));
    expect(html, contains('id="findings"'));
    expect(html, contains('id="findings-2"'));
  });

  test('emits language classes for code blocks', () {
    final ir = const DocumentIr(
      sourceFormat: DocumentFormat.unknown,
      metadata: {},
      body: [CodeBlock(language: 'Dart', text: 'void main() { print("hi"); }')],
    );
    final html = const HtmlDocumentRenderer().render(ir);
    expect(html, contains('class="language-dart"'));
    expect(html, contains('data-lang="dart"'));
    expect(html, contains('void main()'));
  });

  test('previews retained attachment bytes and text safely', () {
    final bytes = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]);
    final ir = DocumentIr(
      sourceFormat: DocumentFormat.image,
      metadata: const {},
      body: const [],
      attachments: [
        Attachment(
          name: 'preview.png',
          mediaType: 'image/png',
          size: bytes.length,
          bytes: bytes,
          relationship: 'Data',
        ),
        const Attachment(
          name: 'notes.txt',
          mediaType: 'text/plain',
          size: 15,
          text: 'attachment body',
        ),
      ],
    );
    final html = const DocumentPageAdapter().render(ir: ir);
    expect(html, contains('id="attachments"'));
    expect(html, contains('data:image/png;base64,'));
    expect(html, contains('download="preview.png"'));
    expect(html, contains('Text preview'));
    expect(html, contains('attachment body'));
    expect(html, contains('Data'));
  });

  test('renders an optional side-by-side version diff', () {
    const before = DocumentIr(
      sourceFormat: DocumentFormat.unknown,
      metadata: {},
      body: [
        ParagraphBlock([TextRun('alpha\nbeta')]),
      ],
    );
    const after = DocumentIr(
      sourceFormat: DocumentFormat.unknown,
      metadata: {},
      body: [
        ParagraphBlock([TextRun('alpha\ngamma')]),
      ],
    );
    final html = const DocumentPageAdapter().render(
      ir: after,
      compareWith: before,
      compareLabel: 'Baseline',
    );
    expect(html, contains('Version comparison'));
    expect(html, contains('Baseline'));
    expect(html, contains('diff-del'));
    expect(html, contains('diff-add'));
    expect(html, contains('gamma'));
    expect(html, contains('beta'));
  });
}
