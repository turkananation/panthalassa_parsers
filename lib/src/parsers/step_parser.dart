import 'dart:convert';
import 'dart:typed_data';

import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_exception.dart';
import '../core/parse_result.dart';

/// Parser for STEP exchange files (ISO 10303-21, "Part 21").
///
/// Tokenises the `HEADER` and `DATA` sections, extracting the standard header
/// entities (`FILE_DESCRIPTION`, `FILE_NAME`, `FILE_SCHEMA`) and indexing the
/// `#<id> = ENTITY(...)` instances in the data section. Comments (`/* ... */`)
/// and string escapes are handled so that `;` inside a quoted string never
/// terminates a statement prematurely.
final class StepParser implements DocumentParser {
  const StepParser();

  static const _magic = 'ISO-10303-21;';

  @override
  DocumentFormat get format => DocumentFormat.step;

  @override
  bool canParse(Uint8List bytes) {
    final p = _peek(bytes, 64);
    return p != null && p.replaceAll(RegExp(r'\s'), '').startsWith('ISO-10303-21;');
  }

  @override
  ParseResult parse(Uint8List bytes, {required ContentHasher hasher}) {
    final String source;
    try {
      source = latin1.decode(bytes, allowInvalid: true);
    } on FormatException catch (e) {
      throw TextDecodingException('cannot decode STEP file: ${e.message}');
    }

    final clean = _stripComments(source);
    if (!clean.contains(_magic)) {
      throw const MalformedDocumentException('missing ISO-10303-21 header token');
    }

    final statements = _splitStatements(clean);
    final header = <String, Object?>{};
    final entityCounts = <String, int>{};
    var instanceCount = 0;
    String? schema;

    var section = _Section.preamble;
    for (final stmt in statements) {
      final s = stmt.trim();
      if (s.isEmpty) continue;
      switch (s.toUpperCase()) {
        case 'HEADER':
          section = _Section.header;
          continue;
        case 'DATA' || _ when s.toUpperCase().startsWith('DATA'):
          section = _Section.data;
          continue;
        case 'ENDSEC':
          section = _Section.preamble;
          continue;
      }

      if (section == _Section.header) {
        final name = _entityName(s);
        if (name == 'FILE_NAME') {
          header['fileName'] = _firstStringArg(s);
        } else if (name == 'FILE_DESCRIPTION') {
          header['fileDescription'] = _firstStringArg(s);
        } else if (name == 'FILE_SCHEMA') {
          schema = _firstStringArg(s);
          header['fileSchema'] = schema;
        }
      } else if (section == _Section.data) {
        final m = RegExp(r'^#(\d+)\s*=\s*([A-Za-z_][\w]*)').firstMatch(s);
        if (m != null) {
          instanceCount++;
          final entity = m.group(2)!;
          entityCounts.update(entity, (v) => v + 1, ifAbsent: () => 1);
        }
      }
    }

    if (instanceCount == 0) {
      throw const MalformedDocumentException('no DATA-section instances found');
    }

    // Top entity types by frequency, for a quick structural fingerprint.
    final topEntities = (entityCounts.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value)))
        .take(10)
        .map((e) => {'entity': e.key, 'count': e.value})
        .toList();

    return ParseResult(
      documentId: hasher.idFor(bytes),
      format: format,
      byteLength: bytes.length,
      metadata: {
        ...header,
        'schema': schema,
        'instanceCount': instanceCount,
        'distinctEntities': entityCounts.length,
        'topEntities': topEntities,
      },
      text: null, // STEP carries geometry, not prose; expose structure only.
    );
  }

  String _stripComments(String s) => s.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), ' ');

  /// Splits on `;` while ignoring semicolons inside single-quoted strings.
  List<String> _splitStatements(String s) {
    final out = <String>[];
    final current = StringBuffer();
    var inString = false;
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (ch == "'") {
        // '' is an escaped quote inside a string.
        if (inString && i + 1 < s.length && s[i + 1] == "'") {
          current.write("''");
          i++;
          continue;
        }
        inString = !inString;
        current.write(ch);
        continue;
      }
      if (ch == ';' && !inString) {
        out.add(current.toString());
        current.clear();
        continue;
      }
      current.write(ch);
    }
    if (current.toString().trim().isNotEmpty) out.add(current.toString());
    return out;
  }

  String? _entityName(String statement) {
    final m = RegExp(r'^([A-Za-z_][\w]*)\s*\(').firstMatch(statement.trim());
    return m?.group(1)?.toUpperCase();
  }

  String? _firstStringArg(String statement) {
    final m = RegExp(r"'((?:[^']|'')*)'").firstMatch(statement);
    return m?.group(1)?.replaceAll("''", "'");
  }

  String? _peek(Uint8List bytes, int max) {
    final slice = bytes.length <= max ? bytes : Uint8List.sublistView(bytes, 0, max);
    return latin1.decode(slice, allowInvalid: true);
  }
}

enum _Section { preamble, header, data }
