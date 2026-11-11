import 'package:meta/meta.dart';

/// Hard resource ceilings applied while parsing.
///
/// Parsers are expected to fail closed (typed [ParseException]) or truncate
/// with a warning when a limit is exceeded; they must never allocate without
/// bound based on an attacker-controlled length field.
@immutable
final class ParseLimits {
  const ParseLimits({
    this.maxTextCharacters = 16 * 1024 * 1024,
    this.maxMetadataEntries = 20000,
    this.maxJsonNodes = 500000,
    this.maxTableRows = 200000,
    this.maxTableColumns = 1024,
    this.maxAttachments = 128,
    this.maxAttachmentBytes = 64 * 1024 * 1024,
    this.maxDecompressedBytes = 256 * 1024 * 1024,
    this.maxDecompressedEntryBytes = 64 * 1024 * 1024,
    this.maxRecursionDepth = 3,
    this.maxPages = 20000,
    this.maxSegments = 50000,
  });

  /// Maximum characters retained in [ParseResult.text].
  final int maxTextCharacters;

  /// Maximum top-level + nested metadata entries retained.
  final int maxMetadataEntries;

  /// Maximum nodes visited while walking a JSON tree.
  final int maxJsonNodes;

  /// Maximum rows across all extracted tables.
  final int maxTableRows;

  /// Maximum columns retained per table row.
  final int maxTableColumns;

  /// Maximum embedded attachments surfaced per document.
  final int maxAttachments;

  /// Maximum total attachment payload bytes retained.
  final int maxAttachmentBytes;

  /// Maximum total bytes inflated from any container (ZIP, PDF streams).
  final int maxDecompressedBytes;

  /// Maximum bytes inflated from a single entry/stream.
  final int maxDecompressedEntryBytes;

  /// Maximum attachment recursion depth when `parseAttachments` is enabled.
  final int maxRecursionDepth;

  /// Maximum pages/slides/frames indexed.
  final int maxPages;

  /// Maximum binary segments indexed.
  final int maxSegments;

  /// Conservative defaults for untrusted ingest.
  static const standard = ParseLimits();

  /// Tighter ceilings for per-request/server use.
  static const strict = ParseLimits(
    maxTextCharacters: 2 * 1024 * 1024,
    maxMetadataEntries: 2000,
    maxJsonNodes: 50000,
    maxTableRows: 20000,
    maxAttachments: 16,
    maxAttachmentBytes: 8 * 1024 * 1024,
    maxDecompressedBytes: 32 * 1024 * 1024,
    maxDecompressedEntryBytes: 16 * 1024 * 1024,
    maxRecursionDepth: 1,
  );
}

/// Per-call parser behaviour switches.
///
/// Defaults preserve the historical output shape (including PDF visual
/// metadata) while adding opt-in recursive attachment parsing.
@immutable
final class ParseOptions {
  const ParseOptions({
    this.limits = ParseLimits.standard,
    this.includeVisual = true,
    this.includeStructuredText = true,
    this.includeOutline = true,
    this.includeTables = true,
    this.includeAttachments = true,
    this.includeAttachmentBytes = false,
    this.parseAttachments = false,
    this.includeAnnotations = true,
    this.includeFormFields = true,
    this.includeSignatures = true,
    this.includeSecurityLabels = true,
    this.rejectEncrypted = false,
  });

  final ParseLimits limits;

  /// Emit format-specific visual display lists (currently PDF).
  final bool includeVisual;

  /// Emit page/section-aware [StructuredText].
  final bool includeStructuredText;

  /// Emit outline/bookmark/navigation entries.
  final bool includeOutline;

  /// Emit native tables.
  final bool includeTables;

  /// Surface embedded attachments (metadata and extracted text).
  final bool includeAttachments;

  /// Retain raw attachment bytes in memory (never serialised by default).
  final bool includeAttachmentBytes;

  /// Recursively parse supported attachments into [DocumentAttachment.child].
  final bool parseAttachments;

  /// Surface annotations/comments where the format supports them.
  final bool includeAnnotations;

  /// Surface form fields where the format supports them.
  final bool includeFormFields;

  /// Surface signature envelopes (presence only; never verification).
  final bool includeSignatures;

  /// Emit normalised security labels where the format carries them.
  final bool includeSecurityLabels;

  /// Treat encrypted/password-protected documents as an error instead of
  /// extracting what is possible with an empty password.
  final bool rejectEncrypted;

  ParseOptions copyWith({
    ParseLimits? limits,
    bool? includeVisual,
    bool? includeStructuredText,
    bool? includeOutline,
    bool? includeTables,
    bool? includeAttachments,
    bool? includeAttachmentBytes,
    bool? parseAttachments,
    bool? includeAnnotations,
    bool? includeFormFields,
    bool? includeSignatures,
    bool? includeSecurityLabels,
    bool? rejectEncrypted,
  }) => ParseOptions(
    limits: limits ?? this.limits,
    includeVisual: includeVisual ?? this.includeVisual,
    includeStructuredText: includeStructuredText ?? this.includeStructuredText,
    includeOutline: includeOutline ?? this.includeOutline,
    includeTables: includeTables ?? this.includeTables,
    includeAttachments: includeAttachments ?? this.includeAttachments,
    includeAttachmentBytes:
        includeAttachmentBytes ?? this.includeAttachmentBytes,
    parseAttachments: parseAttachments ?? this.parseAttachments,
    includeAnnotations: includeAnnotations ?? this.includeAnnotations,
    includeFormFields: includeFormFields ?? this.includeFormFields,
    includeSignatures: includeSignatures ?? this.includeSignatures,
    includeSecurityLabels: includeSecurityLabels ?? this.includeSecurityLabels,
    rejectEncrypted: rejectEncrypted ?? this.rejectEncrypted,
  );
}
