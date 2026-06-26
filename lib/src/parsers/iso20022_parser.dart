import 'dart:typed_data';

import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_result.dart';
import 'xml_support.dart';

/// Parser for ISO 20022 financial messages (pain/pacs/camt/etc.) in their XML
/// serialization, recognised by the ISO 20022 namespace
/// (`urn:iso:std:iso:20022:tech:xsd:<message>`). The message definition
/// identifier is recovered from that namespace.
final class Iso20022Parser implements DocumentParser {
  const Iso20022Parser();

  static const _namespaceRoot = 'urn:iso:std:iso:20022';
  static final _messageId = RegExp(
    r'urn:iso:std:iso:20022:tech:xsd:([A-Za-z]+\.\d+\.\d+\.\d+)',
  );

  @override
  DocumentFormat get format => DocumentFormat.iso20022;

  @override
  bool canParse(Uint8List bytes) {
    final prefix = XmlSupport.peek(bytes, 4096);
    if (prefix == null || !XmlSupport.looksXml(prefix)) return false;
    return prefix.contains(_namespaceRoot);
  }

  @override
  ParseResult parse(Uint8List bytes, {required ContentHasher hasher}) {
    final doc = XmlSupport.parse(bytes);
    final root = doc.rootElement;
    final prefix = XmlSupport.peek(bytes, 4096) ?? '';
    final messageDefinition = _messageId.firstMatch(prefix)?.group(1);

    // The business message sits under the first child of <Document>.
    final businessArea = root.childElements.firstOrNull?.localName;

    return ParseResult(
      documentId: hasher.idFor(bytes),
      format: format,
      byteLength: bytes.length,
      metadata: {
        'rootElement': root.localName,
        'messageDefinition': ?messageDefinition,
        if (messageDefinition != null)
          'messageFamily': messageDefinition.split('.').first,
        'businessArea': ?businessArea,
      },
      text: _orNull(XmlSupport.extractText(root)),
      warnings: const [],
    );
  }

  String? _orNull(String s) => s.isEmpty ? null : s;
}
