import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Test fixture builders that synthesise minimal-but-valid documents, so the
/// suite has no binary asset dependencies and every byte is auditable.

List<int> _le16(int v) => [v & 0xFF, (v >> 8) & 0xFF];
List<int> _le32(int v) => [
  v & 0xFF,
  (v >> 8) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 24) & 0xFF,
];

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

/// Builds a DICOM Part 10 file with a multi-valued string and an
/// undefined-length sequence containing one undefined-length item.
Uint8List buildDicomWithSequenceAndMultiValues() {
  final b = BytesBuilder();
  b.add(Uint8List(128));
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

  void tag(int group, int element) {
    b.add(_le16(group));
    b.add(_le16(element));
  }

  b.add(elem(0x0002, 0x0010, 'UI', ui('1.2.840.10008.1.2.1')));
  b.add(elem(0x0008, 0x0008, 'CS', ascii.encode(r'ORIGINAL\PRIMARY')));
  b.add(elem(0x0008, 0x0060, 'CS', ascii.encode('MR')));

  // (0008,1115) Referenced Series Sequence, undefined length.
  tag(0x0008, 0x1115);
  b.add(ascii.encode('SQ'));
  b.add([0x00, 0x00]);
  b.add(_le32(0xFFFFFFFF));
  // Item, undefined length.
  tag(0xFFFE, 0xE000);
  b.add(_le32(0xFFFFFFFF));
  b.add(elem(0x0020, 0x000D, 'UI', ui('1.2.3.4.5')));
  // Item delimitation.
  tag(0xFFFE, 0xE00D);
  b.add(_le32(0));
  // Sequence delimitation.
  tag(0xFFFE, 0xE0DD);
  b.add(_le32(0));

  return b.toBytes();
}

