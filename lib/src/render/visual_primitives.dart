import 'package:meta/meta.dart';

import '../core/document_format.dart';

/// Coordinate space used by faithful visual commands.
enum VisualCoordinateSpace {
  /// PDF-style user space: origin at bottom-left, positive y upward.
  pdfUserSpace,

  /// Screen-style space: origin at top-left, positive y downward.
  screen,
}

/// Page or frame geometry for faithful rendering.
@immutable
final class PageGeometry {
  const PageGeometry({
    required this.width,
    required this.height,
    this.pageIndex,
    this.x = 0,
    this.y = 0,
    this.coordinateSpace = VisualCoordinateSpace.pdfUserSpace,
  });

  final double width;
  final double height;
  final int? pageIndex;
  final double x;
  final double y;
  final VisualCoordinateSpace coordinateSpace;
}

/// Immutable display-list document used by faithful renderers and UI adapters.
@immutable
final class VisualDocument {
  const VisualDocument({
    required this.sourceFormat,
    required this.pages,
    this.contentId,
    this.metadata = const {},
  });

  final DocumentFormat sourceFormat;
  final List<VisualPage> pages;
  final String? contentId;
  final Map<String, Object?> metadata;

  bool get isEmpty => pages.isEmpty;
}

/// One visual page, tile, or frame.
@immutable
final class VisualPage {
  const VisualPage({
    required this.geometry,
    this.commands = const [],
    this.description,
    this.semanticText,
    this.sourceId,
  });

  final PageGeometry geometry;
  final List<VisualCommand> commands;
  final String? description;
  final String? semanticText;
  final String? sourceId;
}

/// Base command in the pure-Dart faithful rendering display list.
sealed class VisualCommand {
  const VisualCommand();
}

/// A positioned text draw command. Coordinates are in the page's coordinate
/// space and represent the baseline origin.
@immutable
final class VisualTextCommand extends VisualCommand {
  const VisualTextCommand({
    required this.text,
    required this.x,
    required this.y,
    required this.fontSize,
    this.fontName,
    this.fill = const VisualColor.black(),
  });

  final String text;
  final double x;
  final double y;
  final double fontSize;
  final String? fontName;
  final VisualColor fill;
}

/// A rectangle path draw command.
@immutable
final class VisualRectCommand extends VisualCommand {
  const VisualRectCommand({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.fill,
    this.stroke,
    this.strokeWidth = 1,
  });

  final double x;
  final double y;
  final double width;
  final double height;
  final VisualColor? fill;
  final VisualColor? stroke;
  final double strokeWidth;
}

/// A placeholder for image/tile/frame data that has been discovered but not yet
/// decoded into pixels.
@immutable
final class VisualImageCommand extends VisualCommand {
  const VisualImageCommand({
    required this.sourceId,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.mediaType,
    this.description,
  });

  final String sourceId;
  final double x;
  final double y;
  final double width;
  final double height;
  final String? mediaType;
  final String? description;
}

/// Explicit unsupported/opaque operator marker. Faithful renderers can surface
/// this in diagnostics without silently pretending a page was fully rendered.
@immutable
final class VisualUnsupportedCommand extends VisualCommand {
  const VisualUnsupportedCommand({required this.operatorName, this.detail});

  final String operatorName;
  final String? detail;
}

/// Eight-bit sRGB color used by visual display-list commands.
@immutable
final class VisualColor {
  const VisualColor({required this.r, required this.g, required this.b});
  const VisualColor.black() : this(r: 0, g: 0, b: 0);
  const VisualColor.white() : this(r: 255, g: 255, b: 255);

  final int r;
  final int g;
  final int b;

  String get hex {
    String c(int value) =>
        value.clamp(0, 255).toRadixString(16).padLeft(2, '0');
    return '#${c(r)}${c(g)}${c(b)}';
  }
}
