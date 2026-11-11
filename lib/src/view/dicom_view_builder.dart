import '../core/document_format.dart';
import '../core/parse_exception.dart';
import '../core/parse_result.dart';
import '../parsers/dicom/dicom_image.dart';
import '../parsers/dicom_parser.dart';
import 'viewer_document.dart';
import 'viewer_support.dart';

/// DICOM viewer: decode one frame (or a bounded frame set) to PNG and show it
/// with the study/series/image facts. Unsupported codecs degrade to a
/// metadata-only view with an explicit notice rather than a blank page.
final class DicomViewBuilder implements ViewBuilder {
  const DicomViewBuilder();

  /// Static HTML is a poor cine viewer; cap accidental `--all-frames` output.
  static const int maxRenderedFrames = 64;

  /// Total encoded PNG budget for `--all-frames`; prevents a multi-frame study
  /// from producing a multi-gigabyte HTML file.
  static const int maxRenderedBytes = 96 * 1024 * 1024;

  @override
  String get id => 'dicom';

  @override
  bool supports(ParseResult result) => result.format == DocumentFormat.dicom;

  @override
  ViewerDocument build(ViewerRequest request) {
    final result = request.result;
    final options = request.options;
    final title = options.title ?? viewerBasename(request.filename);
    final notices = <ViewerNotice>[
      for (final warning
          in result.warnings
              .where((warning) => warning.code != 'dicom.encapsulated')
              .take(8))
        ViewerNotice(
          '${warning.code}: ${warning.message}',
          level: ViewerNoticeLevel.warning,
        ),
    ];
    final facts = _facts(request, null);
    final sections = <ViewerSection>[];
    final assets = <String, ViewerAsset>{};

    DicomImageData? image;
    try {
      image = const DicomParser().readImage(request.bytes);
    } on ParseException catch (error) {
      notices.add(
        ViewerNotice(
          'Pixel data could not be extracted: ${error.message}',
          level: ViewerNoticeLevel.error,
        ),
      );
    }

    if (image == null) {
      _appendStructuredSections(result, options, sections);
      final hasContent = sections.isNotEmpty;
      notices.add(
        ViewerNotice(
          result.metadata['hasPixelData'] == true
              ? 'This DICOM instance declares Pixel Data, but no decodable '
                    'payload was available. Showing '
                    '${hasContent ? 'extracted content and metadata' : 'metadata only'}.'
              : 'This DICOM instance has no Pixel Data element. Showing '
                    '${hasContent ? 'extracted content and metadata' : 'metadata only'}.',
          level: ViewerNoticeLevel.warning,
        ),
      );
      return ViewerDocument(
        title: title,
        formatLabel: result.format.label,
        subtitle: _subtitle(result),
        facts: facts,
        sections: sections,
        notices: notices,
        footer: 'Panthalassa DICOM viewer',
      );
    }

    final imageFacts = _facts(request, image);
    final frames = _framesToRender(image, options, notices);
    final decoder = const DicomPixelDecoder();
    var renderedBytes = 0;
    for (final frame in frames) {
      try {
        final decoded = decoder.decode(
          image,
          frame: frame,
          windowCenter: options.windowCenter,
          windowWidth: options.windowWidth,
          invert: options.invert,
        );
        final png = decoded.encodePng();
        if (renderedBytes + png.length > maxRenderedBytes) {
          notices.add(
            ViewerNotice(
              'Stopped after ${assets.length} frame(s) to keep the viewer '
              'under ${formatViewerBytes(maxRenderedBytes)}. Use --frame N '
              'to view another frame.',
              level: ViewerNoticeLevel.warning,
            ),
          );
          break;
        }
        renderedBytes += png.length;
        final assetName = 'frame-$frame.png';
        assets[assetName] = ViewerAsset(
          name: assetName,
          mimeType: 'image/png',
          bytes: png,
        );
        final frameTitle = image.frameCount > 1
            ? 'Frame ${frame + 1} of ${image.frameCount}'
            : 'Image';
        sections.add(
          ViewerImageSection(
            title: frameTitle,
            assetName: assetName,
            alt: 'DICOM frame ${frame + 1}',
            width: decoded.width,
            height: decoded.height,
            caption: _frameCaption(decoded),
          ),
        );
      } on ParseException catch (error) {
        notices.add(
          ViewerNotice(
            'Frame ${frame + 1} could not be rendered: ${error.message}',
            level: ViewerNoticeLevel.error,
          ),
        );
        break;
      }
    }

    _appendStructuredSections(result, options, sections);

    if (sections.isEmpty) {
      notices.add(
        const ViewerNotice(
          'No pixel frame could be decoded. The metadata below is still '
          'available.',
          level: ViewerNoticeLevel.warning,
        ),
      );
    }

    return ViewerDocument(
      title: title,
      formatLabel: result.format.label,
      subtitle: _subtitle(result),
      facts: imageFacts,
      sections: sections,
      assets: assets,
      notices: notices,
      footer: 'Panthalassa DICOM viewer',
    );
  }

