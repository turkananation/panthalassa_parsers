import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_result.dart';
import 'xml_support.dart';

/// Generic structured-XML engine: the catch-all for any well-formed XML not
/// claimed by a more specific parser. Detects the NIEM XML profile (and
/// reclassifies as [DocumentFormat.niem]) via namespace / prefixed-element
/// hints, otherwise reports [DocumentFormat.xml]. Registered last among the XML
/// parsers so it never shadows FHIR, CDA, or ISO 20022.
final class XmlStructuredParser implements DocumentParser {
  const XmlStructuredParser();

  @override
  DocumentFormat get format => DocumentFormat.xml;

  @override
  bool canParse(Uint8List bytes) {
    final prefix = XmlSupport.peek(bytes, 2048);
    return prefix != null && XmlSupport.looksXml(prefix);
  }

  @override
  ParseResult parse(Uint8List bytes, {required ContentHasher hasher}) {
    final doc = XmlSupport.parse(bytes);
    final root = doc.rootElement;
    final prefix = XmlSupport.peek(bytes, 8192) ?? '';
    final isNiem = XmlSupport.niemHint.hasMatch(prefix);
    final namespace = root.getAttribute('xmlns');

    return ParseResult(
      documentId: hasher.idFor(bytes),
      format: isNiem ? DocumentFormat.niem : DocumentFormat.xml,
      byteLength: bytes.length,
      metadata: {
        if (isNiem) 'profile': 'NIEM XML',
        'rootElement': root.localName,
        'namespace': ?namespace,
        'elementCount': root.descendantElements.length + 1,
      },
      text: _orNull(XmlSupport.extractText(root)),
      warnings: const [],
    );
  }

  String? _orNull(String s) => s.isEmpty ? null : s;
}
