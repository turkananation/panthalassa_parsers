import 'dart:typed_data';

import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_exception.dart';
import '../core/parse_result.dart';
import 'json_support.dart';

/// Generic structured-JSON engine: the catch-all for any well-formed JSON or
/// NDJSON not claimed by a more specific parser. Detects the NIEM JSON profile
/// (and reclassifies the result as [DocumentFormat.niem]) via its namespace
/// hints, otherwise reports [DocumentFormat.json]. Registered last among the
/// JSON parsers so it never shadows FHIR JSON or Verifiable Credentials.
final class JsonStructuredParser implements DocumentParser {
  const JsonStructuredParser();

  static final _niemPrefixedKey = RegExp(
    r'"(nc|j|em|hs|im|intel|scr|cbrn|mo|geo|ag):[A-Za-z]',
  );

  @override
  DocumentFormat get format => DocumentFormat.json;

  @override
  bool canParse(Uint8List bytes) {
    final prefix = JsonSupport.peek(bytes, 2048);
    return prefix != null && JsonSupport.looksJson(prefix);
  }

  @override
  ParseResult parse(Uint8List bytes, {required ContentHasher hasher}) {
    final List<Object?> records;
    final bool ndjson;
    try {
      (records, ndjson) = JsonSupport.decode(bytes);
    } on FormatException catch (e) {
      throw MalformedDocumentException('invalid JSON: ${e.message}');
    }

    final isNiem = _detectNiem(bytes, records);
    final text = StringBuffer();
    final topKeys = <String>{};
    for (final record in records) {
      if (record is Map) {
        for (final k in record.keys) {
          if (k is String) topKeys.add(k);
        }
      }
      JsonSupport.collectText(record, text);
    }
    final body = text.toString().trimRight();

    return ParseResult(
      documentId: hasher.idFor(bytes),
      format: isNiem ? DocumentFormat.niem : DocumentFormat.json,
      byteLength: bytes.length,
      metadata: {
        if (isNiem) 'profile': 'NIEM JSON',
        'rootType': records.length == 1 && records.first is List
            ? 'array'
            : 'object',
        if (topKeys.isNotEmpty && topKeys.length <= 64)
          'topLevelKeys': topKeys.toList(),
        if (ndjson) 'ndjson': true,
        if (ndjson) 'recordCount': records.length,
      },
      text: body.isEmpty ? null : body,
      warnings: const [],
    );
  }

  bool _detectNiem(Uint8List bytes, List<Object?> records) {
    final prefix = JsonSupport.peek(bytes, 8192) ?? '';
    if (prefix.contains('niem.gov') || prefix.contains('release.niem.gov')) {
      return true;
    }
    return _niemPrefixedKey.hasMatch(prefix);
  }
}
