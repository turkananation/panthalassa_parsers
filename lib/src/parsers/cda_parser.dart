import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_result.dart';
import 'xml_support.dart';

/// Parser for HL7 v3 CDA (Clinical Document Architecture) R2 documents,
/// recognised by the `ClinicalDocument` root in the HL7 v3 namespace
/// (`urn:hl7-org:v3`).
final class CdaParser implements DocumentParser {
  const CdaParser();

  static const _v3Namespace = 'urn:hl7-org:v3';

  @override
  DocumentFormat get format => DocumentFormat.cda;

  @override
  bool canParse(Uint8List bytes) {
    final prefix = XmlSupport.peek(bytes, 4096);
    if (prefix == null || !XmlSupport.looksXml(prefix)) return false;
    if (XmlSupport.firstElementName(prefix) != 'ClinicalDocument') return false;
    return prefix.contains(_v3Namespace);
  }

  @override
  ParseResult parse(Uint8List bytes, {required ContentHasher hasher}) {
    final doc = XmlSupport.parse(bytes);
    final root = doc.rootElement;

    final title = root.findElements('title').firstOrNull?.innerText.trim();
    final effectiveTime = root
        .findElements('effectiveTime')
        .firstOrNull
        ?.getAttribute('value');
    final code = root.findElements('code').firstOrNull;
    final templateIds = root
        .findElements('templateId')
        .map((e) => e.getAttribute('root'))
        .whereType<String>()
        .toList();

    return ParseResult(
      documentId: hasher.idFor(bytes),
      format: format,
      byteLength: bytes.length,
      metadata: {
        if (title != null && title.isNotEmpty) 'title': title,
        if (code?.getAttribute('code') != null)
          'documentTypeCode': code!.getAttribute('code'),
        if (code?.getAttribute('displayName') != null)
          'documentType': code!.getAttribute('displayName'),
        if (effectiveTime != null) 'effectiveTime': effectiveTime,
        if (templateIds.isNotEmpty) 'templateIds': templateIds,
        'sectionCount': root.findAllElements('section').length,
      },
      text: _orNull(XmlSupport.extractText(root)),
      warnings: const [],
    );
  }

  String? _orNull(String s) => s.isEmpty ? null : s;
}
