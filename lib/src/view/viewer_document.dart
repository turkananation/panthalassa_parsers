import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../core/parse_result.dart';

/// A self-contained, renderer-neutral document viewer model.
///
/// Format-specific builders produce this model; [ViewerHtmlRenderer] turns it
/// into a single HTML file. Flutter or Jaspr adapters can consume the same
/// sections without depending on the CLI.
@immutable
final class ViewerDocument {
  const ViewerDocument({
    required this.title,
    required this.formatLabel,
    this.subtitle,
    this.facts = const {},
    this.sections = const [],
    this.assets = const {},
    this.notices = const [],
    this.footer,
  });

  final String title;
  final String formatLabel;
  final String? subtitle;

  /// Ordered label/value pairs shown in the sidebar.
  final Map<String, String> facts;

  final List<ViewerSection> sections;

  /// Binary assets referenced by [ViewerImageSection.assetName].
  final Map<String, ViewerAsset> assets;

  final List<ViewerNotice> notices;
  final String? footer;
}

/// Common contract for viewer body sections.
sealed class ViewerSection {
  const ViewerSection({this.title});

  final String? title;
}

/// Tabular data with optional client-side filtering.
final class ViewerTableSection extends ViewerSection {
  const ViewerTableSection({
    super.title,
    required this.columns,
    required this.rows,
    this.caption,
    this.totalRowCount,
    this.truncated = false,
    this.filterable = true,
  });

  final List<String> columns;
  final List<List<String>> rows;
  final String? caption;
  final int? totalRowCount;
  final bool truncated;
  final bool filterable;
}

/// A raster image embedded from [ViewerDocument.assets].
final class ViewerImageSection extends ViewerSection {
  const ViewerImageSection({
    super.title,
    required this.assetName,
    this.caption,
    this.alt,
    this.width,
    this.height,
    this.zoomable = true,
  });

  final String assetName;
  final String? caption;
  final String? alt;
  final int? width;
  final int? height;
  final bool zoomable;
}

/// An embedded document rendered by a browser-native viewer, such as PDF.
final class ViewerEmbedSection extends ViewerSection {
  const ViewerEmbedSection({
    super.title,
    required this.assetName,
    this.downloadName,
    this.caption,
  });

  final String assetName;
  final String? downloadName;
  final String? caption;
}

/// Preformatted text, useful for text-only extracts and diagnostics.
final class ViewerTextSection extends ViewerSection {
  const ViewerTextSection({
    super.title,
    required this.text,
    this.monospace = false,
  });

  final String text;
  final bool monospace;
}

/// Trusted HTML produced by another renderer in this package.
///
/// Builders must only pass HTML they generated themselves; never pass raw
/// document text through this section without escaping it.
final class ViewerHtmlSection extends ViewerSection {
  const ViewerHtmlSection({super.title, required this.html});

  final String html;
}

@immutable
final class ViewerAsset {
  const ViewerAsset({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });

  final String name;
  final String mimeType;
  final Uint8List bytes;
}

enum ViewerNoticeLevel { info, warning, error }

@immutable
final class ViewerNotice {
  const ViewerNotice(this.message, {this.level = ViewerNoticeLevel.info});

  final String message;
  final ViewerNoticeLevel level;
}

/// Viewer controls shared by every format builder.
@immutable
final class ViewerOptions {
  const ViewerOptions({
    this.title,
    this.rowLimit = 5000,
    this.allRows = false,
    this.frame = 0,
    this.allFrames = false,
    this.windowCenter,
    this.windowWidth,
    this.invert = false,
  });

  final String? title;
  final int rowLimit;
  final bool allRows;

  /// Zero-based DICOM frame index. The CLI exposes a one-based value.
  final int frame;

  final bool allFrames;
  final double? windowCenter;
  final double? windowWidth;
  final bool invert;
}

/// Everything a [ViewBuilder] needs to produce a [ViewerDocument].
@immutable
final class ViewerRequest {
  const ViewerRequest({
    required this.result,
    required this.bytes,
    required this.filename,
    this.options = const ViewerOptions(),
  });

  final ParseResult result;
  final Uint8List bytes;
  final String filename;
  final ViewerOptions options;
}

/// Format-specific viewer builder.
abstract interface class ViewBuilder {
  /// Stable identifier used in diagnostics and tests.
  String get id;

  /// Cheap, non-throwing format check.
  bool supports(ParseResult result);

  ViewerDocument build(ViewerRequest request);
}
