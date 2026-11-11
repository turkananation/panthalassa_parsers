import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:panthalassa_parsers/panthalassa_parsers.dart';
import 'package:test/test.dart';

/// Builds a minimal DOCX package with one paragraph, one heading, and one table.
Uint8List buildDocx({
  String text = 'Hello World',
  String heading = 'Heading One',
  bool withTable = false,
}) {
  final archive = Archive();
  final contentTypes =
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>''';
  final rels = '''<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>''';
  final docRels = '''<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>
''';
  final documentXml =
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>$heading</w:t></w:r></w:p>
    <w:p><w:r><w:t>$text</w:t></w:r></w:p>
    ${withTable ? '''<w:tbl>
      <w:tblGrid>
        <w:gridCol w:w="1000"/><w:gridCol w:w="1000"/>
      </w:tblGrid>
      <w:tr>
        <w:tc><w:p><w:r><w:t>Cell A1</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>Cell B1</w:t></w:r></w:p></w:tc>
      </w:tr>
      <w:tr>
        <w:tc><w:p><w:r><w:t>Cell A2</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>Cell B2</w:t></w:r></w:p></w:tc>
      </w:tr>
    </w:tbl>''' : ''}
  </w:body>
</w:document>''';

  archive.addFile(ArchiveFile.string('[Content_Types].xml', contentTypes));
  archive.addFile(ArchiveFile.string('_rels/.rels', rels));
  archive.addFile(ArchiveFile.string('word/_rels/document.xml.rels', docRels));
  archive.addFile(ArchiveFile.string('word/document.xml', documentXml));

  return Uint8List.fromList(ZipEncoder().encodeBytes(archive) as List<int>);
}

/// Builds a minimal XLSX package with one sheet and a few cells.
Uint8List buildXlsx() {
  final archive = Archive();
  final contentTypes =
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
  <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
</Types>''';
  final rels = '''<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
</Relationships>''';
  final workbookXml = '''<?xml version="1.0" encoding="UTF-8"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheets>
    <sheet name="Sheet1" sheetId="1" r:id="rId1"/>
  </sheets>
</workbook>''';
  final sheet1Xml = '''<?xml version="1.0" encoding="UTF-8"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData>
    <row r="1">
      <c r="A1" t="str"><v>Name</v></c>
      <c r="B1" t="str"><v>Value</v></c>
    </row>
    <row r="2">
      <c r="A2" t="str"><v>Alpha</v></c>
      <c r="B2"><v>42</v></c>
    </row>
  </sheetData>
</worksheet>''';

  archive.addFile(ArchiveFile.string('[Content_Types].xml', contentTypes));
  archive.addFile(ArchiveFile.string('_rels/.rels', rels));
  archive.addFile(ArchiveFile.string('xl/_rels/workbook.xml.rels', rels));
  archive.addFile(ArchiveFile.string('xl/workbook.xml', workbookXml));
  archive.addFile(ArchiveFile.string('xl/worksheets/sheet1.xml', sheet1Xml));

  return Uint8List.fromList(ZipEncoder().encodeBytes(archive) as List<int>);
}

/// Builds a minimal PPTX package with one slide.
Uint8List buildPptx() {
  final archive = Archive();
  final contentTypes =
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
  <Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>
</Types>''';
  final rels = '''<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>
</Relationships>''';
  final presentationXml = '''<?xml version="1.0" encoding="UTF-8"?>
<presentation xmlns="http://schemas.openxmlformats.org/presentationml/2006/main">
  <sldIdLst>
    <sldId id="256" r:id="rId1"/>
  </sldIdLst>
</presentation>''';
  final slide1Xml = '''<?xml version="1.0" encoding="UTF-8"?>
<sld xmlns="http://schemas.openxmlformats.org/presentationml/2006/main">
  <cSld>
    <spTree>
      <sp>
        <txBody>
          <p><a:r xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:t>Slide Title</a:t></a:r></p>
        </txBody>
      </sp>
    </spTree>
  </cSld>
</sld>''';

  archive.addFile(ArchiveFile.string('[Content_Types].xml', contentTypes));
  archive.addFile(ArchiveFile.string('_rels/.rels', rels));
  archive.addFile(ArchiveFile.string('ppt/_rels/presentation.xml.rels', rels));
  archive.addFile(ArchiveFile.string('ppt/presentation.xml', presentationXml));
  archive.addFile(ArchiveFile.string('ppt/slides/slide1.xml', slide1Xml));

  return Uint8List.fromList(ZipEncoder().encodeBytes(archive) as List<int>);
}

