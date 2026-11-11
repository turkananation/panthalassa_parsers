import 'dart:convert';
import 'dart:typed_data';

import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_exception.dart';
import '../core/parse_options.dart';
import '../core/parse_result.dart';
import '../core/structured_artifacts.dart';
import 'pdf/pdf_internals.dart';
import 'pdf/pdf_metadata.dart';
import 'pdf/pdf_text.dart';
import 'pdf/pdf_visual.dart';

/// Public parser for PDF documents.
///
/// Extracts per-page text — decrypting RC4/AES-protected documents, decoding
/// object and cross-reference streams, resolving font encodings and ToUnicode
/// maps, and recursing into form XObjects — plus document metadata, permission
/// flags, XMP, outlines, form fields, annotations, signature envelopes,
/// page labels, embedded files, and encoded image XObjects.
final class PdfParser implements DocumentParser, OptionAwareDocumentParser {
  const PdfParser();

  @override
  DocumentFormat get format => DocumentFormat.pdf;

  String get parserVersion => parserImplementationVersion;

  @override
  bool canParse(Uint8List bytes) {
    // The %PDF- marker must appear at or very near the start (the spec allows a
    // small amount of leading garbage, so scan the first 1 KiB).
    final limit = bytes.length < 1024 ? bytes.length : 1024;
    final head = latin1.decode(
      Uint8List.sublistView(bytes, 0, limit),
      allowInvalid: true,
    );
    return head.contains('%PDF-');
  }

  @override
  ParseResult parse(Uint8List bytes, {required ContentHasher hasher}) =>
      parseWithOptions(bytes, hasher: hasher);

  @override
  ParseResult parseWithOptions(
    Uint8List bytes, {
    required ContentHasher hasher,
    ParseOptions options = const ParseOptions(),
    DocumentHints? hints,
  }) {
    final digest = hasher.digestFor(bytes);
    final PdfDocument doc;
    try {
      doc = PdfDocument.parse(
        bytes,
        maxDecompressedEntryBytes: options.limits.maxDecompressedEntryBytes,
      );
    } on ParseException {
      rethrow;
    } catch (_) {
      throw const MalformedDocumentException('failed to parse PDF structure');
    }

    final warnings = <ParseWarning>[];
    if (options.rejectEncrypted && doc.isEncrypted) {
      throw const UnsupportedFeatureException(
        'encrypted PDF rejected by parse options',
      );
    }

    var pages = doc.pages();
    if (pages.length > options.limits.maxPages) {
      warnings.add(
        ParseWarning(
          'pdf.page_limit',
          'page count exceeded ${options.limits.maxPages}; later pages skipped',
        ),
      );
      pages = pages.sublist(0, options.limits.maxPages);
    }

    final pageTexts = <String>[];
    for (final page in pages) {
      try {
        pageTexts.add(ContentTextExtractor.extractPage(doc, page));
      } catch (_) {
        warnings.add(
          const ParseWarning(
            'pdf.page_extract_failed',
            'a page could not be extracted',
          ),
        );
        pageTexts.add('');
      }
    }

    final pageText = pageTexts.join('\n\f\n').trim();
    if (pages.isNotEmpty && pageText.isEmpty) {
      warnings.add(
        const ParseWarning(
          'pdf.no_text_extracted',
          'pages found but no text recovered; the document may use a scanned '
              'image layer or CID fonts without ToUnicode',
        ),
      );
    }

    final extraction = PdfMetadataExtractor(
      doc,
      hasher,
      options,
      fileLength: bytes.length,
      pages: pages,
    ).extract();
    warnings.addAll(extraction.warnings);

    final embeddedText = extraction.attachments
        .map((a) => a.text?.trim() ?? '')
        .where((t) => t.isNotEmpty)
        .join('\n\f\n')
        .trim();
    final text = embeddedText.isEmpty
        ? pageText
        : (pageText.isEmpty ? embeddedText : '$pageText\n\f\n$embeddedText');

    final info = doc.info;
    String? infoString(String key) {
      final v = doc.resolve(info?[key]);
      return v is PdfString ? v.latin1Value.trim() : null;
    }

    final encryptDict = doc.resolve(doc.trailer?['Encrypt']);
    final permissionsValue = encryptDict is PdfDict
        ? doc.resolve(encryptDict['P'])
        : null;
    final permissions = permissionsValue is PdfNumber
        ? _permissionFlags(permissionsValue.value.toInt())
        : null;
    final visualPages = options.includeVisual
        ? PdfVisualExtractor.extract(doc, pages)
        : const <Map<String, Object?>>[];

    final metadata = <String, Object?>{
      'pdfVersion': doc.version,
      'pageCount': pages.length,
      if (visualPages.isNotEmpty) 'visualPages': visualPages,
      ...extraction.metadata,
    };
    void putIfAbsent(String key, String infoKey) {
      final v = infoString(infoKey);
      if (v != null && v.isNotEmpty) metadata.putIfAbsent(key, () => v);
    }

    putIfAbsent('title', 'Title');
    putIfAbsent('author', 'Author');
    putIfAbsent('subject', 'Subject');
    putIfAbsent('keywords', 'Keywords');
    putIfAbsent('producer', 'Producer');
    putIfAbsent('creator', 'Creator');
    putIfAbsent('creationDate', 'CreationDate');
    putIfAbsent('modDate', 'ModDate');
    if (doc.encryptionLabel != null) {
      metadata['encrypted'] = true;
      metadata['encryption'] = doc.encryptionLabel;
    }
    if (permissions != null) metadata['permissions'] = permissions;

    final embeddedFiles = [
      for (final a in extraction.attachments)
        if (a.path.length <= 1)
          {
            'name': ?a.name,
            if (a.size != null) 'size': a.size,
            if (a.relationship != null) 'relationship': a.relationship,
            if (a.mediaType != null) 'mediaType': a.mediaType,
          },
    ];
    if (embeddedFiles.isNotEmpty) {
      metadata['embeddedFileCount'] = embeddedFiles.length;
      metadata['embeddedFiles'] = embeddedFiles;
    }
    final hasAF = doc.resolve(doc.catalog?['AF']) is PdfArray;
    if (hasAF) metadata['pdfA3'] = true;

    return ParseResult(
      documentId: digest.sha256,
      digest: digest,
      format: format,
      byteLength: bytes.length,
      metadata: metadata,
      text: text.isEmpty ? null : text,
      warnings: warnings,
      structuredText: options.includeStructuredText
          ? _structuredText(doc, pages, visualPages, pageTexts, metadata)
          : null,
      outline: extraction.outline,
      attachments: extraction.attachments,
      signatures: extraction.signatures,
      parserVersion: parserVersion,
    );
  }

