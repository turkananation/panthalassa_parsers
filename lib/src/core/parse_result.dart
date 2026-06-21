import 'package:meta/meta.dart';

import 'document_format.dart';

/// The immutable, isolate-transferable result of parsing one document.
///
/// Contains only data (no open resources), so it can be returned across an
/// [Isolate] boundary without copying concerns beyond the bytes themselves.
@immutable
final class ParseResult {
  const ParseResult({
    required this.documentId,
    required this.format,
    required this.byteLength,
    this.metadata = const {},
    this.text,
    this.warnings = const [],
  });

  /// Content-addressed identifier (lowercase hex SHA-256 by default).
  final String documentId;

  /// The detected format.
  final DocumentFormat format;

  /// Size of the parsed input in bytes.
  final int byteLength;

  /// Format-specific structured fields (patient id, message header, page
  /// count, schema, etc.). Values are JSON-encodable scalars or nested
  /// `Map`/`List` of the same, so the result serialises cleanly.
  final Map<String, Object?> metadata;

  /// Extracted plain text, where the format carries recoverable text.
  /// `null` for formats with no textual layer (e.g. pure GMTI radar data).
  final String? text;

  /// Non-fatal issues encountered during parsing. An empty list means a clean
  /// parse; a populated list still indicates a usable result.
  final List<ParseWarning> warnings;

  bool get hasText => text != null && text!.isNotEmpty;

  Map<String, Object?> toJson() => {
    'documentId': documentId,
    'format': format.name,
    'byteLength': byteLength,
    'metadata': metadata,
    'text': text,
    'warnings': warnings.map((w) => w.toJson()).toList(),
  };

  @override
  String toString() =>
      'ParseResult(${format.name}, id: ${documentId.substring(0, 12)}…, '
      '${byteLength}B, warnings: ${warnings.length})';
}

/// A recoverable issue detected during parsing.
@immutable
final class ParseWarning {
  const ParseWarning(this.code, this.message, {this.offset});

  /// Stable machine-readable code (e.g. `dicom.unknown_vr`).
  final String code;

  /// Human-readable detail. Never contains document payload bytes.
  final String message;

  /// Byte offset, when known.
  final int? offset;

  Map<String, Object?> toJson() => {
    'code': code,
    'message': message,
    if (offset != null) 'offset': offset,
  };

  @override
  String toString() => '[$code] $message';
}
