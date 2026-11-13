import 'dart:convert';
import 'dart:typed_data';

import 'package:panthalassa_parsers/panthalassa_parsers.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final registry = ParserRegistry.standard();

  test(
    'projects ParseResult into DIR and renders text, Markdown, and HTML',
    () {
      final result = registry.parse(
        buildSimplePdf(showText: 'Render <Engine>'),
      );
      final doc = DocumentIr.fromParseResult(result);

      expect(doc.sourceFormat, DocumentFormat.pdf);
      expect(doc.contentId, result.documentId);
      expect(doc.body.whereType<ParagraphBlock>(), isNotEmpty);
      expect(doc.body.whereType<RawVisualBlock>(), isNotEmpty);

      final text = const TextDocumentRenderer().render(doc);
      expect(text, contains('Render <Engine>'));
      expect(text, isNot(contains('visualPages')));

      final markdown = const MarkdownDocumentRenderer().render(doc);
      expect(markdown, contains('Render <Engine>'));

      final html = const HtmlDocumentRenderer().render(doc);
      expect(html, contains('data-format="pdf"'));
      expect(html, contains('Render &lt;Engine&gt;'));
    },
  );

  test('PDF visual pages project into a faithful display list and SVG', () {
    final result = registry.parse(buildSimplePdf(showText: 'Pixel Layer'));
    final visualPages = result.metadata['visualPages'] as List;
    expect(visualPages, hasLength(1));

    final doc = DocumentIr.fromParseResult(result);
    final visual = doc.toVisualDocument();

    expect(visual.sourceFormat, DocumentFormat.pdf);
    expect(visual.pages, hasLength(1));
    expect(visual.pages.single.geometry.width, 612);
    expect(visual.pages.single.geometry.height, 792);
    expect(
      visual.pages.single.commands.whereType<VisualTextCommand>().single.text,
      'Pixel Layer',
    );

    final svg = const SvgVisualRenderer().render(visual);
    expect(svg, contains('viewBox="0 0 612 792"'));
    expect(svg, contains('Pixel Layer'));
    expect(svg, contains('font-size="24"'));

    final inherited = DocumentIr.fromParseResult(
      registry.parse(buildInheritedPageBoxPdf()),
    ).toVisualDocument();
    expect(inherited.pages.single.geometry.width, 300);
    expect(inherited.pages.single.geometry.height, 200);
  });

  test('PDF `cm` graphics-state transform is applied to text position', () {
    final result = registry.parse(buildTransformedPdf(showText: 'Scaled Text'));
    final visualPages = result.metadata['visualPages'] as List;
    expect(visualPages, hasLength(1));

    final doc = DocumentIr.fromParseResult(result).toVisualDocument();
    expect(doc.pages, hasLength(1));

    final textCommands = doc.pages.single.commands
        .whereType<VisualTextCommand>()
        .toList();
    expect(textCommands, hasLength(1));
    final command = textCommands.single;
    expect(command.text, 'Scaled Text');
    // CTM = [2, 0, 0, 2, 100, 100] applied to text position (0, 0) → (100, 100)
    expect(command.x, 100);
    expect(command.y, 100);

    final svg = const SvgVisualRenderer().render(doc);
    expect(svg, contains('x="100"'));
    // SVG flips Y for screen space: 792 - 100 = 692
    expect(svg, contains('y="692"'));
    expect(svg, contains('Scaled Text'));

    // `cm` must not surface as an unsupported operator
    final unsupported = doc.pages.single.commands
        .whereType<VisualUnsupportedCommand>();
    expect(unsupported.any((c) => c.operatorName == 'cm'), isFalse);
  });

  test('PDF `q`/`Q` graphics-state save/restore resets CTM', () {
    final result = registry.parse(buildSavedStatePdf());
    final doc = DocumentIr.fromParseResult(result).toVisualDocument();
    expect(doc.pages, hasLength(1));

    final texts = doc.pages.single.commands
        .whereType<VisualTextCommand>()
        .toList();
    expect(texts, hasLength(2));

    // Inner text: CTM [3, 0, 0, 3, 50, 50] applied to (0, 0) → (50, 50)
    expect(texts[0].text, 'Inner');
    expect(texts[0].x, 50);
    expect(texts[0].y, 50);

    // Outer text: after Q, CTM is identity, so (72, 700) stays (72, 700)
    expect(texts[1].text, 'Outer');
    expect(texts[1].x, 72);
    expect(texts[1].y, 700);
  });

  test('PDF `cm` transform is applied to rectangle commands', () {
    final content = ascii.encode(
      '1 0 0 1 120 640 cm 0.2 0.4 0.6 rg 120 640 80 30 re f',
    );
    final result = registry.parse(
      _pdfWithContent(content),
      options: const ParseOptions(includeVisual: true),
    );
    final doc = DocumentIr.fromParseResult(result).toVisualDocument();
    expect(doc.pages, hasLength(1));

    final rects = doc.pages.single.commands
        .whereType<VisualRectCommand>()
        .toList();
    expect(rects, hasLength(1));
    final rect = rects.single;
    // CTM [1, 0, 0, 1, 120, 640] applied to rect origin (120, 640) → (240, 1280)
    // But page height is 792, so this rect is off-page — that's fine, we just
    // verify the transform was applied.
    expect(rect.x, 240);
    expect(rect.y, 1280);
    expect(rect.width, 80);
    expect(rect.height, 30);
    expect(rect.fill?.hex, '#336699');
  });

  test('PDF visual extraction surfaces rectangles and image placeholders', () {
    final shape = DocumentIr.fromParseResult(
      registry.parse(buildVisualShapePdf()),
    ).toVisualDocument();
    final rect = shape.pages.single.commands
        .whereType<VisualRectCommand>()
        .single;
    expect(rect.x, 120);
    expect(rect.y, 640);
    expect(rect.width, 80);
    expect(rect.height, 30);
    expect(rect.fill?.hex, '#336699');

    final image = DocumentIr.fromParseResult(
      registry.parse(buildInlineImagePdf()),
    ).toVisualDocument();
    expect(
      image.pages.single.commands.whereType<VisualImageCommand>(),
      isNotEmpty,
    );
  });

  test(
    'binary metadata-only formats still produce a screen-renderable DIR',
    () {
      final result = registry.parse(buildDicomWithSequenceAndMultiValues());
      final doc = DocumentIr.fromParseResult(result);

      final text = const TextDocumentRenderer().render(doc);
      expect(text, contains('Metadata'));
      expect(text, contains('modality: MR'));
      expect(text, contains('referencedSeriesSequence'));

      final html = const HtmlDocumentRenderer().render(doc);
      expect(html, contains('data-format="dicom"'));
      expect(html, contains('referencedSeriesSequence'));
    },
  );

  test('NITF image metadata projects to visual image placeholders', () {
    final result = registry.parse(buildNitfWithSegments());
    final doc = DocumentIr.fromParseResult(result);
    final visual = doc.toVisualDocument();

    expect(visual.pages, hasLength(1));
    expect(visual.pages.single.geometry.width, 256);
    expect(visual.pages.single.geometry.height, 128);
    expect(
      visual.pages.single.commands
          .whereType<VisualImageCommand>()
          .single
          .sourceId,
      'IMG0000001',
    );
  });

  test('all fixture families produce nonblank semantic HTML', () {
    final cases = <String, Uint8List>{
      'dicom': buildDicomWithSequenceAndMultiValues(),
      'nitf': buildNitfWithSegments(),
      'odf': buildMinimalOdf(),
      'pdf': buildSimplePdf(),
      'stanag4607': buildStanag4607Gmti(),
      'stanag4609': buildMpegTsWithKlv(),
      'stanag7023': buildStanag7023Npif(),
      'stanag5516': buildStanag5516Link16(),
      'fhirXml': Uint8List.fromList(
        utf8.encode(
          '<Patient xmlns="http://hl7.org/fhir"><id value="p1"/></Patient>',
        ),
      ),
      'json': Uint8List.fromList(utf8.encode('{"hello":"world"}')),
      'xml': Uint8List.fromList(
        utf8.encode('<root><value>world</value></root>'),
      ),
      'edifact': Uint8List.fromList(utf8.encode("UNB+UNOC:3+S+R+1'UNZ+0+1'")),
      'x12': Uint8List.fromList(
        utf8.encode(
          'ISA*00*          *00*          *ZZ*SENDER         *ZZ*RECEIVER       *260621*1530*U*00401*000000001*0*T*:~GS*HC*S*R*20260621*1530*1*X*005010X222~ST*837*0001~SE*2*0001~GE*1*1~IEA*1*000000001~',
        ),
      ),
      'step': Uint8List.fromList(
        utf8.encode(
          "ISO-10303-21;\nHEADER;\nFILE_SCHEMA(('IFC4'));\nENDSEC;\nDATA;\n#1=THING();\nENDSEC;\nEND-ISO-10303-21;",
        ),
      ),
      'usmtf': Uint8List.fromList(utf8.encode('MSGID/TEST/1//\nREF/A//')),
    };

    for (final entry in cases.entries) {
      final result = registry.parse(entry.value);
      final html = const HtmlDocumentRenderer().render(
        DocumentIr.fromParseResult(result),
      );
      expect(html, startsWith('<article'), reason: entry.key);
      expect(html.length, greaterThan(60), reason: entry.key);
    }
  });

  test('capability catalog describes major parser families conservatively', () {
    final parsers = [
      const _Parser(DocumentFormat.dicom),
      const _Parser(DocumentFormat.pdf),
      const _Parser(DocumentFormat.nitf),
      const _Parser(DocumentFormat.stanag),
    ];
    expect(parsers[0].capabilities, contains(DocumentCapability.media));
    expect(parsers[1].capabilities, contains(DocumentCapability.attachments));
    expect(parsers[2].capabilities, contains(DocumentCapability.structure));
    expect(parsers[3].capabilities, contains(DocumentCapability.media));
  });
}

final class _Parser implements DocumentParser {
  const _Parser(this.format);

  @override
  final DocumentFormat format;

  @override
  bool canParse(Uint8List bytes) => false;

  @override
  ParseResult parse(Uint8List bytes, {required ContentHasher hasher}) =>
      throw const UnsupportedFormatException('test parser');
}

/// Builds a minimal PDF with an arbitrary content stream, for testing visual
/// operators in isolation.
Uint8List _pdfWithContent(Uint8List content) {
  final out = BytesBuilder();
  void put(String s) => out.add(latin1.encode(s));

  put('%PDF-1.7\n');
  put('1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');
  put('2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n');
  put(
    '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
    '/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>\nendobj\n',
  );
  put('4 0 obj\n<< /Length ${content.length} >>\nstream\n');
  out.add(content);
  put('\nendstream\nendobj\n');
  put(
    '5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n',
  );
  put('trailer\n<< /Root 1 0 R >>\n%%EOF');
  return out.toBytes();
}
