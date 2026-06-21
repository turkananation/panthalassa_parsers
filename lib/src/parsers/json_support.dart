import 'dart:convert';
import 'dart:typed_data';

/// Shared helpers for JSON-family parsers: tolerant JSON / NDJSON decoding,
/// text harvesting from arbitrary JSON trees, JWT decoding, and cheap sniffing.
class JsonSupport {
  /// Decodes UTF-8 JSON, or newline-delimited JSON (NDJSON), into a list of
  /// top-level records, plus whether NDJSON was detected. Throws
  /// [FormatException] if nothing parses.
  static (List<Object?>, bool) decode(Uint8List bytes) {
    final source = utf8.decode(bytes, allowMalformed: false);
    final trimmed = source.trim();
    try {
      return ([jsonDecode(trimmed)], false);
    } on FormatException {
      // Not a single JSON value — try NDJSON below.
    }
    final records = <Object?>[];
    for (final line in const LineSplitter().convert(source)) {
      final t = line.trim();
      if (t.isEmpty) continue;
      records.add(jsonDecode(t)); // throws if a line is not JSON
    }
    if (records.isEmpty) throw const FormatException('empty JSON document');
    return (records, true);
  }

  /// Appends every non-empty string scalar reachable in [node] to [out], one
  /// per line, in document order. Numbers/bools are skipped (usually flags or
  /// identifiers, not human text). Bounded to avoid pathological inputs.
  static void collectText(
    Object? node,
    StringBuffer out, {
    int maxNodes = 200000,
  }) {
    var budget = maxNodes;
    void walk(Object? n) {
      if (budget-- <= 0) return;
      if (n is String) {
        final t = n.trim();
        if (t.isNotEmpty) out.writeln(t);
      } else if (n is List) {
        for (final e in n) {
          walk(e);
        }
      } else if (n is Map) {
        n.forEach((_, v) => walk(v));
      }
    }

    walk(node);
  }

  /// A small UTF-8 prefix for cheap detection, or `null` if not decodable.
  static String? peek(Uint8List bytes, int max) {
    final slice = bytes.length <= max
        ? bytes
        : Uint8List.sublistView(bytes, 0, max);
    try {
      return utf8.decode(slice, allowMalformed: true);
    } on FormatException {
      return null;
    }
  }

  /// True if the prefix's first non-whitespace char begins a JSON object/array.
  static bool looksJson(String prefix) {
    final t = prefix.trimLeft();
    return t.startsWith('{') || t.startsWith('[');
  }

  /// Matches a compact JWS/JWT: three base64url segments separated by dots
  /// (the signature segment may be empty for an unsecured token).
  static final RegExp jwtShape = RegExp(
    r'^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*$',
  );

  /// Decodes a base64url segment (JWT header or payload) to a JSON map, or
  /// `null` if it is not valid base64url-encoded JSON.
  static Map<String, Object?>? decodeJwtSegment(String segment) {
    try {
      var s = segment.replaceAll('-', '+').replaceAll('_', '/');
      switch (s.length % 4) {
        case 2:
          s += '==';
        case 3:
          s += '=';
      }
      final decoded = utf8.decode(base64.decode(s));
      final value = jsonDecode(decoded);
      return value is Map<String, Object?> ? value : null;
    } catch (_) {
      return null;
    }
  }
}
