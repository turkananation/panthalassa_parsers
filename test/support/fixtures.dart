import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Test fixture builders that synthesise minimal-but-valid documents, so the
/// suite has no binary asset dependencies and every byte is auditable.

List<int> _le16(int v) => [v & 0xFF, (v >> 8) & 0xFF];

/// Builds a minimal DICOM Part 10 file: 128-byte preamble, `DICM`, an Explicit
/// VR LE File Meta group declaring the Explicit VR LE transfer syntax, and a
/// small dataset (Modality, PatientName).
Uint8List buildMinimalDicom() {
  final b = BytesBuilder();
  b.add(Uint8List(128)); // preamble
  b.add(ascii.encode('DICM'));

  List<int> elem(int group, int element, String vr, List<int> value) {
    assert(value.length.isEven, 'DICOM values must be even length');
    return [
      ..._le16(group),
      ..._le16(element),
      ...ascii.encode(vr),
      ..._le16(value.length),
      ...value,
    ];
  }

  List<int> ui(String s) {
    final bytes = ascii.encode(s).toList();
    if (bytes.length.isOdd) bytes.add(0x00);
    return bytes;
  }

  // File Meta Information (group 0002), Explicit VR LE.
  b.add(elem(0x0002, 0x0010, 'UI', ui('1.2.840.10008.1.2.1')));
  // Dataset, ascending tag order.
  b.add(elem(0x0008, 0x0060, 'CS', ascii.encode('CT'))); // Modality
  b.add(elem(0x0010, 0x0010, 'PN', ascii.encode('DOE^JANE'))); // PatientName
  return b.toBytes();
}

