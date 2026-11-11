import 'dart:convert';
import 'dart:typed_data';

/// Shared helpers for JSON-family parsers: tolerant JSON / NDJSON decoding,
/// text harvesting from arbitrary JSON trees, JWT decoding, and cheap sniffing.
class JsonSupport {
  /// Hard ceiling on NDJSON records retained from one stream.
  static const int maxNdjsonRecords = 200000;

  /// Decodes UTF-8 JSON, or newline-delimited JSON (NDJSON), into a list of
  /// top-level records, plus whether NDJSON was detected. Throws
  /// [FormatException] if nothing parses or nesting exceeds a safe depth.
  static (List<Object?>, bool) decode(Uint8List bytes) {
    final source = utf8.decode(bytes, allowMalformed: false);
    final trimmed = source.trim();
    try {
      return ([_decodeValue(trimmed)], false);
    } on FormatException {
      // Not a single JSON value — try NDJSON below.
    }
    final records = <Object?>[];
    for (final line in const LineSplitter().convert(source)) {
      final t = line.trim();
      if (t.isEmpty) continue;
      records.add(_decodeValue(t)); // throws if a line is not JSON
      if (records.length > maxNdjsonRecords) {
        throw const FormatException('NDJSON record count exceeds the limit');
      }
    }
    if (records.isEmpty) throw const FormatException('empty JSON document');
    return (records, true);
  }

  static Object? _decodeValue(String source) {
    try {
      return jsonDecode(source);
    } on StackOverflowError {
      // Dart's recursive decoder can exhaust the stack on deeply nested input.
      throw const FormatException('JSON nesting is too deep');
    }
  }

  /// Appends every non-empty string scalar reachable in [node] to [out], one
  /// per line, in document order. Numbers/bools are skipped (usually flags or
  /// identifiers, not human text).
  ///
  /// Traversal is iterative, so hostile nesting cannot overflow the call stack.
  /// Returns `true` when a node or character budget truncated the harvest.
  static bool collectText(
    Object? node,
    StringBuffer out, {
    int maxNodes = 200000,
    int maxCharacters = 16 * 1024 * 1024,
  }) {
    var budget = maxNodes;
    var truncated = false;
    final stack = <Object?>[node];
    while (stack.isNotEmpty) {
      if (budget-- <= 0 || out.length >= maxCharacters) {
        truncated = true;
        break;
      }
      final n = stack.removeLast();
      if (n is String) {
        final t = n.trim();
        if (t.isEmpty) continue;
        final remaining = maxCharacters - out.length;
        if (remaining <= 0) {
          truncated = true;
          break;
        }
        if (t.length + 1 <= remaining) {
          out
            ..write(t)
            ..write('\n');
        } else {
          out.write(t.substring(0, remaining));
          truncated = true;
          break;
        }
      } else if (n is List) {
        for (var i = n.length - 1; i >= 0; i--) {
          stack.add(n[i]);
        }
      } else if (n is Map) {
        final values = n.values.toList(growable: false);
        for (var i = values.length - 1; i >= 0; i--) {
          stack.add(values[i]);
        }
      }
    }
    return truncated;
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