  /// Builds page-aware text from the visual display list when available, or
  /// from the flat page text otherwise.
  StructuredText _structuredText(
    PdfDocument doc,
    List<PdfDict> pages,
    List<Map<String, Object?>> visualPages,
    List<String> pageTexts,
    Map<String, Object?> metadata,
  ) {
    final labels = metadata['pageLabels'];
    final out = <TextPage>[];
    for (var i = 0; i < pages.length; i++) {
      final visual = i < visualPages.length ? visualPages[i] : null;
      final width = visual?['width'];
      final height = visual?['height'];
      final blocks = <TextBlock>[];
      final commands = visual?['commands'];
      if (commands is List) {
        for (final command in commands) {
          if (command is! Map || command['type'] != 'text') continue;
          final value = command['text'];
          if (value is! String || value.trim().isEmpty) continue;
          final x = _double(command['x']) ?? 0;
          final y = _double(command['y']) ?? 0;
          final size = _double(command['fontSize']) ?? 10;
          blocks.add(
            TextBlock(
              spans: [TextSpan(value)],
              bounds: TextBounds(
                left: x,
                top: y,
                right: x + value.runes.length * size * 0.5,
                bottom: y + size,
              ),
              style: 'text',
            ),
          );
        }
      }
      if (blocks.isEmpty) {
        final pageText = i < pageTexts.length ? pageTexts[i].trim() : '';
        if (pageText.isNotEmpty) {
          blocks.add(
            TextBlock(spans: [TextSpan(pageText)], style: 'paragraph'),
          );
        }
      }
      out.add(
        TextPage(
          index: i,
          width: _double(width),
          height: _double(height),
          blocks: blocks,
          coordinateSpace: TextCoordinateSpace.pdfUserSpace,
          label: labels is Map ? labels['$i'] as String? : null,
        ),
      );
    }
    return StructuredText(out);
  }

  static double? _double(Object? value) =>
      value is num ? value.toDouble() : double.tryParse('$value');

  /// Decodes the Standard security handler permission bits (PDF 7.6.3.2).
  Map<String, bool> _permissionFlags(int p) => {
    'print': p & (1 << 2) != 0,
    'modify': p & (1 << 3) != 0,
    'copy': p & (1 << 4) != 0,
    'annotate': p & (1 << 5) != 0,
    'fillForms': p & (1 << 8) != 0,
    'extractAccessibility': p & (1 << 9) != 0,
    'assemble': p & (1 << 10) != 0,
    'printHighRes': p & (1 << 11) != 0,
  };
}
