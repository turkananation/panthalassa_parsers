import '../core/parse_result.dart';
import '../render/document_ir.dart';
import '../render/document_renderer.dart';
import 'viewer_document.dart';
import 'viewer_support.dart';

/// Fallback viewer for every format without a dedicated pixel/table builder.
///
/// It reuses the semantic DIR and existing escaped-HTML renderer, so new
/// parsers become viewable without adding another renderer.
final class DocumentViewBuilder implements ViewBuilder {
  const DocumentViewBuilder();

  @override
  String get id => 'document';

  @override
  bool supports(ParseResult result) => false;

  @override
  ViewerDocument build(ViewerRequest request) {
    final result = request.result;
    final ir = DocumentIr.fromParseResult(result);
    final html = const HtmlDocumentRenderer().render(
      ir,
      options: const RenderOptions(),
    );
    final notices = viewerWarnings(result);

    return ViewerDocument(
      title: viewerTitle(request),
      formatLabel: result.format.label,
      subtitle: result.format.category.name,
      facts: {
        ...viewerBaseFacts(request),
        'Format': result.format.label,
        if (ir.body.isNotEmpty) 'Sections': '${ir.body.length}',
        if (result.tables.isNotEmpty) 'Tables': '${result.tables.length}',
        if (result.outline.isNotEmpty) 'Outline': '${result.outline.length}',
        if (result.attachments.isNotEmpty)
          'Attachments': '${result.attachments.length}',
      },
      sections: [ViewerHtmlSection(html: html)],
      notices: notices,
      footer: 'Panthalassa document viewer',
    );
  }
}
