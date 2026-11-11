import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'content_hasher.dart';

/// Optional axis-aligned bounds in a format-defined coordinate space.
///
/// PDF uses user space (origin bottom-left); HTML-derived formats use a
/// top-left origin. Consumers that mix spaces must consult the owning
/// [TextPage.coordinateSpace].
@immutable
final class TextBounds {
  const TextBounds({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;

  Map<String, Object?> toJson() => {
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
  };
}

/// Coordinate space used by [TextPage] bounds.
enum TextCoordinateSpace { pdfUserSpace, screen, unknown }

/// A run of text sharing one style and, optionally, one bounding box.
@immutable
final class TextSpan {
  const TextSpan(this.text, {this.bounds, this.style});

  final String text;
  final TextBounds? bounds;

  /// Optional semantic style token such as `heading`, `caption`, or `cell`.
  final String? style;

  Map<String, Object?> toJson() => {
    'text': text,
    if (bounds != null) 'bounds': bounds!.toJson(),
    if (style != null) 'style': style,
  };
}

/// A cohesive block of text (paragraph, heading, table cell, caption…).
@immutable
final class TextBlock {
  const TextBlock({
    required this.spans,
    this.bounds,
    this.style,
    this.role,
    this.level,
  });

  final List<TextSpan> spans;
  final TextBounds? bounds;

  /// Semantic style token, e.g. `heading`, `paragraph`, `list-item`, `cell`.
  final String? style;

  /// Optional structural role such as `title`, `abstract`, `footnote`.
  final String? role;

  /// Heading level (1-based) when [style] is `heading`.
  final int? level;

  String get text => spans.map((s) => s.text).join();

  Map<String, Object?> toJson() => {
    'spans': [for (final s in spans) s.toJson()],
    if (bounds != null) 'bounds': bounds!.toJson(),
    if (style != null) 'style': style,
    if (role != null) 'role': role,
    if (level != null) 'level': level,
  };
}

/// One page/frame/slide of structured text.
@immutable
final class TextPage {
  const TextPage({
    required this.index,
    this.width,
    this.height,
    this.blocks = const [],
    this.coordinateSpace = TextCoordinateSpace.unknown,
    this.label,
  });

  /// Zero-based page index.
  final int index;
  final double? width;
  final double? height;
  final List<TextBlock> blocks;
  final TextCoordinateSpace coordinateSpace;

  /// Optional printed page label (e.g. roman numerals or `A-3`).
  final String? label;

  String get text => blocks.map((b) => b.text).join('\n');

  Map<String, Object?> toJson() => {
    'index': index,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (label != null) 'label': label,
    'coordinateSpace': coordinateSpace.name,
    'blocks': [for (final b in blocks) b.toJson()],
  };
}

/// Page-aware text artifact emitted alongside the legacy flat [text] field.
@immutable
final class StructuredText {
  const StructuredText(this.pages);

  final List<TextPage> pages;

  /// Concatenates pages in order. Intended for search/index fallbacks.
  String get text => pages.map((p) => p.text).join('\n\n');

  Map<String, Object?> toJson() => {
    'pages': [for (final p in pages) p.toJson()],
  };
}

/// A navigation entry (PDF outline, DOCX heading, EPUB nav, Markdown heading…).
@immutable
final class OutlineEntry {
  const OutlineEntry({
    required this.title,
    this.level = 1,
    this.page,
    this.anchor,
    this.children = const [],
  });

  final String title;

  /// One-based depth; 1 is a top-level entry.
  final int level;

  /// Zero-based destination page, when known.
  final int? page;

  /// Format-specific anchor (HTML id, OOXML bookmark, PDF named destination…).
  final String? anchor;

  final List<OutlineEntry> children;

  Map<String, Object?> toJson() => {
    'title': title,
    'level': level,
    if (page != null) 'page': page,
    if (anchor != null) 'anchor': anchor,
    if (children.isNotEmpty) 'children': [for (final c in children) c.toJson()],
  };
}

/// A rectangular table extracted from a native table structure.
///
/// This deliberately does not implement heuristic PDF table detection; it is
/// populated only where the format carries explicit rows and cells.
@immutable
final class DocumentTable {
  const DocumentTable({this.caption, this.name, required this.rows, this.page});

  final String? caption;

  /// Sheet or table name, where the source provides one.
  final String? name;

  /// Rows of cell text. Ragged rows are preserved as-is.
  final List<List<String>> rows;

  /// Zero-based page/slide index when known.
  final int? page;

  Map<String, Object?> toJson() => {
    if (caption != null) 'caption': caption,
    if (name != null) 'name': name,
    if (page != null) 'page': page,
    'rows': rows,
  };
}

/// Normalised security classification metadata across defence formats.
@immutable
final class SecurityLabel {
  const SecurityLabel({
    this.classification,
    this.caveats = const [],
    this.releasability,
    this.ownerProducer,
    this.source,
    this.raw = const {},
  });

  /// Classification token, e.g. `UNCLASSIFIED`, `SECRET`, `NATO SECRET`.
  final String? classification;

  /// Handling caveats / compartments.
  final List<String> caveats;

  final String? releasability;
  final String? ownerProducer;
  final String? source;

  /// Source-specific fields for round-tripping.
  final Map<String, Object?> raw;

  bool get isEmpty =>
      classification == null &&
      caveats.isEmpty &&
      releasability == null &&
      ownerProducer == null;

  Map<String, Object?> toJson() => {
    if (classification != null) 'classification': classification,
    if (caveats.isNotEmpty) 'caveats': caveats,
    if (releasability != null) 'releasability': releasability,
    if (ownerProducer != null) 'ownerProducer': ownerProducer,
    if (source != null) 'source': source,
    if (raw.isNotEmpty) 'raw': raw,
  };
}

/// An attachment surfaced from a container format.
///
/// [bytes] is held in memory for downstream vault ingestion but is intentionally
/// omitted from [toJson] unless explicitly requested, so ordinary parse logs do
/// not leak embedded payloads.
@immutable
final class DocumentAttachment {
  const DocumentAttachment({
    this.name,
    this.mediaType,
    this.size,
    this.digest,
    this.bytes,
    this.text,
    this.child,
    this.path = const [],
    this.encrypted = false,
    this.relationship,
  });

  final String? name;
  final String? mediaType;
  final int? size;

  /// Triple content digest of the attachment payload, when available.
  final ContentDigest? digest;

  /// Raw attachment bytes, when the caller requested payload retention.
  final Uint8List? bytes;

  /// Extracted text for text-bearing attachments.
  final String? text;

  /// Recursively parsed child, when recursion was enabled.
  final Object? child;

  /// Path from the root document to this attachment.
  final List<String> path;

  final bool encrypted;

  /// Container-specific relationship (e.g. PDF `/AFRelationship`).
  final String? relationship;

  bool get hasBytes => bytes != null;

  Map<String, Object?> toJson({bool includeText = true}) => {
    if (name != null) 'name': name,
    if (mediaType != null) 'mediaType': mediaType,
    if (size != null) 'size': size,
    if (digest != null) 'digest': digest!.toJson(),
    if (includeText && text != null) 'text': text,
    if (path.isNotEmpty) 'path': path,
    if (encrypted) 'encrypted': true,
    if (relationship != null) 'relationship': relationship,
    'hasBytes': hasBytes,
    if (child != null) 'child': child,
  };

  DocumentAttachment copyWith({
    String? name,
    String? mediaType,
    int? size,
    ContentDigest? digest,
    Uint8List? bytes,
    String? text,
    Object? child,
    List<String>? path,
    bool? encrypted,
    String? relationship,
  }) => DocumentAttachment(
    name: name ?? this.name,
    mediaType: mediaType ?? this.mediaType,
    size: size ?? this.size,
    digest: digest ?? this.digest,
    bytes: bytes ?? this.bytes,
    text: text ?? this.text,
    child: child ?? this.child,
    path: path ?? this.path,
    encrypted: encrypted ?? this.encrypted,
    relationship: relationship ?? this.relationship,
  );
}

/// Presence-only signature envelope metadata.
///
/// [verified] stays `null` unless an external vault layer explicitly verifies
/// the signature; parsers never make cryptographic assurance claims.
@immutable
final class DocumentSignature {
  const DocumentSignature({
    required this.role,
    required this.signer,
    this.verified,
    this.algorithm,
    this.subFilter,
    this.signingTime,
    this.byteRange,
    this.coversWholeDocument,
    this.reason,
    this.location,
  });

  final String role;
  final String signer;
  final bool? verified;
  final String? algorithm;
  final String? subFilter;
  final String? signingTime;
  final List<int>? byteRange;
  final bool? coversWholeDocument;
  final String? reason;
  final String? location;

  Map<String, Object?> toJson() => {
    'role': role,
    'signer': signer,
    if (verified != null) 'verified': verified,
    if (algorithm != null) 'algorithm': algorithm,
    if (subFilter != null) 'subFilter': subFilter,
    if (signingTime != null) 'signingTime': signingTime,
    if (byteRange != null) 'byteRange': byteRange,
    if (coversWholeDocument != null) 'coversWholeDocument': coversWholeDocument,
    if (reason != null) 'reason': reason,
    if (location != null) 'location': location,
  };
}

/// Caller-supplied filename/MIME/disambiguation hints.
@immutable
final class DocumentHints {
  const DocumentHints({this.filename, this.mimeType});

  final String? filename;
  final String? mimeType;

  String? get extension {
    final name = filename;
    if (name == null) return null;
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return null;
    return name.substring(dot + 1).toLowerCase();
  }

  @override
  bool operator ==(Object other) =>
      other is DocumentHints &&
      other.filename == filename &&
      other.mimeType == mimeType;

  @override
  int get hashCode => Object.hash(filename, mimeType);
}
