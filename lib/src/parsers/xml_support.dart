import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../core/parse_exception.dart';

/// Shared helpers for XML-family parsers: tolerant decoding, cheap prefix
/// sniffing, and human-text harvesting (element text nodes plus the value-
/// bearing attributes used by FHIR (`value`) and CDA (`displayName`)).
class XmlSupport {
  static String? peek(Uint8List bytes, int max) {
    final slice =
        bytes.length <= max ? bytes : Uint8List.sublistView(bytes, 0, max);
    try {
      return utf8.decode(slice, allowMalformed: true);
    } on FormatException {
      return null;
    }
  }

  static bool looksXml(String prefix) {
    final t = prefix.trimLeft();
    return t.startsWith('<?xml') || t.startsWith('<');
  }

  /// Local name of the first element, skipping the XML declaration, comments,
  /// and processing instructions. `null` if none is found in the prefix.
  static String? firstElementName(String prefix) {
    var s = prefix.trimLeft();
    s = s.replaceFirst(RegExp(r'<\?xml.*?\?>', dotAll: true), '');
    s = s.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
    s = s.replaceAll(RegExp(r'<\?.*?\?>', dotAll: true), '');
    final match = RegExp(r'<\s*([A-Za-z_][\w.-]*)').firstMatch(s);
    final raw = match?.group(1);
    if (raw == null) return null;
    final colon = raw.indexOf(':');
    return colon == -1 ? raw : raw.substring(colon + 1);
  }

  static XmlDocument parse(Uint8List bytes) {
    final String source;
    try {
      source = utf8.decode(bytes);
    } on FormatException catch (e) {
      throw TextDecodingException('invalid UTF-8 in XML: ${e.message}');
    }
    try {
      return XmlDocument.parse(source);
    } on XmlException catch (e) {
      throw MalformedDocumentException('invalid XML: ${e.message}');
    }
  }

  static const _textAttributes = {'value', 'displayName'};

  /// Harvests human-readable text in document order: element text nodes, then
  /// value-bearing attributes. Deduplication is intentionally avoided so the
  /// content id reflects the document faithfully.
  static String extractText(XmlElement root) {
    final buffer = StringBuffer();
    for (final node in root.descendantElements) {
      for (final attr in _textAttributes) {
        final v = node.getAttribute(attr);
        if (v != null && v.trim().isNotEmpty) buffer.writeln(v.trim());
      }
      for (final child in node.children) {
        if (child is XmlText || child is XmlCDATA) {
          final t = child.value?.trim() ?? '';
          if (t.isNotEmpty) buffer.writeln(t);
        }
      }
    }
    return buffer.toString().trimRight();
  }

  /// True if the document carries NIEM namespaces or prefixed element names.
  static final RegExp niemHint = RegExp(
    r'niem\.gov|<(nc|j|em|hs|im|intel|scr|cbrn|mo|geo|ag):[A-Za-z]',
  );
}
