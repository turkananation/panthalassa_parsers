import 'dart:typed_data';

import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_exception.dart';
import '../core/parse_result.dart';
import 'json_support.dart';

/// Parser for HL7 FHIR JSON resources (R4/R5), including NDJSON bulk-export
/// streams (one resource per line). Recognised by the mandatory top-level
/// `resourceType` member, so it does not shadow arbitrary JSON.
final class FhirJsonParser implements DocumentParser {
  const FhirJsonParser();

  @override
  DocumentFormat get format => DocumentFormat.fhirJson;

  @override
  bool canParse(Uint8List bytes) {
    final prefix = JsonSupport.peek(bytes, 4096);
    if (prefix == null || !JsonSupport.looksJson(prefix)) return false;
    return prefix.contains('"resourceType"');
  }

  @override
  ParseResult parse(Uint8List bytes, {required ContentHasher hasher}) {
    final List<Object?> records;
    final bool ndjson;
    try {
      (records, ndjson) = JsonSupport.decode(bytes);
    } on FormatException catch (e) {
      throw MalformedDocumentException('invalid FHIR JSON: ${e.message}');
    }

    final resourceTypes = <String, int>{};
    var entryCount = 0;
    String? firstId;
    String? firstProfile;
    final text = StringBuffer();

    for (final record in records) {
      if (record is! Map) {
        throw const MalformedDocumentException(
          'FHIR JSON record is not an object',
        );
      }
      final rt = record['resourceType'];
      if (rt is String) resourceTypes[rt] = (resourceTypes[rt] ?? 0) + 1;
      firstId ??= record['id'] is String ? record['id'] as String : null;
      final meta = record['meta'];
      if (firstProfile == null && meta is Map && meta['profile'] is List) {
        final profiles = meta['profile'] as List;
        if (profiles.isNotEmpty && profiles.first is String) {
          firstProfile = profiles.first as String;
        }
      }
      final entries = record['entry'];
      if (entries is List) entryCount += entries.length;
      JsonSupport.collectText(record, text);
    }

    final warnings = <ParseWarning>[];
    if (resourceTypes.isEmpty) {
      warnings.add(
        const ParseWarning(
          'fhir.no_resource_type',
          'no resourceType found; classification is heuristic',
        ),
      );
    }

    final body = text.toString().trimRight();
    return ParseResult(
      documentId: hasher.idFor(bytes),
      format: format,
      byteLength: bytes.length,
      metadata: {
        if (records.length == 1 && resourceTypes.length == 1)
          'resourceType': resourceTypes.keys.first
        else
          'resourceTypes': resourceTypes,
        'id': ?firstId,
        'profile': ?firstProfile,
        if (entryCount > 0) 'entryCount': entryCount,
        if (ndjson) 'ndjson': true,
        if (ndjson) 'recordCount': records.length,
      },
      text: body.isEmpty ? null : body,
      warnings: warnings,
    );
  }
}
