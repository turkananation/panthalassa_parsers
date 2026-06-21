import 'dart:convert';
import 'dart:typed_data';

import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_exception.dart';
import '../core/parse_result.dart';

/// Parser for ANSI ASC X12 EDI interchanges (837 claims, 850 purchase orders,
/// 810 invoices, …).
///
/// The 106-character `ISA` header is positional and self-describing: the element
/// separator is the 4th byte, the component separator is byte 104, and the
/// segment terminator is byte 105. Envelope identifiers come from ISA/GS/ST;
/// every element value is harvested as text.
final class X12Parser implements DocumentParser {
  const X12Parser();

  static const _isaLength = 106;

  @override
  DocumentFormat get format => DocumentFormat.x12;

  @override
  bool canParse(Uint8List bytes) {
    if (bytes.length < _isaLength) return false;
    if (bytes[0] != 0x49 || bytes[1] != 0x53 || bytes[2] != 0x41) return false; // ISA
    final sep = bytes[3];
    return !_isAlnum(sep) && sep != 0x20;
  }

  @override
  ParseResult parse(Uint8List bytes, {required ContentHasher hasher}) {
    final source = utf8.decode(bytes, allowMalformed: true);
    if (source.length < _isaLength) {
      throw const MalformedDocumentException('X12 ISA header is truncated');
    }
    final elementSep = source[3];
    final componentSep = source[104];
    final segTerm = source[105];

    final segments = source
        .split(segTerm)
        .map((s) => s.replaceAll(RegExp(r'^[\r\n]+'), '').trim())
        .where((s) => s.isNotEmpty)
        .toList();

    final isa = segments.first.split(elementSep);
    String? isaEl(int n) => n < isa.length ? isa[n].trim() : null;

    final functionalGroups = <String>[];
    final transactionSets = <String, int>{};
    final segmentCounts = <String, int>{};
    final text = StringBuffer();

    const controlSegments = {'ISA', 'GS', 'ST', 'SE', 'GE', 'IEA', 'TA1'};
    for (final seg in segments) {
      final elements = seg.split(elementSep);
      final id = elements.isNotEmpty ? elements.first : '';
      segmentCounts[id] = (segmentCounts[id] ?? 0) + 1;
      if (id == 'GS' && elements.length > 1) {
        functionalGroups.add(elements[1]);
      } else if (id == 'ST' && elements.length > 1) {
        transactionSets[elements[1]] = (transactionSets[elements[1]] ?? 0) + 1;
      }
      // Envelope/control segments are routing metadata, not document text.
      if (controlSegments.contains(id)) continue;
      for (var i = 1; i < elements.length; i++) {
        for (final comp in elements[i].split(componentSep)) {
          final v = comp.trim();
          if (v.isNotEmpty) text.writeln(v);
        }
      }
    }

    final body = text.toString().trimRight();
    return ParseResult(
      documentId: hasher.idFor(bytes),
      format: format,
      byteLength: bytes.length,
      metadata: {
        if (isaEl(12) != null) 'x12Version': isaEl(12),
        if (isaEl(13) != null) 'interchangeControlNumber': isaEl(13),
        if (isaEl(6) != null) 'senderId': isaEl(6),
        if (isaEl(8) != null) 'receiverId': isaEl(8),
        if (functionalGroups.isNotEmpty) 'functionalGroups': functionalGroups,
        if (transactionSets.isNotEmpty) 'transactionSets': transactionSets,
        'segmentCount': segments.length,
        'segmentTypes': segmentCounts,
      },
      text: body.isEmpty ? null : body,
      warnings: const [],
    );
  }

  static bool _isAlnum(int b) =>
      (b >= 0x30 && b <= 0x39) ||
      (b >= 0x41 && b <= 0x5A) ||
      (b >= 0x61 && b <= 0x7A);
}