/// Builds a minimal ODF (ODT) container: an uncompressed `mimetype` member and
/// a `content.xml` carrying one paragraph.
Uint8List buildMinimalOdf({String paragraph = 'Hello Panthalassa'}) {
  final archive = Archive();

  final mime = ascii.encode('application/vnd.oasis.opendocument.text');
  final mimetype = ArchiveFile.noCompress('mimetype', mime.length, mime);
  archive.addFile(mimetype);

  final content = utf8.encode(
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<office:document-content '
    'xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
    'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">'
    '<office:body><office:text>'
    '<text:p>$paragraph</text:p>'
    '</office:text></office:body>'
    '</office:document-content>',
  );
  archive.addFile(ArchiveFile('content.xml', content.length, content));

  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// Builds a single-page PDF whose content stream shows [showText]. When
/// [compress] is true the content stream is zlib-compressed and tagged
/// `/FlateDecode`, exercising the inflate path.
Uint8List buildSimplePdf({
  String showText = 'Hello Panthalassa Vault',
  bool compress = false,
}) {
  final rawContent = ascii.encode('BT /F1 24 Tf 72 720 Td ($showText) Tj ET');
  final List<int> streamBytes;
  final String filterEntry;
  if (compress) {
    streamBytes = const ZLibEncoder().encode(rawContent);
    filterEntry = ' /Filter /FlateDecode';
  } else {
    streamBytes = rawContent;
    filterEntry = '';
  }

  final out = BytesBuilder();
  void put(String s) => out.add(latin1.encode(s));

  put('%PDF-1.7\n');
  put('1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');
  put('2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n');
  put(
    '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
    '/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>\nendobj\n',
  );
  put('4 0 obj\n<< /Length ${streamBytes.length}$filterEntry >>\nstream\n');
  out.add(streamBytes);
  put('\nendstream\nendobj\n');
  put(
    '5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n',
  );
  put('trailer\n<< /Root 1 0 R >>\n%%EOF');
  return out.toBytes();
}

List<int> _be32(int v) => [
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

/// Builds a minimal STANAG 4607 GMTI packet: 32-byte packet header (packet size
/// set to the actual length) followed by one Dwell segment.
Uint8List buildStanag4607Gmti() {
  final body = [0x00, 0x01, 0x02];
  final segment = <int>[
    2,
    ..._be32(5 + body.length),
    ...body,
  ]; // type 2 = Dwell
  final total = 32 + segment.length;

  final h = BytesBuilder();
  h.add(ascii.encode('30')); // version id (2)
  h.add(_be32(total)); // packet size (4)
  h.add(ascii.encode('US')); // nationality (2)
  h.addByte(5); // classification: UNCLASSIFIED (1)
  h.add(ascii.encode('US')); // classification system (2)
  h.add([0x00, 0x00]); // classification code/control (2)
  h.addByte(0); // exercise indicator (1)
  h.add(ascii.encode('PLATFORM01')); // platform id (10)
  h.add(_be32(7)); // mission id (4)
  h.add(_be32(42)); // job id (4)
  h.add(segment);
  return h.toBytes();
}

/// Builds a minimal MPEG-2 Transport Stream (STANAG 4609 essence container):
/// three 188-byte packets with valid sync bytes and PIDs; optionally embeds the
/// MISB KLV Universal Label so metadata presence is detected.
Uint8List buildMpegTsWithKlv({bool withKlv = true}) {
  final out = Uint8List(188 * 3);
  for (var p = 0; p < 3; p++) {
    final base = p * 188;
    out[base] = 0x47; // sync byte
    final pid = 0x100 + p;
    out[base + 1] = (pid >> 8) & 0x1F;
    out[base + 2] = pid & 0xFF;
    out[base + 3] = 0x10; // payload only, continuity counter 0
    for (var i = base + 4; i < base + 188; i++) {
      out[i] = 0xFF;
    }
  }
  if (withKlv) {
    final at = 188 * 2 + 4; // payload of the third packet
    out[at] = 0x06;
    out[at + 1] = 0x0E;
    out[at + 2] = 0x2B;
    out[at + 3] = 0x34;
  }
  return out;
}

/// Builds a PDF whose Catalog/Pages/Page/Font are packed into a FlateDecode'd
/// `/ObjStm`, with `/Root` carried only by a cross-reference stream (no
/// `trailer` keyword) — the PDF 1.5+ shape that a brute-force `obj` scan alone
/// cannot resolve. Exercises xref-stream `/Root` recovery + ObjStm expansion.
Uint8List buildObjStmPdf({String showText = 'Compressed Objects Work'}) {
  const o1 = '<< /Type /Catalog /Pages 2 0 R >>';
  const o2 = '<< /Type /Pages /Kids [3 0 R] /Count 1 >>';
  const o3 =
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
      '/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>';
  const o5 = '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>';

  final region = '$o1 $o2 $o3 $o5'; // single-space separated object data
  final off2 = o1.length + 1;
  final off3 = off2 + o2.length + 1;
  final off5 = off3 + o3.length + 1;
  final header = '1 0 2 $off2 3 $off3 5 $off5 ';
  final first = header.length;
  final objStmRaw = const ZLibEncoder().encode(ascii.encode(header + region));

  final content = ascii.encode('BT /F1 24 Tf 72 720 Td ($showText) Tj ET');

  final out = BytesBuilder();
  void put(String s) => out.add(latin1.encode(s));
  put('%PDF-1.5\n');
  put('4 0 obj\n<< /Length ${content.length} >>\nstream\n');
  out.add(content);
  put('\nendstream\nendobj\n');
  put(
    '6 0 obj\n<< /Type /ObjStm /N 4 /First $first '
    '/Length ${objStmRaw.length} /Filter /FlateDecode >>\nstream\n',
  );
  out.add(objStmRaw);
  put('\nendstream\nendobj\n');
  // Only the xref stream's dictionary is consulted (for /Root); body is empty.
  put(
    '7 0 obj\n<< /Type /XRef /Root 1 0 R /Size 8 /W [1 2 1] /Length 0 >>'
    '\nstream\n\nendstream\nendobj\n',
  );
  put('startxref\n0\n%%EOF');
  return out.toBytes();
}

/// PDF whose simple font uses WinAnsi base encoding plus a `/Differences` array,
/// with no `/ToUnicode` — exercises encoding-table + glyph-name resolution.
/// Content: octal-escaped high bytes ("Résumé") and Differences-mapped codes
/// (Euro, trademark).
Uint8List buildEncodedTextPdf() {
  final content = ascii.encode(
    r'BT /F1 24 Tf 72 720 Td (R\351sum\351) Tj 0 -30 Td <0102> Tj ET',
  );
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
    '5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
    '/Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding '
    '/Differences [ 1 /Euro 2 /trademark ] >> >>\nendobj\n',
  );
  put('trailer\n<< /Root 1 0 R >>\n%%EOF');
  return out.toBytes();
}

/// PDF with a Type0 (composite) font using Identity-H and a 2-byte `/ToUnicode`
/// CMap. Content shows two-byte codes that map to "Hi".
Uint8List buildType0Pdf() {
  final content = ascii.encode('BT /F1 24 Tf 72 720 Td <00010002> Tj ET');
  final cmap = ascii.encode(
    '/CIDInit /ProcSet findresource begin 12 dict begin begincmap\n'
    '1 begincodespacerange <0000> <FFFF> endcodespacerange\n'
    '2 beginbfchar <0001> <0048> <0002> <0069> endbfchar\n'
    'endcmap CMapName currentdict /CMap defineresource pop end end',
  );
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
    '5 0 obj\n<< /Type /Font /Subtype /Type0 /BaseFont /ABCDEF+Custom '
    '/Encoding /Identity-H /DescendantFonts [7 0 R] /ToUnicode 8 0 R >>\nendobj\n',
  );
  put(
    '7 0 obj\n<< /Type /Font /Subtype /CIDFontType2 /BaseFont /ABCDEF+Custom '
    '/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> >>\nendobj\n',
  );
  put('8 0 obj\n<< /Length ${cmap.length} >>\nstream\n');
  out.add(cmap);
  put('\nendstream\nendobj\n');
  put('trailer\n<< /Root 1 0 R >>\n%%EOF');
  return out.toBytes();
}

