import 'package:meta/meta.dart';

import 'content_hasher.dart';
import 'document_format.dart';
import 'structured_artifacts.dart';

/// Current `ParseResult.toJson()` schema version.
///
/// Bump whenever a field changes meaning or is removed. Additive fields do not
/// require a bump, but are documented in the changelog.
const int parseResultSchemaVersion = 2;

/// The immutable, isolate-transferable result of parsing one document.
///
/// Contains only data (no open resources), so it can be returned across an
/// [Isolate] boundary without copying concerns beyond the bytes themselves.
/// Attachments may retain payload bytes when explicitly requested; otherwise
/// only digests and text are carried.
@immutable
final class ParseResult {
  const ParseResult({
    required this.documentId,
    required this.format,
    required this.byteLength,
    this.digest,
    this.metadata = const {},
    this.text,
    this.warnings = const [],
    this.structuredText,
    this.outline = const [],
    this.tables = const [],
    this.attachments = const [],
    this.signatures = const [],
    this.securityLabel,
    this.parserVersion = 'unknown',
  });

  /// Content-addressed identifier (lowercase hex SHA-256 by default).
  ///
  /// Kept for backward compatibility. New code should use [digest] and treat
  /// [documentId] as `digest.sha256`.
  final String documentId;

  /// SHA-256, SHA-384, and SHA-512 digests of the exact input bytes.
  final ContentDigest? digest;

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

  /// Page/section-aware text with optional coordinates and styles.
  final StructuredText? structuredText;

  /// Navigation entries (bookmarks, headings, spine order, …).
  final List<OutlineEntry> outline;

  /// Native tables extracted from explicit table structures.
  final List<DocumentTable> tables;

  /// Embedded files/attachments surfaced by container formats.
  final List<DocumentAttachment> attachments;

  /// Presence-only signature envelope metadata.
  final List<DocumentSignature> signatures;

  /// Normalised classification/handling metadata (NITF, STANAG, XMP…).
  final SecurityLabel? securityLabel;

  /// Version of the parser/formatter that produced this result.
  final String parserVersion;

  bool get hasText => text != null && text!.isNotEmpty;

  /// SHA-512 hex when available (convenience for vault adapters).
  String? get sha512 => digest?.sha512;

  /// SHA-384 hex when available.
  String? get sha384 => digest?.sha384;

  Map<String, Object?> toJson({bool includeAttachmentText = true}) => {
    'schemaVersion': parseResultSchemaVersion,
    'documentId': documentId,
    if (digest != null) ...{
      'sha256': digest!.sha256,
      'sha384': digest!.sha384,
      'sha512': digest!.sha512,
    },
    'format': format.name,
    'byteLength': byteLength,
    'parserVersion': parserVersion,
    'metadata': metadata,
    'text': text,
    'warnings': warnings.map((w) => w.toJson()).toList(),
    if (structuredText != null) 'structuredText': structuredText!.toJson(),
    if (outline.isNotEmpty) 'outline': [for (final e in outline) e.toJson()],
    if (tables.isNotEmpty) 'tables': [for (final t in tables) t.toJson()],
    if (attachments.isNotEmpty)
      'attachments': [
        for (final a in attachments)
          a.toJson(includeText: includeAttachmentText),
      ],
    if (signatures.isNotEmpty)
      'signatures': [for (final s in signatures) s.toJson()],
    if (securityLabel != null) 'securityLabel': securityLabel!.toJson(),
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