/// Builds a minimal NITF 2.1 file with image, graphic, text, DES, and RES
/// segments so segment-table and body walking can be tested without assets.
Uint8List buildNitfWithSegments() {
  void putFixed(List<int> target, int offset, int length, String value) {
    final bytes = ascii.encode(value);
    for (var i = 0; i < length; i++) {
      target[offset + i] = i < bytes.length ? bytes[i] : 0x20;
    }
  }

  List<int> fixed(int length, String value) {
    final out = List<int>.filled(length, 0x20);
    putFixed(out, 0, length, value);
    return out;
  }

  List<int> digits(int width, int value) =>
      ascii.encode(value.toString().padLeft(width, '0'));

  final imageSub = List<int>.filled(183, 0x20);
  putFixed(imageSub, 0, 2, 'IM');
  putFixed(imageSub, 2, 10, 'IMG0000001');
  putFixed(imageSub, 12, 14, '20260621153000');
  putFixed(imageSub, 26, 17, 'TARGET-000000001');
  putFixed(imageSub, 43, 80, 'Recon image tile');
  putFixed(imageSub, 123, 1, 'U');
  putFixed(imageSub, 167, 8, '00000128');
  putFixed(imageSub, 175, 8, '00000256');
  final imageData = List<int>.filled(12, 0x7F);

  final graphicSub = <int>[
    ...fixed(2, 'SY'),
    ...fixed(10, 'GRAPHIC01'),
    ...fixed(20, 'Overlay'),
    ...fixed(1, 'U'),
    ...fixed(7, ''),
  ];
  final graphicData = ascii.encode('VECTOR');

  final textSub = <int>[
    ...fixed(2, 'TE'),
    ...fixed(7, 'TXT0001'),
    ...fixed(14, '20260621153100'),
    ...fixed(80, 'Mission notes'),
    ...fixed(1, 'U'),
    ...fixed(2, ''),
    ...fixed(3, 'TXT'),
    ...fixed(1, ''),
  ];
  final textData = utf8.encode('NITF mission note');

  final desSub = <int>[
    ...fixed(2, 'DE'),
    ...fixed(25, 'XML_DATA_CONTENT'),
    ...fixed(2, '01'),
    ...fixed(1, 'U'),
    ...fixed(10, ''),
  ];
  final desData = utf8.encode('<metadata/>');

  final resSub = <int>[
    ...fixed(2, 'RE'),
    ...fixed(25, 'RESERVED_EXTENSION'),
    ...fixed(1, 'U'),
    ...fixed(4, ''),
  ];
  final resData = ascii.encode('RESERVE');

  final header = List<int>.filled(363, 0x20);
  putFixed(header, 0, 4, 'NITF');
  putFixed(header, 4, 5, '02.10');
  putFixed(header, 9, 2, '03');
  putFixed(header, 15, 10, 'PNTH');
  putFixed(header, 25, 14, '20260621152900');
  putFixed(header, 39, 80, 'Panthalassa NITF sample');
  putFixed(header, 119, 1, 'U');
  putFixed(header, 360, 3, '001');

  final tables = <int>[
    ...digits(6, imageSub.length),
    ...digits(10, imageData.length),
    ...digits(3, 1),
    ...digits(6, graphicSub.length),
    ...digits(10, graphicData.length),
    ...digits(3, 0), // NUMX
    ...digits(3, 1),
    ...digits(4, textSub.length),
    ...digits(5, textData.length),
    ...digits(3, 1),
    ...digits(4, desSub.length),
    ...digits(9, desData.length),
    ...digits(3, 1),
    ...digits(4, resSub.length),
    ...digits(7, resData.length),
  ];
  final headerLength = header.length + tables.length;
  final fileLength =
      headerLength +
      imageSub.length +
      imageData.length +
      graphicSub.length +
      graphicData.length +
      textSub.length +
      textData.length +
      desSub.length +
      desData.length +
      resSub.length +
      resData.length;
  putFixed(header, 342, 12, fileLength.toString().padLeft(12, '0'));
  putFixed(header, 354, 6, headerLength.toString().padLeft(6, '0'));

  final out = BytesBuilder()
    ..add(header)
    ..add(tables)
    ..add(imageSub)
    ..add(imageData)
    ..add(graphicSub)
    ..add(graphicData)
    ..add(textSub)
    ..add(textData)
    ..add(desSub)
    ..add(desData)
    ..add(resSub)
    ..add(resData);
  return out.toBytes();
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

/// PDF with a filled rectangle plus text for visual display-list extraction.
Uint8List buildVisualShapePdf() {
  final content = ascii.encode(
    '0.2 0.4 0.6 rg 120 640 80 30 re f '
    'BT /F1 18 Tf 72 600 Td (Shape Page) Tj ET',
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
    '5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n',
  );
  put('trailer\n<< /Root 1 0 R >>\n%%EOF');
  return out.toBytes();
}

/// PDF whose MediaBox is inherited from the `/Pages` node.
Uint8List buildInheritedPageBoxPdf() {
  final content = ascii.encode('BT /F1 12 Tf 10 20 Td (Inherited Box) Tj ET');
  final out = BytesBuilder();
  void put(String s) => out.add(latin1.encode(s));

  put('%PDF-1.7\n');
  put('1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');
  put(
    '2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 '
    '/MediaBox [0 0 300 200] >>\nendobj\n',
  );
  put(
    '3 0 obj\n<< /Type /Page /Parent 2 0 R '
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

List<int> _be32(int v) => [
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

List<int> _be16(int v) => [((v >> 8) & 0xFF), v & 0xFF];

int _scaledLat(double value) => (value / 90 * 2147483647).round();
int _scaledLon(double value) => (value / 180 * 2147483647).round();

/// Builds a minimal STANAG 4607 GMTI packet: 32-byte packet header (packet size
/// set to the actual length) followed by one Dwell segment with one target
/// report body.
Uint8List buildStanag4607Gmti() {
  final body = <int>[
    ..._be32(0x00000000),
    ..._be32(0x0000001F), // existence mask
    ..._be16(3), // revisit index
    ..._be16(9), // dwell index
    1, // last dwell
    ..._be16(1), // target report count
    ..._be32(_scaledLat(1.25)), // sensor lat
    ..._be32(_scaledLon(36.75)), // sensor lon
    ..._be32(1700), // sensor altitude
    ..._be16(44), // target report index
    ..._be32(_scaledLat(1.3)), // target lat
    ..._be32(_scaledLon(36.8)), // target lon
    ..._be32(1710), // target height
    ..._be16(1234), // range rate cm/s
    ..._be16(-250), // cross-range rate cm/s
  ];
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
/// MISB ST 0601 Universal Label and local-set metadata.
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
    final localSet = <int>[
      5,
      2,
      ..._be16((91 / 360 * 65535).round()), // platform heading
      13,
      4,
      ..._be32(_scaledLat(1.25)), // sensor latitude
      14,
      4,
      ..._be32(_scaledLon(36.75)), // sensor longitude
      23,
      4,
      ..._be32(_scaledLat(1.3)), // frame center latitude
      24,
      4,
      ..._be32(_scaledLon(36.8)), // frame center longitude
      65,
      1,
      17,
    ];
    final klv = <int>[
      0x06,
      0x0E,
      0x2B,
      0x34,
      0x02,
      0x0B,
      0x01,
      0x01,
      0x0E,
      0x01,
      0x03,
      0x01,
      0x01,
      0x00,
      0x00,
      0x00,
      localSet.length,
      ...localSet,
    ];
    out.setRange(at, at + klv.length, klv);
  }
  return out;
}

/// Builds a strict NPIF-framed STANAG 7023 fixture with two segment-index
/// entries.
Uint8List buildStanag7023Npif() {
  final b = BytesBuilder()
    ..add(ascii.encode('NPIF'))
    ..add(ascii.encode('0001'))
    ..add(_be32(36))
    ..add(_be16(2))
    ..addByte(5)
    ..addByte(0)
    ..add(ascii.encode('IM'))
    ..add(_be32(48))
    ..add(_be32(1024))
    ..add(ascii.encode('TX'))
    ..add(_be32(24))
    ..add(_be32(128));
  return b.toBytes();
}

/// Builds a conservative `L16J` framed STANAG 5516 fixture with two fixed-size
/// packed J-series words.
Uint8List buildStanag5516Link16() {
  final b = BytesBuilder()
    ..add(ascii.encode('L16J'))
    ..addByte(1)
    ..addByte(10)
    ..add(_be16(2))
    ..add([0x58, 0x01, 0x02, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xF0, 0x11])
    ..add([0x69, 0x03, 0x04, 0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD]);
  return b.toBytes();
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
  String seller = 'Turkana Nation',
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
