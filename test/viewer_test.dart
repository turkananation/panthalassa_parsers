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
      expect(standard.builderFor(pdf).id, 'document');
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