/// PDF whose page invokes a Form XObject (via `Do`) that itself shows text.
Uint8List buildFormXObjectPdf({String showText = 'XObject Text Here'}) {
  final pageContent = ascii.encode('q /Fm0 Do Q');
  final formContent = ascii.encode('BT /F1 24 Tf 0 20 Td ($showText) Tj ET');
  final out = BytesBuilder();
  void put(String s) => out.add(latin1.encode(s));
  put('%PDF-1.7\n');
  put('1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');
  put('2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n');
  put(
    '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
    '/Resources << /Font << /F1 5 0 R >> /XObject << /Fm0 6 0 R >> >> '
    '/Contents 4 0 R >>\nendobj\n',
  );
  put('4 0 obj\n<< /Length ${pageContent.length} >>\nstream\n');
  out.add(pageContent);
  put('\nendstream\nendobj\n');
  put(
    '5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n',
  );
  put(
    '6 0 obj\n<< /Type /XObject /Subtype /Form /BBox [0 0 200 50] '
    '/Resources << /Font << /F1 5 0 R >> >> /Length ${formContent.length} >>\nstream\n',
  );
  out.add(formContent);
  put('\nendstream\nendobj\n');
  put('trailer\n<< /Root 1 0 R >>\n%%EOF');
  return out.toBytes();
}

/// PDF whose page content places an inline image (BI/ID/EI) between two text
/// runs. The image data deliberately contains bytes that would corrupt the
/// tokenizer (an unbalanced `(` and a `BT`) if the image were not skipped.
Uint8List buildInlineImagePdf() {
  final out = BytesBuilder();
  void put(String s) => out.add(latin1.encode(s));
  final pre = ascii.encode(
    'BT /F1 24 Tf 72 720 Td (Before Image) Tj ET\n'
    'q 100 0 0 100 72 600 cm BI /W 2 /H 2 /CS /RGB /BPC 8 ID ',
  );
  // 12 bytes of "image data" including '(' (0x28) and 'BT' to bait the parser.
  final imageData = <int>[
    0x28,
    0x29,
    0x20,
    0x42,
    0x54,
    0x20,
    0x28,
    0x78,
    0x29,
    0x20,
    0x20,
    0x20,
  ];
  final post = ascii.encode(
    '\nEI Q\nBT /F1 24 Tf 72 500 Td (After Image) Tj ET',
  );
  final content = <int>[...pre, ...imageData, ...post];

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

/// PDF/A-3-style document carrying an associated embedded XML file (the
/// ZUGFeRD/Factur-X hybrid-invoice pattern): page text plus an `/AF` filespec
/// whose `/EF` stream is the invoice XML.
Uint8List buildPdfA3WithEmbeddedXml({
  String pageText = 'Invoice 2026-001',
  String seller = 'Esambo Interserve Ltd',
}) {
  final content = ascii.encode('BT /F1 18 Tf 72 720 Td ($pageText) Tj ET');
  final xml = ascii.encode(
    '<?xml version="1.0"?><rsm:CrossIndustryInvoice>'
    '<Seller>$seller</Seller><GrandTotal>1500.00</GrandTotal>'
    '</rsm:CrossIndustryInvoice>',
  );
  final out = BytesBuilder();
  void put(String s) => out.add(latin1.encode(s));
  put('%PDF-1.7\n');
  put(
    '1 0 obj\n<< /Type /Catalog /Pages 2 0 R '
    '/Names << /EmbeddedFiles << /Names [ (factur-x.xml) 7 0 R ] >> >> '
    '/AF [ 7 0 R ] >>\nendobj\n',
  );
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
  put(
    '7 0 obj\n<< /Type /Filespec /F (factur-x.xml) /UF (factur-x.xml) '
    '/AFRelationship /Alternative /EF << /F 8 0 R >> >>\nendobj\n',
  );
  put(
    '8 0 obj\n<< /Type /EmbeddedFile /Subtype /text#2Fxml '
    '/Params << /Size ${xml.length} >> /Length ${xml.length} >>\nstream\n',
  );
  out.add(xml);
  put('\nendstream\nendobj\n');
  put('trailer\n<< /Root 1 0 R >>\n%%EOF');
  return out.toBytes();
}
