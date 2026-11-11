import 'document_ir.dart';
import 'document_renderer.dart';
import 'visual_primitives.dart';
import 'visual_renderer.dart';

/// Renders a [DocumentIr] (semantic content) together with an optional
/// [VisualDocument] (faithful display-list pages) into one self-contained HTML
/// page.
///
/// This is a pure-Dart, framework-free adapter surface. Flutter adapters can
/// map the same `DocumentIr`/`VisualDocument` to `Canvas`, and Jaspr/web
/// callers can consume this HTML directly or sanitize it per their UI policy.
///
/// Visual pages are embedded as inline SVG so the page geometry, positioned
/// text, rectangles, image placeholders, and unsupported-operator diagnostics
/// travel with the semantic text/Markdown/HTML output.
final class DocumentPageAdapter {
  const DocumentPageAdapter();

  /// Renders [ir] with an optional [visual] projection into a single HTML
  /// document.
  ///
  /// [options] are forwarded to the semantic [HtmlDocumentRenderer].
  String render({
    required DocumentIr ir,
    VisualDocument? visual,
    RenderOptions options = const RenderOptions(),
  }) {
    final semantic = const HtmlDocumentRenderer().render(
      ir,
      options: options,
    );
    final svg = visual == null || visual.isEmpty
        ? ''
        : const SvgVisualRenderer().render(visual);
    final title = _pageTitle(ir);
    return '''
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="generator" content="panthalassa">
<title>${_escapeHtml(title)}</title>
<style>$_pageStyle</style>
</head>
<body>
<header class="panthalassa-header">
  <div class="panthalassa-title">${_escapeHtml(title)}</div>
  <div class="panthalassa-format">Format: ${_escapeHtml(ir.sourceFormat.name)}</div>
  ${_metadataBlock(ir.metadata, options.includeMetadata)}
</header>
<main class="panthalassa-body">
  $semantic
  ${_visualBlock(svg, visual)}
</main>
<footer class="panthalassa-footer">
  ${_escapeHtml(ir.sourceFormat.name)} · documentId ${_escapeHtml(ir.contentId ?? '-')}
</footer>
</body>
</html>
''';
  }

  String _pageTitle(DocumentIr ir) {
    for (final block in ir.body) {
      if (block is HeadingBlock && block.text.isNotEmpty) {
        return block.text.map((i) {
          if (i is TextRun) return i.text;
          return '';
        }).join().trimRight();
      }
    }
    return 'panthalassa document';
  }

  String _metadataBlock(Map<String, Object?> metadata, bool include) {
    if (!include || metadata.isEmpty) return '';
    final lines = <String>[];
    for (final entry in metadata.entries) {
      if (entry.key == 'visualPages') continue;
      final value = _metadataValue(entry.value);
      if (value.isEmpty) continue;
      lines.add(
        '<div class="panthalassa-meta-row">'
        '<span class="panthalassa-meta-key">${_escapeHtml(entry.key)}</span>'
        '<span class="panthalassa-meta-value">${_escapeHtml(value)}</span>'
        '</div>',
      );
    }
    if (lines.isEmpty) return '';
    return '<div class="panthalassa-metadata">${lines.join()}</div>';
  }

  String _metadataValue(Object? value) {
    if (value == null) return '';
    if (value is String || value is num || value is bool) return '$value';
    if (value is Iterable) return value.map(_metadataValue).join(', ');
    if (value is Map) {
      return value.entries
          .map((e) => '${e.key}: ${_metadataValue(e.value)}')
          .join('; ');
    }
    return '$value';
  }

  String _visualBlock(String svg, VisualDocument? visual) {
    if (visual == null || visual.isEmpty || svg.isEmpty) return '';
    final pages = <String>[];
    for (final page in visual.pages) {
      final pageSvg = const SvgVisualRenderer().render(VisualDocument(
        sourceFormat: visual.sourceFormat,
        pages: [page],
        contentId: visual.contentId,
        metadata: visual.metadata,
      ));
      pages.add(
        '<div class="panthalassa-visual-page">'
        '<div class="panthalassa-visual-head">'
        '<span class="panthalassa-visual-index">Page '
        '${(page.geometry.pageIndex ?? pages.length + 1)}</span>'
        '<span class="panthalassa-visual-geom">'
        '${page.geometry.width.toInt()}×${page.geometry.height.toInt()}</span>'
        '</div>'
        '</div>'
        '$pageSvg'
        '</div>',
      );
    }
    return '<section class="panthalassa-visuals">${pages.join()}</section>';
  }

  String _escapeHtml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');

  static const _pageStyle = '''
* { box-sizing: border-box; }
body { font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, sans-serif; margin: 0; color: #1f2937; line-height: 1.5; }
.panthalassa-header { border-bottom: 1px solid #e5e7eb; padding: 12px 16px; background: #f9fafb; }
.panthalassa-title { font-size: 16px; font-weight: 600; }
.panthalassa-format { font-size: 12px; color: #6b7280; margin-top: 2px; }
.panthalassa-metadata { margin-top: 8px; font-size: 12px; color: #4b5563; }
.panthalassa-meta-row { display: flex; gap: 8px; margin: 2px 0; }
.panthalassa-meta-key { min-width: 110px; font-weight: 600; color: #374151; }
.panthalassa-body { padding: 16px; }
.panthalassa-visuals { margin-top: 24px; border-top: 1px solid #e5e7eb; padding-top: 16px; }
.panthalassa-visual-page { margin-bottom: 16px; border: 1px solid #e5e7eb; border-radius: 6px; overflow: hidden; background: #fff; }
.panthalassa-visual-head { display: flex; justify-content: space-between; padding: 6px 10px; background: #f3f4f6; font-size: 11px; color: #6b7280; border-bottom: 1px solid #e5e7eb; }
.panthalassa-visual-page svg { display: block; width: 100%; height: auto; max-height: 64vh; }
.panthalassa-footer { border-top: 1px solid #e5e7eb; padding: 10px 16px; font-size: 11px; color: #9ca3af; }
''';
}
