import 'visual_primitives.dart';

/// Renderer contract for faithful visual display lists.
abstract interface class VisualRenderer<T> {
  T render(VisualDocument document);
}

/// Produces standalone, escaped SVG pages from the visual display list.
///
/// This is intentionally pure Dart and framework-free. Flutter adapters can map
/// the same commands to `Canvas`, while Jaspr/web callers can embed or sanitize
/// this output according to their UI policy.
final class SvgVisualRenderer implements VisualRenderer<String> {
  const SvgVisualRenderer();

  @override
  String render(VisualDocument document) {
    final out = StringBuffer();
    for (final page in document.pages) {
      _writePage(out, page);
    }
    return out.toString();
  }

  void _writePage(StringBuffer out, VisualPage page) {
    final geometry = page.geometry;
    out
      ..write('<svg class="panthalassa-visual-page" ')
      ..write('xmlns="http://www.w3.org/2000/svg" ')
      ..write('viewBox="0 0 ')
      ..write(_num(geometry.width))
      ..write(' ')
      ..write(_num(geometry.height))
      ..write('" role="img"');
    if (page.description != null) {
      out
        ..write(' aria-label="')
        ..write(_escapeXml(page.description!))
        ..write('"');
    }
    out.write('>');
    if (page.description != null) {
      out
        ..write('<title>')
        ..write(_escapeXml(page.description!))
        ..write('</title>');
    }
    for (final command in page.commands) {
      _writeCommand(out, page, command);
    }
    out.write('</svg>');
  }

  void _writeCommand(StringBuffer out, VisualPage page, VisualCommand command) {
    switch (command) {
      case VisualTextCommand():
        final point = _point(page, command.x, command.y);
        out
          ..write('<text x="')
          ..write(_num(point.x))
          ..write('" y="')
          ..write(_num(point.y))
          ..write('" font-size="')
          ..write(_num(command.fontSize))
          ..write('" fill="')
          ..write(command.fill.hex)
          ..write('"');
        if (command.fontName != null) {
          out
            ..write(' font-family="')
            ..write(_escapeXml(command.fontName!))
            ..write('"');
        }
        out
          ..write('>')
          ..write(_escapeXml(command.text))
          ..write('</text>');
      case VisualRectCommand():
        final point = _point(page, command.x, command.y + command.height);
        out
          ..write('<rect x="')
          ..write(_num(point.x))
          ..write('" y="')
          ..write(_num(point.y))
          ..write('" width="')
          ..write(_num(command.width))
          ..write('" height="')
          ..write(_num(command.height))
          ..write('" fill="')
          ..write(command.fill?.hex ?? 'none')
          ..write('" stroke="')
          ..write(command.stroke?.hex ?? 'none')
          ..write('" stroke-width="')
          ..write(_num(command.strokeWidth))
          ..write('"/>');
      case VisualImageCommand():
        final point = _point(page, command.x, command.y + command.height);
        out
          ..write('<rect class="panthalassa-image-placeholder" x="')
          ..write(_num(point.x))
          ..write('" y="')
          ..write(_num(point.y))
          ..write('" width="')
          ..write(_num(command.width))
          ..write('" height="')
          ..write(_num(command.height))
          ..write('" fill="#f5f5f5" stroke="#777" stroke-dasharray="4 4"/>');
        out
          ..write('<text x="')
          ..write(_num(point.x + 4))
          ..write('" y="')
          ..write(_num(point.y + 14))
          ..write('" font-size="12" fill="#555">')
          ..write(_escapeXml(command.description ?? command.sourceId))
          ..write('</text>');
      case VisualUnsupportedCommand():
        out
          ..write('<desc>unsupported ')
          ..write(_escapeXml(command.operatorName));
        if (command.detail != null) {
          out
            ..write(': ')
            ..write(_escapeXml(command.detail!));
        }
        out.write('</desc>');
    }
  }

  ({double x, double y}) _point(VisualPage page, double x, double y) {
    final geometry = page.geometry;
    return switch (geometry.coordinateSpace) {
      VisualCoordinateSpace.pdfUserSpace => (
        x: x - geometry.x,
        y: geometry.height - (y - geometry.y),
      ),
      VisualCoordinateSpace.screen => (x: x - geometry.x, y: y - geometry.y),
    };
  }
}

String _num(double value) {
  if (value.isNaN || value.isInfinite) return '0';
  if (value == value.roundToDouble()) return value.toInt().toString();
  return value.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '');
}

String _escapeXml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