  void _appendStructuredSections(
    ParseResult result,
    ViewerOptions options,
    List<ViewerSection> sections,
  ) {
    final text = result.text?.trim();
    if (text != null && text.isNotEmpty) {
      sections.add(ViewerTextSection(title: 'Report text', text: text));
    }
    for (var i = 0; i < result.tables.length; i++) {
      sections.add(
        viewerTableSection(
          result.tables[i],
          options,
          fallbackTitle: 'Table ${i + 1}',
        ),
      );
    }
  }

  List<int> _framesToRender(
    DicomImageData image,
    ViewerOptions options,
    List<ViewerNotice> notices,
  ) {
    if (!options.allFrames) {
      if (options.frame < 0 || options.frame >= image.frameCount) {
        throw MalformedDocumentException(
          'requested DICOM frame ${options.frame + 1} but only '
          '${image.frameCount} frame(s) are available',
        );
      }
      return [options.frame];
    }
    final count = image.frameCount;
    if (count > maxRenderedFrames) {
      notices.add(
        ViewerNotice(
          'Rendering the first $maxRenderedFrames of $count frames. Use '
          '--frame N to select a specific frame.',
          level: ViewerNoticeLevel.warning,
        ),
      );
    }
    return [for (var i = 0; i < count && i < maxRenderedFrames; i++) i];
  }

  String _frameCaption(DicomDecodedFrame frame) {
    final parts = <String>[
      '${frame.width} × ${frame.height} px',
      frame.photometricInterpretation,
    ];
    if (frame.windowCenter != null && frame.windowWidth != null) {
      parts.add(
        'W/L ${frame.windowCenter!.toStringAsFixed(1)}/'
        '${frame.windowWidth!.toStringAsFixed(1)}',
      );
    }
    if (frame.inverted) parts.add('inverted');
    return parts.join(' · ');
  }

  String _subtitle(ParseResult result) {
    final modality = viewerString(result.metadata['modality']);
    final description =
        viewerString(result.metadata['seriesDescription']) ??
        viewerString(result.metadata['studyDescription']);
    if (modality == null && description == null) {
      return result.format.label;
    }
    return [?modality, ?description].join(' · ');
  }

  Map<String, String> _facts(ViewerRequest request, DicomImageData? image) {
    final result = request.result;
    final metadata = result.metadata;
    final facts = <String, String>{};
    void add(String label, Object? value) {
      final text = viewerValue(value);
      if (text.isNotEmpty) facts[label] = text;
    }

    final patient = viewerString(metadata['patientName']);
    if (patient != null) add('Patient', _personName(patient));
    add('Patient ID', metadata['patientId']);
    add('Modality', metadata['modality']);
    add('Study', metadata['studyDescription']);
    add('Study date', metadata['studyDate']);
    add('Series', metadata['seriesDescription']);
    add('Institution', metadata['institutionName']);
    if (image != null) {
      add('Dimensions', '${image.columns} × ${image.rows}');
      add('Frames', image.frameCount);
      add(
        'Bits',
        '${image.bitsStored} stored / ${image.bitsAllocated} allocated',
      );
      add('Photometric', image.photometricInterpretation);
      add('Pixel spacing', image.pixelSpacing);
      add(
        'Transfer syntax',
        image.transferSyntaxName ?? image.transferSyntaxUid,
      );
      if (image.rescaleSlope != 1 || image.rescaleIntercept != 0) {
        add(
          'Rescale',
          'slope ${image.rescaleSlope}, intercept ${image.rescaleIntercept}',
        );
      }
      if (image.windowCenter != null || image.windowWidth != null) {
        add(
          'Window',
          'C ${image.windowCenter ?? 'auto'} / W ${image.windowWidth ?? 'auto'}',
        );
      }
    } else {
      add(
        'Dimensions',
        '${metadata['columns'] ?? '?'} × ${metadata['rows'] ?? '?'}',
      );
      add('Frames', metadata['numberOfFrames']);
      add('Photometric', metadata['photometricInterpretation']);
      add(
        'Transfer syntax',
        metadata['transferSyntaxName'] ?? metadata['transferSyntax'],
      );
    }
    add('Size', formatViewerBytes(request.bytes.length));
    add('Document ID', result.documentId);
    return facts;
  }

  String _personName(String value) {
    final parts = value.split('^');
    if (parts.length >= 2 && parts[0].isNotEmpty && parts[1].isNotEmpty) {
      return '${parts[0]}, ${parts[1]}';
    }
    return value;
  }
}
