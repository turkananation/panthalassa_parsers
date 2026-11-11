import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:panthalassa_parsers/panthalassa_parsers.dart';
import 'package:test/test.dart';

Uint8List u8(String s) => Uint8List.fromList(utf8.encode(s));

/// Builds a minimal baseline JPEG: SOI, SOF0, EOI.
Uint8List buildJpeg({int width = 320, int height = 240}) {
  final b = BytesBuilder();
  b.add([0xFF, 0xD8]); // SOI
  b.add([0xFF, 0xC0]); // SOF0
  final frame = <int>[
    8, // precision
    (height >> 8) & 0xFF,
    height & 0xFF,
    (width >> 8) & 0xFF,
    width & 0xFF,
    3, // components
    1, 0x11, 0, // Y
    2, 0x11, 0, // Cb
    3, 0x11, 0, // Cr
  ];
  final length = frame.length + 2;
  b.add([(length >> 8) & 0xFF, length & 0xFF]);
  b.add(frame);
  b.add([0xFF, 0xD9]); // EOI
  return b.toBytes();
}

/// Builds a minimal PNG with IHDR, tEXt, and IEND chunks.
Uint8List buildPng({int width = 640, int height = 480}) {
  final b = BytesBuilder();
  b.add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  List<int> u32(int v) => [
    (v >> 24) & 0xFF,
    (v >> 16) & 0xFF,
    (v >> 8) & 0xFF,
    v & 0xFF,
  ];

  void chunk(String type, List<int> data) {
    b.add(u32(data.length));
    b.add(ascii.encode(type));
    b.add(data);
    b.add([0, 0, 0, 0]); // CRC is not validated by the metadata reader
  }

  chunk('IHDR', [
    ...u32(width),
    ...u32(height),
    8, // bit depth
    2, // RGB
    0,
    0,
    0,
  ]);
  chunk('tEXt', [...ascii.encode('Comment'), 0, ...ascii.encode('fixture')]);
  chunk('IEND', const []);
  return b.toBytes();
}

