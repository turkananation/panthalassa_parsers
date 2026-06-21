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
    final String source;
    try {
      // EDIFACT is commonly Latin-1; decode permissively but flag non-ASCII.
      source = latin1.decode(bytes, allowInvalid: true);
    } on FormatException catch (e) {
      throw TextDecodingException('cannot decode EDIFACT: ${e.message}');
    }

    final delims = _Delimiters.fromSource(source);
    final body = delims.unaConsumed ? source.substring(9) : source;
    final segments = _splitSegments(body, delims);
    if (segments.isEmpty) {
      throw const MalformedDocumentException('no EDIFACT segments found');
    }

    final warnings = <ParseWarning>[];
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
      documentId: hasher.idFor(bytes),
      format: format,
      byteLength: bytes.length,
      metadata: {
        'segmentCount': segments.length,
        'syntaxIdentifier': unb.at(0, 0),
        'sender': unb.at(1, 0),
        'recipient': unb.at(2, 0),
        'interchangeRef': unb.at(4, 0),
        'messageTypes': messageTypes,
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
      // Release sequences are preserved through the segment and element splits,
      // then resolved once at the component (leaf) level — otherwise the escape
      // would be consumed by the first pass and fail to protect inner
      // separators (e.g. "ACME?+CO" must stay a single value "ACME+CO").
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
    return latin1.decode(slice, allowInvalid: true);
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
    if (source.startsWith('UNA') && source.length >= 9) {
      return _Delimiters(
        component: source[3],
        element: source[4],
        decimal: source[5],
        release: source[6],
        // source[7] is reserved (space)
        segment: source[8],
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
