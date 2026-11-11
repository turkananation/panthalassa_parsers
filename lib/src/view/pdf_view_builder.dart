import '../core/document_format.dart';
import '../core/parse_result.dart';
import 'viewer_document.dart';
import 'viewer_support.dart';

/// PDF viewer that embeds the original file for the browser's native renderer
/// and keeps the extracted text available for search/copy.
///
/// Encrypted PDFs are not embedded because the browser would prompt for a
/// password the parser does not retain; their extracted text is shown instead.
final class PdfViewBuilder implements ViewBuilder {
  const PdfViewBuilder();

  @override
  String get id => 'pdf';

  @override
  bool supports(ParseResult result) => result.format == DocumentFormat.pdf;

  @override
  ViewerDocument build(ViewerRequest request) {
    final result = request.result;
    final title = request.options.title ?? viewerBasename(request.filename);
    final metadata = result.metadata;
    final documentTitle = viewerString(metadata['title']);
    final author = viewerString(metadata['author']);
    final pages = viewerInt(metadata['pageCount']);
    final encrypted = metadata['encrypted'] == true;
    final sections = <ViewerSection>[];
    final assets = <String, ViewerAsset>{};
    final notices = <ViewerNotice>[
      for (final warning in result.warnings.take(8))
        ViewerNotice(
          '${warning.code}: ${warning.message}',
          level: ViewerNoticeLevel.warning,
        ),
    ];

    if (encrypted) {
      notices.add(
        const ViewerNotice(
          'This PDF is encrypted. The browser cannot preview it without the '
          'password, so the extracted text is shown instead.',
          level: ViewerNoticeLevel.warning,
        ),
      );
    } else {
      const assetName = 'document.pdf';
      assets[assetName] = ViewerAsset(
        name: assetName,
        mimeType: 'application/pdf',
        bytes: request.bytes,
      );
      sections.add(
        ViewerEmbedSection(
          title: 'Document',
          assetName: assetName,
          downloadName: viewerBasename(request.filename),
        ),
      );
    }

    final text = result.text?.trim();
    if (text != null && text.isNotEmpty) {
      sections.add(
        ViewerTextSection(title: 'Extracted text', text: text, monospace: true),
      );
    }

    if (sections.isEmpty) {
      notices.add(
        const ViewerNotice(
          'This PDF produced no previewable content.',
          level: ViewerNoticeLevel.warning,
        ),
      );
    }

    final subtitleParts = <String>[
      ?documentTitle,
      if (pages != null) '$pages page${pages == 1 ? '' : 's'}',
      ?author,
    ];
    return ViewerDocument(
      title: title,
      formatLabel: result.format.label,
      subtitle: subtitleParts.isEmpty
          ? result.format.label
          : subtitleParts.join(' · '),
      facts: {
        'Title': ?documentTitle,
        'Author': ?author,
        if (pages != null) 'Pages': '$pages',
        if (encrypted) 'Encrypted': 'yes',
        if (metadata['pdfA3'] == true) 'PDF/A-3': 'yes',
        if (result.attachments.isNotEmpty)
          'Attachments': '${result.attachments.length}',
        if (result.outline.isNotEmpty) 'Outline': '${result.outline.length}',
        'Size': formatViewerBytes(request.bytes.length),
        'Document ID': result.documentId,
      },
      sections: sections,
      assets: assets,
      notices: notices,
      footer: 'Panthalassa PDF viewer',
    );
  }
}