/// Builds a minimal EPUB 3 container with one chapter, nav TOC, and cover.
Uint8List buildEpub() {
  final archive = Archive();
  void add(String name, String content) =>
      archive.addFile(ArchiveFile.string(name, content));

  add('mimetype', 'application/epub+zip');
  add('META-INF/container.xml', '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''');
  add('OEBPS/content.opf', '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Test Book</dc:title>
    <dc:creator>Jane Doe</dc:creator>
    <dc:language>en</dc:language>
    <dc:identifier id="bookid">urn:uuid:12345678</dc:identifier>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>
  </manifest>
  <spine>
    <itemref idref="ch1"/>
  </spine>
</package>''');
  add('OEBPS/nav.xhtml', '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
  <head><title>Contents</title></head>
  <body>
    <nav epub:type="toc"><ol><li><a href="chapter1.xhtml">Chapter One</a></li></ol></nav>
  </body>
</html>''');
  add('OEBPS/chapter1.xhtml', '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapter One</title></head>
  <body>
    <h1>Chapter One</h1>
    <p>Hello EPUB.</p>
    <table>
      <tr><th>A</th><th>B</th></tr>
      <tr><td>1</td><td>2</td></tr>
    </table>
  </body>
</html>''');
  final cover = buildPng(width: 16, height: 16);
  archive.addFile(ArchiveFile('OEBPS/cover.png', cover.length, cover));

  return Uint8List.fromList(ZipEncoder().encodeBytes(archive) as List<int>);
}

String buildDicomJson() {
  final embedded = base64Encode(
    utf8.encode(
      '<?xml version="1.0"?>'
      '<ClinicalDocument xmlns="urn:hl7-org:v3">'
      '<title>Encapsulated CDA</title></ClinicalDocument>',
    ),
  );
  return '''{
  "00080060": {"vr": "CS", "Value": ["CT"]},
  "00100010": {"vr": "PN", "Value": [{"Alphabetic": "DOE^JANE"}]},
  "0040A730": {"vr": "SQ", "Value": [
    {
      "0040A040": {"vr": "CS", "Value": ["CONTAINER"]},
      "0040A043": {"vr": "SQ", "Value": [
        {"00080100": {"vr": "SH", "Value": ["121071"]},
         "00080104": {"vr": "LO", "Value": ["Finding"]}}
      ]},
      "0040A730": {"vr": "SQ", "Value": [
        {
          "0040A040": {"vr": "CS", "Value": ["TEXT"]},
          "0040A160": {"vr": "UT", "Value": ["Nodule present"]},
          "0040A043": {"vr": "SQ", "Value": [
            {"00080104": {"vr": "LO", "Value": ["Observation"]}}
          ]}
        }
      ]}
    }
  ]},
  "00400010": {"vr": "ST", "Value": ["Encapsulated Doc"]},
  "00400011": {"vr": "OB", "InlineBinary": "$embedded"},
  "00400012": {"vr": "LO", "Value": ["application/xml"]}
}''';
}

void main() {
  final registry = ParserRegistry.standard();

  group('Markdown', () {
    test('requires a hint and extracts structure', () {
      final bytes = u8('''---
title: Test Note
author: Jane
---

# Heading One

Intro with **bold** text and [a link](https://example.com).

## Section Two

- item one
- item two

| A | B |
| --- | --- |
| 1 | 2 |

```dart
void main() {}
```
''');
      expect(const MarkdownParser().canParse(bytes), isFalse);
      expect(registry.detect(bytes), DocumentFormat.unknown);

      final r = registry.parse(
        bytes,
        hints: const DocumentHints(filename: 'note.md'),
      );
      expect(r.format, DocumentFormat.markdown);
      expect(r.metadata['frontMatter'], contains('title: Test Note'));
      expect(r.metadata['codeBlockCount'], 1);
      expect(r.metadata['listItemCount'], 2);
      expect(r.outline.map((e) => e.title), ['Heading One', 'Section Two']);
      expect(r.tables, hasLength(1));
      expect(r.tables.single.rows, hasLength(2));
      expect(r.text, contains('Intro with bold text'));
      expect(r.text, contains('a link'));
      expect(r.structuredText, isNotNull);
    });

    test('warns on an unclosed code fence', () {
      final r = registry.parse(
        u8('# Title\n\n```dart\nvoid main() {}\n'),
        hints: const DocumentHints(filename: 'readme.markdown'),
      );
      expect(
        r.warnings.map((w) => w.code),
        contains('markdown.unclosed_fence'),
      );
    });
  });

  group('CSV / TSV', () {
    test('parses quoted fields with delimiters and embedded newlines', () {
      final bytes = u8(
        'name,note,amount\n'
        '"Smith, Jane","line1\nline2",10\n'
        '"O""Brien",plain,20\n',
      );
      expect(const CsvParser().canParse(bytes), isFalse);

      final r = registry.parse(
        bytes,
        hints: const DocumentHints(filename: 'people.csv'),
      );
      expect(r.format, DocumentFormat.csv);
      expect(r.metadata['delimiter'], ',');
      expect(r.metadata['columnCount'], 3);
      expect(r.metadata['rowCount'], 2);
      expect(r.tables.single.rows[1][0], 'Smith, Jane');
      expect(r.tables.single.rows[1][1], 'line1\nline2');
      expect(r.tables.single.rows[2][0], 'O"Brien');
      expect(r.text, contains('line1'));
    });

    test('honours a TSV hint and reports ragged rows', () {
      final r = registry.parse(
        u8('a\tb\n1\t2\t3\n'),
        hints: const DocumentHints(filename: 'data.tsv'),
      );
      expect(r.format, DocumentFormat.csv);
      expect(r.metadata['delimiter'], 'tab');
      expect(r.metadata['isTabSeparated'], true);
      expect(r.warnings.map((w) => w.code), contains('csv.ragged_rows'));
    });

    test('without a hint, delimited text is not claimed', () {
      final bytes = u8('a,b\n1,2\n');
      expect(const CsvParser().canParse(bytes), isFalse);
      expect(registry.detect(bytes), DocumentFormat.unknown);
    });
  });

  group('Image metadata', () {
    test('JPEG dimensions and colour model', () {
      final r = registry.parse(buildJpeg());
      expect(r.format, DocumentFormat.image);
      expect(r.metadata['formatFamily'], 'JPEG');
      expect(r.metadata['width'], 320);
      expect(r.metadata['height'], 240);
      expect(r.metadata['componentCount'], 3);
      expect(r.text, isNull);
    });

    test('PNG dimensions, colour type, and text chunk', () {
      final r = registry.parse(buildPng());
      expect(r.metadata['formatFamily'], 'PNG');
      expect(r.metadata['width'], 640);
      expect(r.metadata['height'], 480);
      expect(r.metadata['colorType'], 'RGB');
      expect((r.metadata['textChunks'] as Map)['Comment'], 'fixture');
    });

    test('SVG root is recognised and script/external refs are warnings', () {
      final r = registry.parse(
        u8('''<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80"
  viewBox="0 0 120 80">
  <title>Diagram</title>
  <script>alert(1)</script>
  <image href="https://example.com/pixel.png"/>
</svg>'''),
      );
      expect(r.metadata['formatFamily'], 'SVG');
      expect(r.metadata['width'], 120);
      expect(r.metadata['height'], 80);
      expect(r.metadata['title'], 'Diagram');
      expect(
        r.warnings.map((w) => w.code),
        containsAll(['image.svg_script', 'image.svg_external_resources']),
      );
    });

    test('HTML embedding an <svg> is not misdetected as an image', () {
      final bytes = u8(
        '<html><body><svg><title>inline</title></svg></body></html>',
      );
      expect(registry.detect(bytes), DocumentFormat.html);
    });
  });

  group('EPUB', () {
    test('detects, follows the spine, and extracts nav/metadata', () {
      final r = registry.parse(buildEpub());
      expect(r.format, DocumentFormat.epub);
      expect(r.metadata['title'], 'Test Book');
      expect(r.metadata['creator'], 'Jane Doe');
      expect(r.metadata['language'], 'en');
      expect(r.metadata['spineCount'], 1);
      expect(r.metadata['coverImage'], 'OEBPS/cover.png');
      expect(r.text, contains('Hello EPUB.'));
      expect(r.outline.first.title, 'Chapter One');
      expect(r.tables, hasLength(1));
      expect(r.attachments, hasLength(1));
      expect(r.attachments.single.mediaType, 'image/png');
      expect(r.attachments.single.digest, isNotNull);
    });
  });

  group('DICOM JSON', () {
    test('decodes tags, SR content, and InlineBinary attachments', () {
      final bytes = u8(buildDicomJson());
      expect(const DicomJsonParser().canParse(bytes), isTrue);

      final r = registry.parse(
        bytes,
        options: const ParseOptions(parseAttachments: true),
      );
      expect(r.format, DocumentFormat.dicom);
      expect(r.metadata['dicomJson'], true);
      expect(r.metadata['modality'], 'CT');
      expect(r.metadata['patientName'], 'DOE^JANE');
      expect(r.metadata['hasStructuredReport'], true);
      expect(r.text, contains('Nodule present'));
      expect(r.outline.map((e) => e.title), contains('Finding'));

      expect(r.attachments, hasLength(1));
      final attachment = r.attachments.single;
      expect(attachment.name, 'Encapsulated Doc');
      expect(attachment.mediaType, 'application/xml');
      expect(attachment.digest, isNotNull);
      final child = attachment.child;
      expect(child, isA<ParseResult>());
      expect((child! as ParseResult).format, DocumentFormat.cda);
      expect(attachment.text, contains('Encapsulated CDA'));
    });
  });

  group('CDA depth', () {
    test('extracts header roles, nested sections, tables, and media', () {
      final r = registry.parse(
        u8('''<?xml version="1.0"?>
<ClinicalDocument xmlns="urn:hl7-org:v3">
  <id root="2.16.840.1.113883.19.5" extension="DOC-1"/>
  <code code="34133-9" displayName="Summary of Episode Note"/>
  <title>Clinical Summary</title>
  <effectiveTime value="20260115"/>
  <confidentialityCode code="N" displayName="Normal"/>
  <languageCode value="en-US"/>
  <recordTarget>
    <patientRole>
      <id root="2.16.840.1.113883.19.5" extension="P-1"/>
      <patient>
        <name>Jane Doe</name>
        <administrativeGenderCode code="F"/>
        <birthTime value="19800101"/>
      </patient>
    </patientRole>
  </recordTarget>
  <author>
    <time value="20260115"/>
    <assignedAuthor><assignedPerson><name>Dr. Smith</name></assignedPerson></assignedAuthor>
  </author>
  <custodian>
    <assignedCustodian><representedCustodianOrganization><name>General Hospital</name></representedCustodianOrganization></assignedCustodian>
  </custodian>
  <documentationOf>
    <serviceEvent><code code="CONSULT" displayName="Consultation"/><effectiveTime value="20260114"/></serviceEvent>
  </documentationOf>
  <componentOf>
    <encompassingEncounter>
      <code code="AMB" displayName="Ambulatory"/>
      <effectiveTime value="20260114"/>
      <location><healthCareFacility><location><name>Clinic A</name></location></healthCareFacility></location>
    </encompassingEncounter>
  </componentOf>
  <component><structuredBody>
    <component><section>
      <title>History</title>
      <text>
        <paragraph>Patient reports pain.</paragraph>
        <table>
          <thead><tr><th>Date</th><th>Value</th></tr></thead>
          <tbody><tr><td>2026</td><td>5</td></tr></tbody>
        </table>
      </text>
      <component><section>
        <title>Subsection</title>
        <text>Nested narrative</text>
      </section></component>
      <entry>
        <observationMedia ID="img1">
          <value mediaType="image/png">aGVsbG8=</value>
        </observationMedia>
      </entry>
    </section></component>
  </structuredBody></component>
</ClinicalDocument>'''),
        options: const ParseOptions(includeAttachmentBytes: true),
      );
      expect(r.format, DocumentFormat.cda);
      expect(r.metadata['title'], 'Clinical Summary');
      expect(r.metadata['documentId'], '2.16.840.1.113883.19.5|DOC-1');
      expect(r.metadata['patientNames'], ['Jane Doe']);
      expect(r.metadata['patientGender'], 'F');
      expect(r.metadata['patientBirthTime'], '19800101');
      expect(r.metadata['authors'], hasLength(1));
      expect(r.metadata['custodian'], 'General Hospital');
      expect(r.metadata['serviceEvent'], 'Consultation');
      expect(r.metadata['encounterType'], 'Ambulatory');
      expect(r.metadata['encounterLocation'], 'Clinic A');
      expect(r.metadata['sectionCount'], 2);
      expect(
        r.outline.map((e) => e.title),
        containsAll(['History', 'Subsection']),
      );
      expect(r.text, contains('Nested narrative'));
      expect(r.text, contains('Patient reports pain.'));
      expect(r.tables, hasLength(1));
      expect(r.tables.single.rows, hasLength(2));
      expect(r.structuredText?.pages, hasLength(2));
      expect(r.attachments, hasLength(1));
      expect(r.attachments.single.bytes, [104, 101, 108, 108, 111]);
      expect(r.attachments.single.digest, isNotNull);
    });
  });

  group('ISO 20022 depth', () {
    test('extracts group header, parties, accounts, and transactions', () {
      final r = registry.parse(
        u8('''<?xml version="1.0"?>
<Document xmlns="urn:iso:std:iso:20022:tech:xsd:pain.001.001.09">
  <CstmrCdtTrfInitn>
    <GrpHdr>
      <MsgId>MSG-1</MsgId>
      <CreDtTm>2026-01-01T00:00:00</CreDtTm>
      <NbOfTxs>1</NbOfTxs>
      <CtrlSum>10.00</CtrlSum>
      <InitgPty><Nm>Initiator Ltd</Nm></InitgPty>
      <InstgAgt><FinInstnId><BICFI>BANKUS33</BICFI></FinInstnId></InstgAgt>
    </GrpHdr>
    <PmtInf>
      <PmtMtd>TRF</PmtMtd>
      <ReqdExctnDt>2026-01-02</ReqdExctnDt>
      <Dbtr><Nm>Alice</Nm></Dbtr>
      <DbtrAcct><Id><IBAN>DE89370400440532013000</IBAN></Id></DbtrAcct>
      <CdtTrfTxInf>
        <PmtId><EndToEndId>E2E-1</EndToEndId></PmtId>
        <Amt><InstdAmt Ccy="EUR">10.00</InstdAmt></Amt>
        <Cdtr><Nm>Bob</Nm></Cdtr>
        <CdtrAcct><Id><IBAN>FR1420041010050500013M02606</IBAN></Id></CdtrAcct>
        <RmtInf><Ustrd>Invoice 42</Ustrd></RmtInf>
      </CdtTrfTxInf>
    </PmtInf>
  </CstmrCdtTrfInitn>
</Document>'''),
      );
      expect(r.format, DocumentFormat.iso20022);
      expect(r.metadata['messageDefinition'], 'pain.001.001.09');
      expect(r.metadata['messageId'], 'MSG-1');
      expect(r.metadata['controlSum'], '10.00');
      expect(r.metadata['initiatingParty'], 'Initiator Ltd');
      expect(r.metadata['instructingAgentBic'], 'BANKUS33');
      expect(r.metadata['debtor'], 'Alice');
      expect(r.metadata['debtorAccount'], 'DE89370400440532013000');
      expect(r.metadata['creditor'], 'Bob');
      expect(r.metadata['creditorAccount'], 'FR1420041010050500013M02606');
      expect(r.metadata['settlementDate'], '2026-01-02');
      expect(r.metadata['transactionCount'], 1);
      expect((r.metadata['amountsByCurrency'] as Map)['EUR'], 10.0);
      expect(r.tables, hasLength(2));
      expect(r.tables.first.rows[1][0], 'cdttrftxinf');
      expect(r.text, contains('Alice'));
      expect(r.text, contains('Invoice 42'));
    });
  });
}
