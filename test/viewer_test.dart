import 'dart:convert';
import 'dart:typed_data';

import 'package:panthalassa_parsers/panthalassa_parsers.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final registry = ParserRegistry.standard();

  ParseResult parseCsv(String text, {String filename = 'rows.csv'}) =>
      registry.parse(
        Uint8List.fromList(utf8.encode(text)),
        hints: DocumentHints(filename: filename),
      );

  ViewerRequest request(
    ParseResult result, {
    ViewerOptions options = const ViewerOptions(),
    String filename = 'document',
    Uint8List? bytes,
  }) => ViewerRequest(
    result: result,
    bytes: bytes ?? Uint8List.fromList(utf8.encode('source')),
    filename: filename,
    options: options,
  );

  group('ViewerRegistry', () {
    test('selects dedicated CSV and DICOM builders', () {
      final csv = parseCsv('name,value\nalpha,1');
      final dicom = registry.parse(
        buildDicomImage(rows: 1, columns: 1, pixelBytes: [0]),
      );
      final pdf = registry.parse(buildSimplePdf(showText: 'Hello'));

      final standard = ViewerRegistry.standard();
      expect(standard.builderFor(csv).id, 'csv');
      expect(standard.builderFor(dicom).id, 'dicom');
      expect(standard.builderFor(pdf).id, 'pdf');
    });
  });

  group('CsvViewBuilder', () {
    test('maps header, rows, facts, and TSV delimiter', () {
      final result = parseCsv('name,value\nalpha,1\nbeta,2');
      final viewer = const CsvViewBuilder().build(
        request(result, filename: 'people.csv'),
      );

      expect(viewer.title, 'people.csv');
      expect(viewer.formatLabel, 'CSV');
      expect(viewer.facts['Rows'], '2');
      expect(viewer.facts['Columns'], '2');
      expect(viewer.facts['Delimiter'], ',');
      expect(viewer.subtitle, contains('2 rows'));
      final table = viewer.sections.single as ViewerTableSection;
      expect(table.columns, ['name', 'value']);
      expect(table.rows, [
        ['alpha', '1'],
        ['beta', '2'],
      ]);
      expect(table.truncated, isFalse);
      expect(table.totalRowCount, 2);

      final tsv = parseCsv('name\tvalue\nalpha\t1', filename: 'rows.tsv');
      final tsvViewer = const CsvViewBuilder().build(request(tsv));
      expect(tsvViewer.formatLabel, 'TSV');
      expect(tsvViewer.facts['Delimiter'], 'tab');
    });

    test('limits rows by default and honours allRows', () {
      final result = parseCsv('name\none\ntwo\nthree');
      final limited = const CsvViewBuilder().build(
        request(
          result,
          options: const ViewerOptions(rowLimit: 1),
          filename: 'rows.csv',
        ),
      );
      final table = limited.sections.single as ViewerTableSection;
      expect(table.rows, hasLength(1));
      expect(table.truncated, isTrue);
      expect(table.totalRowCount, 3);

      final all = const CsvViewBuilder().build(
        request(
          result,
          options: const ViewerOptions(rowLimit: 1, allRows: true),
          filename: 'rows.csv',
        ),
      );
      final allTable = all.sections.single as ViewerTableSection;
      expect(allTable.rows, hasLength(3));
      expect(allTable.truncated, isFalse);
    });

    test('normalises ragged rows and fills unnamed headers', () {
      final result = parseCsv('name,\nalpha,1,extra');
      final viewer = const CsvViewBuilder().build(request(result));
      final table = viewer.sections.single as ViewerTableSection;
      expect(table.columns, ['name', 'Column 2', 'Column 3']);
      expect(table.rows, [
        ['alpha', '1', 'extra'],
      ]);
    });

    test('falls back to text when table extraction is disabled', () {
      final result = registry.parse(
        Uint8List.fromList(utf8.encode('name,value\nalpha,1')),
        hints: const DocumentHints(filename: 'rows.csv'),
        options: const ParseOptions(includeTables: false),
      );

      final viewer = const CsvViewBuilder().build(request(result));
      expect(viewer.sections.single, isA<ViewerTextSection>());
      expect(
        viewer.notices.map((notice) => notice.message).join(' '),
        contains('--tables'),
      );
    });
  });

  group('DicomViewBuilder', () {
    test('decodes the selected frame to a PNG asset', () {
      final bytes = buildDicomImage(
        rows: 1,
        columns: 2,
        pixelBytes: [0, 255],
        windowCenter: 128,
        windowWidth: 256,
      );
      final result = registry.parse(bytes);
      final viewer = const DicomViewBuilder().build(
        request(
          result,
          bytes: bytes,
          filename: 'scan.dcm',
          options: const ViewerOptions(
            title: 'CT scan',
            windowCenter: 128,
            windowWidth: 256,
          ),
        ),
      );

      expect(viewer.title, 'CT scan');
      expect(viewer.facts['Dimensions'], '2 × 1');
      expect(viewer.facts['Patient'], 'DOE, JANE');
      expect(viewer.facts['Modality'], 'CT');
      expect(viewer.assets.keys, contains('frame-0.png'));
      final png = viewer.assets['frame-0.png']!.bytes;
      expect(png.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);

      final image = viewer.sections.single as ViewerImageSection;
      expect(image.assetName, 'frame-0.png');
      expect(image.width, 2);
      expect(image.height, 1);
      expect(image.caption, contains('W/L 128.0/256.0'));
    });

    test('renders every frame up to the static-viewer cap', () {
      final bytes = buildDicomImage(
        rows: 1,
        columns: 1,
        numberOfFrames: 2,
        pixelBytes: [0, 255],
      );
      final result = registry.parse(bytes);
      final viewer = const DicomViewBuilder().build(
        request(
          result,
          bytes: bytes,
          options: const ViewerOptions(allFrames: true),
        ),
      );

      expect(viewer.assets.keys, ['frame-0.png', 'frame-1.png']);
      expect(viewer.sections, hasLength(2));
    });

    test('degrades to metadata when Pixel Data is absent', () {
      final bytes = buildMinimalDicom();
      final viewer = const DicomViewBuilder().build(
        request(registry.parse(bytes), bytes: bytes, filename: 'meta.dcm'),
      );

      expect(viewer.sections, isEmpty);
      expect(viewer.assets, isEmpty);
      expect(
        viewer.notices.map((notice) => notice.message).join(' '),
        contains('no Pixel Data'),
      );
    });

    test('reports unsupported codecs without hiding metadata', () {
      final bytes = buildEncapsulatedDicomImage(
        rows: 1,
        columns: 1,
        frame: [1, 2, 3, 4],
        transferSyntax: '1.2.840.10008.1.2.4.90',
      );
      final viewer = const DicomViewBuilder().build(
        request(registry.parse(bytes), bytes: bytes),
      );

      expect(viewer.sections, isEmpty);
      expect(
        viewer.notices.map((notice) => notice.message).join(' '),
        contains('not supported for pixel rendering'),
      );
      expect(viewer.facts['Transfer syntax'], isNotEmpty);
    });
  });

  group('SpreadsheetViewBuilder', () {
    test('renders XLSX sheets as sections with row totals', () {
      final result = registry.parse(
        buildSpreadsheetXlsx(),
        options: const ParseOptions(includeTables: true),
      );
      expect(result.format, DocumentFormat.xlsx);
      final viewer = const SpreadsheetViewBuilder().build(
        request(result, bytes: buildSpreadsheetXlsx(), filename: 'budget.xlsx'),
      );

      expect(viewer.title, 'budget.xlsx');
      expect(viewer.formatLabel, 'SpreadsheetML (XLSX)');
      expect(viewer.facts['Sheets'], '2');
      expect(viewer.facts['Rows'], '2');
      final titles = viewer.sections
          .whereType<ViewerTableSection>()
          .map((s) => s.title)
          .toList();
      expect(titles, contains('Budget'));
      expect(titles, contains('Notes'));
      expect(viewer.subtitle, contains('2 sheets'));
    });

    test('renders ODS spreadsheets as sections', () {
      final result = registry.parse(
        buildSpreadsheetOds(),
        options: const ParseOptions(includeTables: true),
      );
      expect(result.format, DocumentFormat.odf);
      expect(result.metadata['documentClass'], 'spreadsheet');
      final viewer = const SpreadsheetViewBuilder().build(
        request(result, bytes: buildSpreadsheetOds(), filename: 'budget.ods'),
      );
      expect(viewer.formatLabel, 'ODS spreadsheet');
      expect(viewer.sections, hasLength(1));
      final table = viewer.sections.single as ViewerTableSection;
      expect(table.title, 'Budget');
      expect(table.columns, ['Item', 'Amount']);
      expect(table.rows, [
        ['Alpha', '42'],
      ]);
    });

    test('does not claim unsupported formats', () {
      final csv = parseCsv('name,value\nalpha,1');
      expect(const SpreadsheetViewBuilder().supports(csv), isFalse);
    });
  });

  group('ImageViewBuilder', () {
    test('embeds PNG preview with metadata table', () {
      final bytes = buildViewerPng(width: 4, height: 3);
      final result = registry.parse(bytes);
      expect(result.format, DocumentFormat.image);
      expect(result.metadata['mediaType'], 'image/png');
      expect(result.metadata['width'], 4);
      expect(result.metadata['height'], 3);
      final viewer = const ImageViewBuilder().build(
        request(result, bytes: bytes, filename: 'chart.png'),
      );
      expect(viewer.formatLabel, 'PNG');
      expect(viewer.facts['Dimensions'], '4 × 3 px');
      expect(viewer.assets.keys, contains('image.png'));
      final images = viewer.sections.whereType<ViewerImageSection>();
      expect(images, hasLength(1));
      final image = images.single;
      expect(image.assetName, 'image.png');
      expect(image.width, 4);
      expect(image.height, 3);
    });

    test('metadata-only for TIFF', () {
      final bytes = Uint8List.fromList([0x49, 0x49, 0x2A, 0x00]);
      final result = registry.parse(bytes);
      final viewer = const ImageViewBuilder().build(
        request(result, bytes: bytes, filename: 'scan.tiff'),
      );
      expect(viewer.formatLabel, 'TIFF');
      expect(viewer.notices.any((n) => n.message.contains('TIFF')), isTrue);
      expect(viewer.sections.any((s) => s is ViewerImageSection), isFalse);
    });

    test('does not claim non-image formats', () {
      final csv = parseCsv('name,value\nalpha,1');
      expect(const ImageViewBuilder().supports(csv), isFalse);
    });
  });

  group('EmailViewBuilder', () {
    test('renders headers, body, and attachments without HTML', () {
      final bytes = buildEmlWithAttachment();
      final result = registry.parse(bytes);
      expect(result.format, DocumentFormat.eml);
      expect(result.metadata['subject'], 'Viewer message');
      final viewer = const EmailViewBuilder().build(
        request(result, bytes: bytes, filename: 'message.eml'),
      );
      expect(viewer.formatLabel, result.format.label);
      expect(viewer.facts['Subject'], 'Viewer message');
      expect(viewer.facts['From'], 'sender@example.com');
      expect(viewer.facts['To'], 'recipient@example.com');
      expect(
        viewer.sections.any(
          (s) => s is ViewerTextSection && s.text == 'Hello from the viewer.',
        ),
        isTrue,
      );
      final attachments = viewer.sections.whereType<ViewerTableSection>();
      expect(attachments.single.rows.first, [
        'report.pdf',
        'application/pdf',
        hasLength(greaterThan(0)),
      ]);
      expect(viewer.facts['Attachments'], isNotNull);
      // HTML parts are never rendered — body stays escaped text.
      expect(viewer.notices.any((n) => n.message.contains('HTML')), isFalse);
    });

    test('does not claim non-email formats', () {
      final csv = parseCsv('name,value\nalpha,1');
      expect(const EmailViewBuilder().supports(csv), isFalse);
    });
  });

  group('PdfViewBuilder', () {
    test('embeds the PDF asset and shows extracted text', () {
      final bytes = buildSimplePdf(showText: 'Hello Panthalassa Vault');
      final result = registry.parse(bytes);
      expect(result.format, DocumentFormat.pdf);
      final viewer = const PdfViewBuilder().build(
        request(result, bytes: bytes, filename: 'report.pdf'),
      );
      expect(viewer.formatLabel, 'PDF');
      expect(viewer.assets.keys, contains('document.pdf'));
      final embed = viewer.sections.whereType<ViewerEmbedSection>();
      expect(embed, isNotEmpty);
      final textSection = viewer.sections.whereType<ViewerTextSection>();
      expect(textSection.any((s) => s.text.contains('Hello')), isTrue);
    });

    test('shows extracted text only for encrypted PDFs', () {
      final bytes = buildEncryptedPdf();
      final result = registry.parse(bytes);
      expect(result.metadata['encrypted'], true);
      final viewer = const PdfViewBuilder().build(
        request(result, bytes: bytes, filename: 'secret.pdf'),
      );
      expect(viewer.assets, isEmpty);
      expect(viewer.sections.any((s) => s is ViewerEmbedSection), isFalse);
      expect(
        viewer.notices.any((n) => n.message.contains('encrypted')),
        isTrue,
      );
    });

    test('does not claim non-PDF formats', () {
      final csv = parseCsv('name,value\nalpha,1');
      expect(const PdfViewBuilder().supports(csv), isFalse);
    });
  });

  group('StructuredSourceViewBuilder', () {
    test('pretty-prints JSON and escapes before display', () {
      final bytes = Uint8List.fromList(
        utf8.encode('{"name":"<script>","count":2}'),
      );
      final result = registry.parse(bytes);
      expect(result.format, DocumentFormat.json);
      final viewer = const StructuredSourceViewBuilder().build(
        request(result, bytes: bytes, filename: 'data.json'),
      );
      expect(viewer.formatLabel, 'JSON');
      expect(viewer.sections.single, isA<ViewerTextSection>());
      final text = (viewer.sections.single as ViewerTextSection).text;
      expect(text, contains('{'));
      expect(text, contains('"name": "<script>"'));
      expect(text, contains('"count": 2'));
      // HTML escaping happens at render time.
      final html = const ViewerHtmlRenderer().render(viewer);
      expect(html, contains('&lt;script&gt;'));
    });

    test('pretty-prints XML and NIEM', () {
      final xmlBytes = Uint8List.fromList(
        utf8.encode('<root><child>one</child></root>'),
      );
      final xmlResult = registry.parse(xmlBytes);
      expect(xmlResult.format, DocumentFormat.xml);
      final xmlViewer = const StructuredSourceViewBuilder().build(
        request(xmlResult, bytes: xmlBytes, filename: 'data.xml'),
      );
      expect(xmlViewer.formatLabel, 'XML');
      final xmlText = (xmlViewer.sections.single as ViewerTextSection).text;
      expect(xmlText, contains('<root>'));

      final niemBytes = Uint8List.fromList(
        utf8.encode('{"nc:PersonName":{"nc:PersonGivenName":"Jane"}}'),
      );
      final niemResult = registry.parse(niemBytes);
      expect(niemResult.format, DocumentFormat.niem);
      expect(niemResult.metadata['profile'], 'NIEM JSON');
      final niemViewer = const StructuredSourceViewBuilder().build(
        request(niemResult, bytes: niemBytes, filename: 'niem.json'),
      );
      expect(niemViewer.formatLabel, 'NIEM');
    });

    test('truncates very large sources', () {
      final big =
          '{"items":[${List.generate(200000, (i) => '"item$i"').join(',')}]}';
      final bytes = Uint8List.fromList(utf8.encode(big));
      final result = registry.parse(bytes);
      final viewer = const StructuredSourceViewBuilder().build(
        request(result, bytes: bytes, filename: 'big.json'),
      );
      expect(
        viewer.notices.any((n) => n.message.contains('truncated')),
        isTrue,
      );
    });

    test('does not claim non-structured formats', () {
      final csv = parseCsv('name,value\nalpha,1');
      expect(const StructuredSourceViewBuilder().supports(csv), isFalse);
    });
  });

  group('DicomViewBuilder SR and no-pixel', () {
    test('shows report text and table for Structured Report instances', () {
      final bytes = buildDicomStructuredReport(
        finding: 'Clear lungs, normal heart size',
      );
      final result = registry.parse(
        bytes,
        options: const ParseOptions(includeTables: true),
      );
      expect(result.format, DocumentFormat.dicom);
      expect(result.metadata['hasPixelData'], isFalse);
      final viewer = const DicomViewBuilder().build(
        request(result, bytes: bytes, filename: 'report.dcm'),
      );
      expect(viewer.sections, isNotEmpty);
      expect(
        viewer.sections.any(
          (s) => s is ViewerTextSection && s.text.contains('Clear lungs'),
        ),
        isTrue,
      );
      final tables = viewer.sections.whereType<ViewerTableSection>();
      expect(tables, isNotEmpty);
    });

    test('degrades gracefully for a DICOM instance without Pixel Data', () {
      final bytes = buildMinimalDicom();
      final result = registry.parse(bytes);
      final viewer = const DicomViewBuilder().build(
        request(result, bytes: bytes, filename: 'meta.dcm'),
      );
      expect(viewer.sections, isEmpty);
      expect(viewer.assets, isEmpty);
      expect(
        viewer.notices.map((notice) => notice.message).join(' '),
        contains('no Pixel Data'),
      );
    });
  });

  group('DocumentViewBuilder', () {
    test('renders the semantic fallback with escaped HTML', () {
      final bytes = buildSimplePdf(showText: 'Viewer <PDF> & friends');
      final viewer = const DocumentViewBuilder().build(
        request(
          registry.parse(bytes),
          bytes: bytes,
          filename: 'report.pdf',
          options: const ViewerOptions(title: 'Report'),
        ),
      );

      expect(viewer.title, 'Report');
      expect(viewer.facts['Format'], 'PDF');
      final section = viewer.sections.single as ViewerHtmlSection;
      expect(section.html, contains('Viewer &lt;PDF&gt; &amp; friends'));
      expect(section.html, contains('panthalassa-document'));
    });
  });

  group('ViewerHtmlRenderer', () {
    test('emits a self-contained, filterable, escaped HTML document', () {
      final result = parseCsv('name,value\n<script>,1\nbeta,2');
      const viewer = ViewerDocument(
        title: 'Rows <unsafe> & "quoted"',
        formatLabel: 'CSV',
        subtitle: 'A table',
        facts: {'Rows': '2'},
        sections: [
          ViewerTableSection(
            title: 'Data',
            columns: ['name', 'value'],
            rows: [
              ['<script>', '1'],
            ],
            totalRowCount: 1,
          ),
        ],
        notices: [
          ViewerNotice('Check <this>', level: ViewerNoticeLevel.warning),
        ],
      );
      final html = const ViewerHtmlRenderer().render(viewer);

      expect(html, startsWith('<!doctype html>'));
      expect(html, contains('Rows &lt;unsafe&gt; &amp; &quot;quoted&quot;'));
      expect(html, contains('&lt;script&gt;'));
      expect(html, isNot(contains('<script>alert')));
      expect(html, contains('data-filter="viewer-table-0"'));
      expect(html, contains('Filter rows'));
      expect(html, contains('viewer-lightbox'));
      expect(html, contains('Check &lt;this&gt;'));
      expect(html, contains('A table'));
      expect(result.tables, isNotEmpty);
    });

    test('embeds image assets as data URIs', () {
      final result = parseCsv('name\nalpha');
      final viewer = const CsvViewBuilder().build(request(result));
      final bytes = buildDicomImage(rows: 1, columns: 1, pixelBytes: [128]);
      final dicom = registry.parse(bytes);
      final dicomViewer = const DicomViewBuilder().build(
        request(dicom, bytes: bytes),
      );

      final html = const ViewerHtmlRenderer().render(dicomViewer);
      expect(html, contains('data:image/png;base64,'));
      expect(html, contains('data-zoom="true"'));
      expect(html, contains('<h2>Image</h2>'));
      expect(viewer.title, isNotEmpty);
    });

    test('escapes text sections and monospace content', () {
      const viewer = ViewerDocument(
        title: 'Text',
        formatLabel: 'Text',
        sections: [ViewerTextSection(text: '<b>raw</b>', monospace: true)],
      );
      final html = const ViewerHtmlRenderer().render(viewer);
      expect(html, contains('&lt;b&gt;raw&lt;/b&gt;'));
      expect(html, contains('text-block mono'));
    });
  });
}