void main() {
  final registry = ParserRegistry.standard();

  group('OOXML DOCX', () {
    test('detects DOCX from ZIP + content types', () {
      final r = registry.parse(buildDocx());
      expect(r.format, DocumentFormat.docx);
      expect(r.digest!.sha256, r.documentId);
      expect(r.digest!.sha512, isNotNull);
      expect(r.text, contains('Hello World'));
      expect(r.text, contains('Heading One'));
    });

    test('extracts heading outline', () {
      final r = registry.parse(
        buildDocx(heading: 'Report Title'),
        options: const ParseOptions(includeOutline: true),
      );
      expect(r.outline, isNotEmpty);
      expect(r.outline.first.title, 'Report Title');
    });

    test('extracts table', () {
      final r = registry.parse(
        buildDocx(withTable: true),
        options: const ParseOptions(includeTables: true),
      );
      expect(r.tables, isNotEmpty);
      expect(r.tables.first.rows, hasLength(2));
      expect(r.tables.first.rows[0], contains('Cell A1'));
      expect(r.tables.first.rows[0], contains('Cell B1'));
    });

    test('hints route .docx to docx', () {
      final r = registry.parse(
        buildDocx(),
        hints: const DocumentHints(filename: 'report.docx'),
      );
      expect(r.format, DocumentFormat.docx);
    });

    test('carries both digests', () {
      final r = registry.parse(buildDocx());
      expect(r.documentId, hasLength(64));
      expect(r.sha512, hasLength(128));
      expect(r.sha384, hasLength(96));
      expect(r.digest!.sha256, r.documentId);
    });
  });

  group('OOXML XLSX', () {
    test('detects XLSX and extracts cells', () {
      final r = registry.parse(buildXlsx());
      expect(r.format, DocumentFormat.xlsx);
      expect(r.text, contains('Alpha'));
      expect(r.text, contains('42'));
    });

    test('extracts sheets as tables', () {
      final r = registry.parse(
        buildXlsx(),
        options: const ParseOptions(includeTables: true),
      );
      expect(r.tables, isNotEmpty);
      expect(r.tables.first.rows, hasLength(2));
      expect(r.tables.first.rows[0], contains('Name'));
    });

    test('hints route .xlsx to xlsx', () {
      final r = registry.parse(
        buildXlsx(),
        hints: const DocumentHints(filename: 'data.xlsx'),
      );
      expect(r.format, DocumentFormat.xlsx);
    });
  });

  group('OOXML PPTX', () {
    test('detects PPTX and extracts slide text', () {
      final r = registry.parse(buildPptx());
      expect(r.format, DocumentFormat.pptx);
      expect(r.text, contains('Slide Title'));
    });

    test('extracts slides as pages', () {
      final r = registry.parse(
        buildPptx(),
        options: const ParseOptions(includeStructuredText: true),
      );
      expect(r.structuredText, isNotNull);
      expect(r.structuredText!.pages, hasLength(1));
    });

    test('hints route .pptx to pptx', () {
      final r = registry.parse(
        buildPptx(),
        hints: const DocumentHints(filename: 'deck.pptx'),
      );
      expect(r.format, DocumentFormat.pptx);
    });
  });

  group('OOXML attachment passthrough', () {
    test('surfaces embedded media as attachments', () async {
      // Build a DOCX with a media entry by manually adding to the archive.
      final archive = Archive();
      archive.addFile(
        ArchiveFile.string('[Content_Types].xml', '''
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Default Extension="png" ContentType="image/png"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>'''),
      );
      archive.addFile(
        ArchiveFile.string('_rels/.rels', '''
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>'''),
      );
      archive.addFile(
        ArchiveFile.string(
          'word/_rels/document.xml.rels',
          '''
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>''',
        ),
      );
      archive.addFile(
        ArchiveFile.string('word/document.xml', '''
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body><w:p><w:r><w:t>Text</w:t></w:r></w:p></w:body>
</w:document>'''),
      );
      archive.addFile(
        ArchiveFile.bytes('word/media/image.png', [0x89, 0x50, 0x4E, 0x47]),
      );

      final bytes = Uint8List.fromList(
        ZipEncoder().encodeBytes(archive) as List<int>,
      );
      final r = registry.parse(
        bytes,
        options: const ParseOptions(
          includeAttachments: true,
          includeAttachmentBytes: true,
        ),
      );
      expect(r.format, DocumentFormat.docx);
      expect(r.attachments, isNotEmpty);
      expect(r.attachments.first.name, 'image.png');
      expect(r.attachments.first.mediaType, 'image/png');
      expect(r.attachments.first.digest, isNotNull);
      expect(r.attachments.first.hasBytes, isTrue);
    });
  });
}
