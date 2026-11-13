import '../core/document_format.dart';
import '../core/parse_result.dart';
import 'viewer_document.dart';
import 'viewer_support.dart';

/// Raster/SVG image viewer that embeds the original bytes for browser-native
/// display and lists the parsed container/EXIF metadata.
///
/// Images are not decoded in Dart. JPEG, PNG, GIF, WebP, and SVG are safe for an
/// `<img>` element; SVG scripts and external references stay inert in that
/// context. TIFF is metadata-only because browser support is inconsistent.
final class ImageViewBuilder implements ViewBuilder {
  const ImageViewBuilder();

  static const int maxEmbeddedBytes = 64 * 1024 * 1024;

  static const Set<String> _previewMimeTypes = {
    'image/jpeg',
    'image/png',
    'image/gif',
    'image/webp',
    'image/svg+xml',
  };

  @override
  String get id => 'image';

  @override
  bool supports(ParseResult result) => result.format == DocumentFormat.image;

  @override
  ViewerDocument build(ViewerRequest request) {
    final result = request.result;
    final title = viewerTitle(request);
    final family =
        viewerString(result.metadata['formatFamily']) ?? result.format.label;
    final mediaType = viewerString(result.metadata['mediaType']);
    final width = viewerInt(result.metadata['width']);
    final height = viewerInt(result.metadata['height']);
    final sections = <ViewerSection>[];
    final assets = <String, ViewerAsset>{};
    final notices = viewerWarnings(result);

    final previewType =
        mediaType != null && _previewMimeTypes.contains(mediaType)
        ? mediaType
        : null;
    if (previewType != null && request.bytes.length <= maxEmbeddedBytes) {
      final assetName = 'image.${_extension(previewType)}';
      assets[assetName] = ViewerAsset(
        name: assetName,
        mimeType: previewType,
        bytes: request.bytes,
      );
      sections.add(
        ViewerImageSection(
          title: 'Image',
          assetName: assetName,
          alt: title,
          width: width,
          height: height,
          caption: '$family · ${formatViewerBytes(request.bytes.length)}',
        ),
      );
      if (previewType == 'image/svg+xml') {
        notices.add(
          const ViewerNotice(
            'SVG is displayed as a static image; scripts and external '
            'references are not executed.',
          ),
        );
      }
    } else if (previewType != null) {
      notices.add(
        ViewerNotice(
          'Image is larger than ${formatViewerBytes(maxEmbeddedBytes)}; '
          'showing metadata instead.',
          level: ViewerNoticeLevel.warning,
        ),
      );
    } else if (mediaType == 'image/tiff') {
      notices.add(
        const ViewerNotice(
          'TIFF preview is not embedded because browser support is '
          'inconsistent. Showing metadata instead.',
          level: ViewerNoticeLevel.warning,
        ),
      );
    } else {
      notices.add(
        const ViewerNotice(
          'This image type cannot be previewed in a browser. Showing metadata '
          'instead.',
          level: ViewerNoticeLevel.warning,
        ),
      );
    }

    final metadataRows = viewerMetadataRows(result.metadata);
    if (metadataRows.isNotEmpty) {
      sections.add(
        ViewerTableSection(
          title: 'Metadata',
          columns: const ['Field', 'Value'],
          rows: metadataRows,
          filterable: true,
        ),
      );
    }
    if (sections.isEmpty) {
      sections.add(
        ViewerTextSection(
          title: 'Extracted text',
          text: result.text ?? 'The parser produced no previewable data.',
        ),
      );
    }

    final dimensions = width != null && height != null
        ? '$width × $height px'
        : null;
    return ViewerDocument(
      title: title,
      formatLabel: family,
      subtitle: [?dimensions, family].join(' · '),
      facts: {
        ...viewerBaseFacts(request),
        'Format': family,
        'Media type': ?mediaType,
        'Dimensions': ?dimensions,
      },
      sections: sections,
      assets: assets,
      notices: notices,
      footer: 'Panthalassa image viewer',
    );
  }

  String _extension(String mimeType) => switch (mimeType) {
    'image/jpeg' => 'jpg',
    'image/png' => 'png',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    'image/svg+xml' => 'svg',
    _ => 'img',
  };
}
