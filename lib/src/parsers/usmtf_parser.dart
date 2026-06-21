import 'dart:convert';
import 'dart:typed_data';

import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_exception.dart';
import '../core/parse_result.dart';

/// Parser for United States Message Text Format (USMTF / MIL-STD-6040) messages.
///
/// A USMTF message is a sequence of *sets*, each terminated by `//` and composed
/// of `/`-separated fields, the first of which is the set identifier (e.g.
/// `MSGID`, `EXER`). Detection is deliberately stricter than "contains `/` and
/// `//`": it requires several set-terminated lines, so that arbitrary text
/// containing slashes (URLs, dates, file paths) is not misclassified.
final class UsmtfParser implements DocumentParser {
  const UsmtfParser();

  static final _setLine = RegExp(
    r'^[A-Z][A-Z0-9]{1,9}/.*//\s*$',
    multiLine: true,
  );
  static const _commonSetIds = {
    'MSGID',
    'EXER',
    'REF',
    'AMPN',
    'NARR',
    'GENTEXT',
    'SITREP',
    'UNITLOCS',
    'PERSTAT',
    'TASKORG',
    'COORD',
    'AKNLDG',
  };
  static const _minSetLines = 2;

  @override
  DocumentFormat get format => DocumentFormat.usmtf;

  @override
  bool canParse(Uint8List bytes) {
    final text = _peek(bytes, 4096);
    if (text == null) return false;
    final matches = _setLine.allMatches(text);
    if (matches.length < _minSetLines) return false;
    // Require at least one recognised set identifier to suppress false positives
    // from unrelated `AAA/.../bbb//`-shaped content.
    return matches.any((m) {
      final id = m.group(0)!.split('/').first;
      return _commonSetIds.contains(id) || matches.length >= 4;
    });
  }

  @override
  ParseResult parse(Uint8List bytes, {required ContentHasher hasher}) {
    final String source;
    try {
      source = ascii.decode(bytes, allowInvalid: true);
    } on FormatException catch (e) {
      throw TextDecodingException('cannot decode USMTF: ${e.message}');
    }

    // Sets may span lines but always end at `//`. Normalise then split.
    final normalised = source.replaceAll('\r\n', '\n');
    final rawSets = normalised
        .split(RegExp(r'//\s*'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    if (rawSets.isEmpty) {
      throw const MalformedDocumentException('no USMTF sets found');
    }

    final sets = <Map<String, Object?>>[];
    String? messageId;
    String? messageType;
    for (final raw in rawSets) {
      final fields = raw.split('/').map((f) => f.trim()).toList();
      if (fields.isEmpty || fields.first.isEmpty) continue;
      final setId = fields.first;
      sets.add({'setId': setId, 'fields': fields.skip(1).toList()});
      if (setId == 'MSGID') {
        messageType = fields.length > 1 ? fields[1] : null;
        messageId = fields.length > 2 ? fields[2] : null;
      }
    }

    return ParseResult(
      documentId: hasher.idFor(bytes),
      format: format,
      byteLength: bytes.length,
      metadata: {
        'setCount': sets.length,
        if (messageType != null) 'messageType': messageType,
        if (messageId != null) 'originator': messageId,
        'setIds': sets.map((s) => s['setId']).toList(),
      },
      text: sets
          .map((s) => '${s['setId']}: ${(s['fields'] as List).join(' / ')}')
          .join('\n'),
    );
  }

  String? _peek(Uint8List bytes, int max) {
    final slice = bytes.length <= max
        ? bytes
        : Uint8List.sublistView(bytes, 0, max);
    return ascii.decode(slice, allowInvalid: true);
  }
}
