import 'dart:convert';
import 'dart:typed_data';

import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_exception.dart';
import '../core/parse_result.dart';

/// Parser for HL7 v2.x pipe-delimited messages (ADT, ORU, ORM, …).
///
/// The `MSH` segment is self-describing: the character immediately after `MSH`
/// is the field separator, and `MSH-2` carries the component/repetition/escape/
/// subcomponent characters. Those delimiters drive tokenization; the message
/// type, version, and control id are read from MSH, and all data values are
/// harvested (with separator escapes resolved) as text.
final class Hl7V2Parser implements DocumentParser {
  const Hl7V2Parser();

  @override
  DocumentFormat get format => DocumentFormat.hl7v2;

  @override
  bool canParse(Uint8List bytes) {
    if (bytes.length < 8) return false;
    if (bytes[0] != 0x4D || bytes[1] != 0x53 || bytes[2] != 0x48) return false; // MSH
    final sep = bytes[3];
    // Field separator must be a delimiter, not a letter/digit/space.
    return !_isAlnum(sep) && sep != 0x20;
  }

  @override
  ParseResult parse(Uint8List bytes, {required ContentHasher hasher}) {
    final source = utf8.decode(bytes, allowMalformed: true);
    final fieldSep = source[3];
    // MSH-2 encoding characters: component, repetition, escape, subcomponent.
    final enc = source.length >= 8 ? source.substring(4, 8) : '^~\\&';
    final componentSep = enc.isNotEmpty ? enc[0] : '^';
    final repetitionSep = enc.length > 1 ? enc[1] : '~';
    final escapeChar = enc.length > 2 ? enc[2] : '\\';
    final subSep = enc.length > 3 ? enc[3] : '&';

    final segments = source
        .split(RegExp(r'[\r\n]+'))
        .where((s) => s.trim().isNotEmpty)
        .toList();
    if (segments.isEmpty || !segments.first.startsWith('MSH')) {
      throw const MalformedDocumentException('no MSH segment in HL7 v2 message');
    }

    final mshFields = segments.first.split(fieldSep);
    String? msh(int n1) => n1 - 1 < mshFields.length ? mshFields[n1 - 1] : null;

    final segmentCounts = <String, int>{};
    final text = StringBuffer();
    for (final seg in segments) {
      final fields = seg.split(fieldSep);
      final id = fields.isNotEmpty ? fields.first : '';
      segmentCounts[id] = (segmentCounts[id] ?? 0) + 1;
      // Skip the segment id; harvest every component/subcomponent value.
      for (var i = 1; i < fields.length; i++) {
        for (final rep in fields[i].split(repetitionSep)) {
          for (final comp in rep.split(componentSep)) {
            for (final sub in comp.split(subSep)) {
              final v = _deescape(sub, escapeChar, fieldSep, componentSep,
                      subSep, repetitionSep)
                  .trim();
              if (v.isNotEmpty) text.writeln(v);
            }
          }
        }
      }
    }

    final body = text.toString().trimRight();
    return ParseResult(
      documentId: hasher.idFor(bytes),
      format: format,
      byteLength: bytes.length,
      metadata: {
        if (msh(9) != null && msh(9)!.isNotEmpty) 'messageType': msh(9),
        if (msh(10) != null && msh(10)!.isNotEmpty) 'controlId': msh(10),
        if (msh(12) != null && msh(12)!.isNotEmpty) 'version': msh(12),
        if (msh(3) != null && msh(3)!.isNotEmpty) 'sendingApplication': msh(3),
        if (msh(5) != null && msh(5)!.isNotEmpty) 'receivingApplication': msh(5),
        'segmentCount': segments.length,
        'segmentTypes': segmentCounts,
      },
      text: body.isEmpty ? null : body,
      warnings: const [],
    );
  }

  String _deescape(String s, String esc, String f, String c, String sub,
      String rep) {
    if (!s.contains(esc)) return s;
    final e = RegExp.escape(esc);
    final out = s
        .replaceAll('${esc}F$esc', f)
        .replaceAll('${esc}S$esc', c)
        .replaceAll('${esc}T$esc', sub)
        .replaceAll('${esc}R$esc', rep)
        .replaceAll('${esc}E$esc', esc);
    // Strip remaining formatting/hex/custom escapes (\H\, \N\, \Xdd\, \Zxx\).
    return out.replaceAll(RegExp('$e[A-Za-z][^$e]*$e'), '');
  }

  static bool _isAlnum(int b) =>
      (b >= 0x30 && b <= 0x39) ||
      (b >= 0x41 && b <= 0x5A) ||
      (b >= 0x61 && b <= 0x7A);
}
