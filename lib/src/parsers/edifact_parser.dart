import 'dart:convert';
import 'dart:typed_data';

import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_exception.dart';
import '../core/parse_result.dart';

/// Parser for UN/EDIFACT interchanges (ISO 9735).
///
/// Honours the optional `UNA` service string advice to discover the component,
/// element, decimal, release, and segment-terminator characters; falls back to
/// the ISO defaults (`:` `+` `.` `?` `'`) when `UNA` is absent. Segments are
/// split on the terminator while respecting the release (escape) character.
final class EdifactParser implements DocumentParser {
  const EdifactParser();

  static const int _unaLength = 9;

  @override
  DocumentFormat get format => DocumentFormat.edifact;

  @override
  bool canParse(Uint8List bytes) {
    final p = _peek(bytes, 64);
    if (p == null) return false;
    final t = p.trimLeft();
    return t.startsWith('UNA') || t.startsWith('UNB');
  }

  @override
  ParseResult parse(Uint8List bytes, {required ContentHasher hasher}) {
    final digest = hasher.digestFor(bytes);

    // EDIFACT may be UTF-8 or Latin-1. Detect a BOM / high-bit bytes and decode
    // accordingly; never silently substitute replacement characters.
    String source;
    bool nonAscii = false;
    try {
      source = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      // Latin-1 path: every byte maps to a code point; scan for non-ASCII.
      source = latin1.decode(bytes, allowInvalid: true);
      for (final b in bytes) {
        if (b > 0x7F) nonAscii = true;
      }
    } catch (_) {
      throw const TextDecodingException('cannot decode EDIFACT');
    }

    final delims = _Delimiters.fromSource(source);
    // `UNA` may be preceded by leading whitespace; locate it at the start of
    // the (trimmed) stream rather than assuming offset zero.
    final startOfBody = delims.unaConsumed ? _unaLength : 0;
    final body = source.substring(startOfBody);
    final segments = _splitSegments(body, delims);
    if (segments.isEmpty) {
      throw const MalformedDocumentException('no EDIFACT segments found');
    }

    final warnings = <ParseWarning>[];
    if (nonAscii) {
      warnings.add(
        const ParseWarning(
          'edifact.non_ascii',
          'non-ASCII bytes decoded as Latin-1; confirm the syntax encoding',
        ),
      );
    }

    final unb = segments.firstWhere(
      (s) => s.tag == 'UNB',
      orElse: () => const _Segment('UNB', []),
    );
    if (unb.elements.isEmpty) {
      warnings.add(
        const ParseWarning(
          'edifact.missing_unb',
          'interchange header (UNB) not found',
        ),
      );
    }

    final messageTypes = segments
        .where((s) => s.tag == 'UNH')
        .map(
          (s) =>
              s.elements.length > 1 ? s.elements[1].join(delims.component) : '',
        )
        .where((s) => s.isNotEmpty)
        .toList();

    return ParseResult(
      documentId: digest.sha256,
      digest: digest,
      format: format,
      byteLength: bytes.length,
      metadata: {
        'segmentCount': segments.length,
        'syntaxIdentifier': unb.at(0, 0),
        'sender': unb.at(1, 0),
        'recipient': unb.at(2, 0),
        'interchangeRef': unb.at(4, 0),
        'messageTypes': messageTypes,
        if (nonAscii) 'nonAscii': true,
        if (delims.unaConsumed) 'serviceStringAdvice': true,
      },
      text: segments
          .map(
            (s) =>
                '${s.tag}: ${s.elements.map((e) => e.join('/')).join(' | ')}',
          )
          .join('\n'),
      warnings: warnings,
    );
  }

  List<_Segment> _splitSegments(String body, _Delimiters d) {
    final segments = <_Segment>[];
    for (final segText in _split(body, d.segment, d.release)) {
      final trimmed = segText.trim();
      if (trimmed.isEmpty) continue;
      final elements = _split(trimmed, d.element, d.release)
          .map(
            (e) => _split(
              e,
              d.component,
              d.release,
            ).map((c) => _unescape(c, d.release)).toList(),
          )
          .toList();
      final tag = elements.isNotEmpty && elements.first.isNotEmpty
          ? elements.first.first
          : '';
      segments.add(_Segment(tag, elements.skip(1).toList()));
    }
    return segments;
  }

  /// Splits [input] on [sep] while treating a [release]-prefixed character as a
  /// literal pair. The release sequence is *preserved* in the output (not yet
  /// unescaped), so the same data can be split again at a finer level.
  List<String> _split(String input, String sep, String release) {
    final out = <String>[];
    final current = StringBuffer();
    var i = 0;
    while (i < input.length) {
      final ch = input[i];
      if (ch == release && i + 1 < input.length) {
        current
          ..write(ch)
          ..write(input[i + 1]);
        i += 2;
        continue;
      }
      if (ch == sep) {
        out.add(current.toString());
        current.clear();
        i++;
        continue;
      }
      current.write(ch);
      i++;
    }
    out.add(current.toString());
    return out;
  }

  /// Resolves release sequences in a leaf value: drops each release character,
  /// keeping the character that follows it literal.
  String _unescape(String value, String release) {
    if (!value.contains(release)) return value;
    final b = StringBuffer();
    var i = 0;
    while (i < value.length) {
      if (value[i] == release && i + 1 < value.length) {
        b.write(value[i + 1]);
        i += 2;
      } else {
        b.write(value[i]);
        i++;
      }
    }
    return b.toString();
  }

  String? _peek(Uint8List bytes, int max) {
    final slice = bytes.length <= max
        ? bytes
        : Uint8List.sublistView(bytes, 0, max);
    try {
      return latin1.decode(slice, allowInvalid: true);
    } catch (_) {
      return null;
    }
  }
}

class _Delimiters {
  const _Delimiters({
    required this.component,
    required this.element,
    required this.decimal,
    required this.release,
    required this.segment,
    required this.unaConsumed,
  });

  final String component;
  final String element;
  final String decimal;
  final String release;
  final String segment;
  final bool unaConsumed;

  factory _Delimiters.fromSource(String source) {
    final trimmed = source.trimLeft();
    final unaOffset = trimmed.indexOf('UNA');
    if (unaOffset == 0 && trimmed.length >= EdifactParser._unaLength) {
      return _Delimiters(
        component: trimmed[3],
        element: trimmed[4],
        decimal: trimmed[5],
        release: trimmed[6],
        // trimmed[7] is reserved (space)
        segment: trimmed[8],
        unaConsumed: true,
      );
    }
    return const _Delimiters(
      component: ':',
      element: '+',
      decimal: '.',
      release: '?',
      segment: "'",
      unaConsumed: false,
    );
  }
}

class _Segment {
  const _Segment(this.tag, this.elements);
  final String tag;
  final List<List<String>> elements;

  String? at(int element, int component) {
    if (element >= elements.length) return null;
    final comp = elements[element];
    if (component >= comp.length) return null;
    final v = comp[component];
    return v.isEmpty ? null : v;
  }
}
