import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../core/byte_reader.dart';
import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_exception.dart';
import '../core/parse_options.dart';
import '../core/parse_result.dart';
import '../core/structured_artifacts.dart';
import 'cda_parser.dart';
import 'dicom/dicom_image.dart';
import 'dicom_sr.dart';
import 'pdf_parser.dart';

/// Parser for DICOM Part 10 files (PS3.10).
///
/// Reads the 128-byte preamble and `DICM` magic, parses the File Meta
/// Information group as Explicit VR Little Endian, then walks the main dataset
/// under the indicated transfer syntax. It descends into SQ values, including
/// undefined-length item/delimitation records, and stops before Pixel Data.
final class DicomParser implements DocumentParser, OptionAwareDocumentParser {
  const DicomParser();

  static const _preambleLength = 128;
  static const _pixelDataTag = 0x7FE00010;
  static const _itemTag = 0xFFFEE000;
  static const _itemDelimitationTag = 0xFFFEE00D;
  static const _sequenceDelimitationTag = 0xFFFEE0DD;

  static const _implicitVrLe = '1.2.840.10008.1.2';
  static const _explicitVrLe = '1.2.840.10008.1.2.1';
  static const _explicitVrBe = '1.2.840.10008.1.2.2';
  static const _deflatedExplicitVrLe = '1.2.840.10008.1.2.1.99';

  static const _transferSyntaxNames = {
    _implicitVrLe: 'Implicit VR Little Endian',
    _explicitVrLe: 'Explicit VR Little Endian',
    _explicitVrBe: 'Explicit VR Big Endian',
    '1.2.840.10008.1.2.1.99': 'Deflated Explicit VR Little Endian',
    '1.2.840.10008.1.2.4.50': 'JPEG Baseline',
    '1.2.840.10008.1.2.4.70': 'JPEG Lossless',
    '1.2.840.10008.1.2.4.80': 'JPEG-LS Lossless',
    '1.2.840.10008.1.2.4.90': 'JPEG 2000 Lossless',
    '1.2.840.10008.1.2.5': 'RLE Lossless',
  };

  static const _stringVrs = {
    'AE',
    'AS',
    'CS',
    'DA',
    'DS',
    'DT',
    'IS',
    'LO',
    'LT',
    'PN',
    'SH',
    'ST',
    'TM',
    'UC',
    'UI',
    'UR',
    'UT',
  };

  static const _longFormVrs = {
    'OB',
    'OW',
    'OF',
    'OD',
    'OL',
    'OV',
    'SQ',
    'SV',
    'UC',
    'UN',
    'UR',
    'UT',
    'UV',
  };

  /// Tag dictionary for common metadata, sequence traversal, and rendering.
  ///
  /// This covers the standard patient/study/series/image keys most callers need
  /// plus high-value SQ tags. Unknown tags are still surfaced in the `attributes`
  /// list by numeric tag.
  static const _dictionary = <int, ({String key, String vr})>{
    0x00020010: (key: 'transferSyntaxUid', vr: 'UI'),
    0x00080005: (key: 'specificCharacterSet', vr: 'CS'),
    0x00080008: (key: 'imageType', vr: 'CS'),
    0x00080016: (key: 'sopClassUid', vr: 'UI'),
    0x00080018: (key: 'sopInstanceUid', vr: 'UI'),
    0x00080020: (key: 'studyDate', vr: 'DA'),
    0x00080030: (key: 'studyTime', vr: 'TM'),
    0x00080050: (key: 'accessionNumber', vr: 'SH'),
    0x00080060: (key: 'modality', vr: 'CS'),
    0x00080070: (key: 'manufacturer', vr: 'LO'),
    0x00080080: (key: 'institutionName', vr: 'LO'),
    0x00080090: (key: 'referringPhysician', vr: 'PN'),
    0x00081115: (key: 'referencedSeriesSequence', vr: 'SQ'),
    0x00081140: (key: 'referencedImageSequence', vr: 'SQ'),
    0x00082112: (key: 'sourceImageSequence', vr: 'SQ'),
    0x00081030: (key: 'studyDescription', vr: 'LO'),
    0x0008103E: (key: 'seriesDescription', vr: 'LO'),
    0x00100010: (key: 'patientName', vr: 'PN'),
    0x00100020: (key: 'patientId', vr: 'LO'),
    0x00100030: (key: 'patientBirthDate', vr: 'DA'),
    0x00100040: (key: 'patientSex', vr: 'CS'),
    0x00101010: (key: 'patientAge', vr: 'AS'),
    0x0020000D: (key: 'studyInstanceUid', vr: 'UI'),
    0x0020000E: (key: 'seriesInstanceUid', vr: 'UI'),
    0x00200011: (key: 'seriesNumber', vr: 'IS'),
    0x00200013: (key: 'instanceNumber', vr: 'IS'),
    0x00280002: (key: 'samplesPerPixel', vr: 'US'),
    0x00280004: (key: 'photometricInterpretation', vr: 'CS'),
    0x00280006: (key: 'planarConfiguration', vr: 'US'),
    0x00280008: (key: 'numberOfFrames', vr: 'IS'),
    0x00280009: (key: 'frameIncrementPointer', vr: 'AT'),
    0x00280010: (key: 'rows', vr: 'US'),
    0x00280011: (key: 'columns', vr: 'US'),
    0x00280030: (key: 'pixelSpacing', vr: 'DS'),
    0x00280034: (key: 'pixelAspectRatio', vr: 'IS'),
    0x00280100: (key: 'bitsAllocated', vr: 'US'),
    0x00280101: (key: 'bitsStored', vr: 'US'),
    0x00280102: (key: 'highBit', vr: 'US'),
    0x00280103: (key: 'pixelRepresentation', vr: 'US'),
    0x00280106: (key: 'smallestImagePixelValue', vr: 'US'),
    0x00280107: (key: 'largestImagePixelValue', vr: 'US'),
    0x00280120: (key: 'pixelPaddingValue', vr: 'US'),
    0x00280121: (key: 'pixelPaddingRangeLimit', vr: 'US'),
    0x00281050: (key: 'windowCenter', vr: 'DS'),
    0x00281051: (key: 'windowWidth', vr: 'DS'),
    0x00281052: (key: 'rescaleIntercept', vr: 'DS'),
    0x00281053: (key: 'rescaleSlope', vr: 'DS'),
    0x00281054: (key: 'rescaleType', vr: 'LO'),
    0x00281056: (key: 'voiLutFunction', vr: 'CS'),
    0x00281101: (key: 'redPaletteColorLookupTableDescriptor', vr: 'US'),
    0x00281102: (key: 'greenPaletteColorLookupTableDescriptor', vr: 'US'),
    0x00281103: (key: 'bluePaletteColorLookupTableDescriptor', vr: 'US'),
    0x00281201: (key: 'redPaletteColorLookupTableData', vr: 'OW'),
    0x00281202: (key: 'greenPaletteColorLookupTableData', vr: 'OW'),
    0x00281203: (key: 'bluePaletteColorLookupTableData', vr: 'OW'),
    0x7FE00010: (key: 'pixelData', vr: 'OW'),
    0x00400010: (key: 'documentTitle', vr: 'ST'),
    0x00400011: (key: 'encapsulatedDocument', vr: 'OB'),
    0x00400012: (key: 'mimeTypeOfEncapsulatedDocument', vr: 'LO'),
    0x0040A010: (key: 'relationshipType', vr: 'CS'),
    0x0040A040: (key: 'valueType', vr: 'CS'),
    0x0040A043: (key: 'conceptNameCodeSequence', vr: 'SQ'),
    0x0040A120: (key: 'dateTime', vr: 'DT'),
    0x0040A123: (key: 'personName', vr: 'PN'),
    0x0040A124: (key: 'uid', vr: 'UI'),
    0x0040A160: (key: 'textValue', vr: 'UT'),
    0x0040A168: (key: 'conceptCodeSequence', vr: 'SQ'),
    0x0040A30A: (key: 'numericValue', vr: 'DS'),
    0x0040A375: (key: 'referencedInstanceSequence', vr: 'SQ'),
    0x0040A504: (key: 'contentTemplateSequence', vr: 'SQ'),
    0x0040A730: (key: 'contentSequence', vr: 'SQ'),
    0x004008EA: (key: 'measurementUnitsCodeSequence', vr: 'SQ'),
    0x00080100: (key: 'codeValue', vr: 'SH'),
    0x00080102: (key: 'codingSchemeDesignator', vr: 'SH'),
    0x00080104: (key: 'codeMeaning', vr: 'LO'),
  };

  /// Public read-only view of the common-tag dictionary for sibling parsers
  /// (DICOM JSON) and downstream rendering.
  static const Map<int, ({String key, String vr})> tagDictionary = _dictionary;

  @override
  DocumentFormat get format => DocumentFormat.dicom;

  @override
  bool canParse(Uint8List bytes) {
    if (bytes.length < _preambleLength + 4) return false;
    return bytes[_preambleLength] == 0x44 &&
        bytes[_preambleLength + 1] == 0x49 &&
        bytes[_preambleLength + 2] == 0x43 &&
        bytes[_preambleLength + 3] == 0x4D;
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
    final warnings = <ParseWarning>[];
    final file = _readFile(
      bytes,
      limits: options.limits,
      warnings: warnings,
      capturePixelData: false,
    );
    final dataset = file.dataset;

    // Honor SpecificCharacterSet (0008,0005): surface the declared repertoire
    // so callers decode multi-valued strings correctly. Defaults to ISO_IR 6
    // (ASCII) where the tag is absent. Parsers never silently substitute
    // replacement characters for non-ASCII bytes.
    final specificCharSet = dataset.metadata['specificCharacterSet'];
    final charset = _firstString(specificCharSet);
    dataset.metadata['characterSet'] = charset ?? 'ISO_IR 6';

    final structuredReport = extractDicomStructuredReport(
      dataset.attributes,
      options,
      warnings,
    );
    final attachments = _encapsulatedAttachments(
      dataset,
      hasher,
      options,
      warnings,
    );
    if (structuredReport != null) {
      dataset.metadata['hasStructuredReport'] = true;
      dataset.metadata['structuredReport'] = structuredReport.tree;
    }
    if (attachments.isNotEmpty) {
      dataset.metadata['attachmentCount'] = attachments.length;
    }

    return ParseResult(
      documentId: digest.sha256,
      digest: digest,
      format: format,
      byteLength: bytes.length,
      metadata: {
        'transferSyntax': file.transferSyntax,
        if (_transferSyntaxNames[file.transferSyntax] != null)
          'transferSyntaxName': _transferSyntaxNames[file.transferSyntax],
        'explicitVr': file.explicitVr,
        'metaElements': file.metaElements,
        'datasetElements': dataset.elementCount,
        'hasPixelData': dataset.hasPixelData,
        ...file.meta,
        ...dataset.metadata,
        'attributes': dataset.attributes,
      },
      text: structuredReport?.text,
      warnings: warnings,
      structuredText: options.includeStructuredText && structuredReport != null
          ? StructuredText([
              TextPage(index: 0, blocks: structuredReport.blocks),
            ])
          : null,
      outline: options.includeOutline
          ? structuredReport?.outline ?? const []
          : const [],
      tables: options.includeTables
          ? structuredReport?.tables ?? const []
          : const [],
      attachments: attachments,
      parserVersion: parserImplementationVersion,
    );
  }

  /// Extracts the first image frame's parameters and native/encapsulated pixel
  /// payload for rendering. Returns `null` when the instance has no Pixel Data.
  ///
  /// This path is separate from [parseWithOptions] so ordinary metadata parsing
  /// remains fast and never retains a potentially large pixel buffer.
  DicomImageData? readImage(
    Uint8List bytes, {
    ParseLimits limits = ParseLimits.standard,
  }) {
    final file = _readFile(
      bytes,
      limits: limits,
      warnings: <ParseWarning>[],
      capturePixelData: true,
    );
    final dataset = file.dataset;
    if (!dataset.hasPixelData) return null;

    final rows = _asInt(dataset.metadata['rows']);
    final columns = _asInt(dataset.metadata['columns']);
    if (rows == null || columns == null || rows <= 0 || columns <= 0) {
      throw const MalformedDocumentException(
        'DICOM image is missing valid Rows or Columns',
      );
    }
    final bitsAllocated = _asInt(dataset.metadata['bitsAllocated']) ?? 8;
    final bitsStored = _asInt(dataset.metadata['bitsStored']) ?? bitsAllocated;
    final highBit = _asInt(dataset.metadata['highBit']) ?? bitsStored - 1;
    final samplesPerPixel = _asInt(dataset.metadata['samplesPerPixel']) ?? 1;
    final numberOfFrames = _asInt(dataset.metadata['numberOfFrames']) ?? 1;
    final photometric =
        _firstString(dataset.metadata['photometricInterpretation']) ??
        (samplesPerPixel == 1 ? 'MONOCHROME2' : 'RGB');
    final compressed = _isEncapsulated(file.transferSyntax)
        ? _compressedFrames(dataset, numberOfFrames)
        : null;
    final pixelData = compressed == null ? dataset.pixelData : null;
    if (pixelData == null && compressed == null) return null;

    final slope = _asDouble(dataset.metadata['rescaleSlope']);
    return DicomImageData(
      rows: rows,
      columns: columns,
      numberOfFrames: numberOfFrames,
      bitsAllocated: bitsAllocated,
      bitsStored: bitsStored,
      highBit: highBit,
      pixelRepresentation: _asInt(dataset.metadata['pixelRepresentation']) ?? 0,
      samplesPerPixel: samplesPerPixel,
      photometricInterpretation: photometric,
      planarConfiguration: _asInt(dataset.metadata['planarConfiguration']) ?? 0,
      transferSyntaxUid: file.transferSyntax,
      transferSyntaxName: _transferSyntaxNames[file.transferSyntax],
      endian: file.transferSyntax == _explicitVrBe ? Endian.big : Endian.little,
      pixelData: pixelData,
      compressedFrames: compressed,
      rescaleSlope: slope == null || slope == 0 ? 1.0 : slope,
      rescaleIntercept: _asDouble(dataset.metadata['rescaleIntercept']) ?? 0.0,
      windowCenter: _asDouble(dataset.metadata['windowCenter']),
      windowWidth: _asDouble(dataset.metadata['windowWidth']),
      voiLutFunction: _firstString(dataset.metadata['voiLutFunction']),
      pixelSpacing: _joinValues(dataset.metadata['pixelSpacing']),
      pixelPaddingValue: _asInt(dataset.metadata['pixelPaddingValue']),
    );
  }

  _DicomFileRead _readFile(
    Uint8List bytes, {
    required ParseLimits limits,
    required List<ParseWarning> warnings,
    required bool capturePixelData,
  }) {
    final reader = ByteReader(bytes, endian: Endian.little)
      ..seek(_preambleLength + 4);

    final meta = <String, Object?>{};
    String transferSyntax = _explicitVrLe;
    var metaElements = 0;
    while (!reader.isAtEnd) {
      final mark = reader.position;
      final tag = _readTag(reader);
      final group = tag >> 16;
      if (group != 0x0002) {
        reader.seek(mark);
        break;
      }
      final value = _readExplicitElement(reader, tag, warnings, 0);
      metaElements++;
      if (tag == 0x00020010) {
        transferSyntax = (_present(value) as String? ?? '').trim();
      }
      final dict = _dictionary[tag];
      if (dict != null) meta[dict.key] = _present(value);
    }

    var explicit = true;
    var datasetReader = reader;
    switch (transferSyntax) {
      case _implicitVrLe:
        explicit = false;
        reader.endian = Endian.little;
      case _explicitVrBe:
        explicit = true;
        reader.endian = Endian.big;
      case _explicitVrLe:
        explicit = true;
        reader.endian = Endian.little;
      case _deflatedExplicitVrLe:
        explicit = true;
        reader.endian = Endian.little;
        datasetReader = ByteReader(
          _inflateDataset(reader.readBytes(reader.remaining), limits),
          endian: Endian.little,
        );
      default:
        explicit = true;
        reader.endian = Endian.little;
        if (transferSyntax.isNotEmpty && !capturePixelData) {
          warnings.add(
            ParseWarning(
              'dicom.encapsulated',
              'transfer syntax $transferSyntax uses encapsulated pixel data; '
                  'pixel data is not decoded',
            ),
          );
        }
    }

    return _DicomFileRead(
      meta: meta,
      transferSyntax: transferSyntax,
      explicitVr: explicit,
      metaElements: metaElements,
      dataset: _readDataset(
        datasetReader,
        explicit: explicit,
        warnings: warnings,
        depth: 0,
        capturePixelData: capturePixelData,
      ),
    );
  }

  Uint8List _inflateDataset(Uint8List compressed, ParseLimits limits) {
    // PS3.5 says the dataset is raw deflate, but some writers emit a zlib
    // wrapper. Detect the RFC 1950 header and try the matching mode first;
    // otherwise a raw decoder can silently return nonsense for zlib data.
    final looksZlib =
        compressed.length >= 2 &&
        (compressed[0] & 0x0F) == 8 &&
        ((compressed[0] << 8) + compressed[1]) % 31 == 0;
    final max = limits.maxDecompressedBytes;
    final modes = looksZlib ? const [false, true] : const [true, false];
    Object? lastError;
    for (final raw in modes) {
      try {
        return const ZLibDecoder().decodeBytes(
          compressed,
          raw: raw,
          verify: true,
          throwOnError: true,
          maxOutputSize: max,
        );
      } on Object catch (error) {
        lastError = error;
      }
    }
    throw MalformedDocumentException(
      'deflated DICOM dataset could not be inflated: $lastError',
    );
  }

  // --- encapsulated documents ----------------------------------------------

  // --- encapsulated documents ----------------------------------------------

  List<DocumentAttachment> _encapsulatedAttachments(
    _DatasetParse dataset,
    ContentHasher hasher,
    ParseOptions options,
    List<ParseWarning> warnings,
  ) {
    final bytes = dataset.encapsulatedDocument;
    if (bytes == null || !options.includeAttachments) return const [];
    if (bytes.length > options.limits.maxAttachmentBytes) {
      warnings.add(
        ParseWarning(
          'dicom.encapsulated_document_limit',
          'encapsulated document exceeded '
              '${options.limits.maxAttachmentBytes} bytes',
        ),
      );
      return const [];
    }
    final declaredMime = _firstString(
      dataset.metadata['mimeTypeOfEncapsulatedDocument'],
    );
    final mime = declaredMime ?? _sniffMime(bytes);
    final title = _firstString(dataset.metadata['documentTitle']);
    ParseResult? child;
    String? extractedText;
    if (options.parseAttachments) {
      try {
        if (mime == 'application/pdf' || _startsWith(bytes, '%PDF')) {
          child = const PdfParser().parseWithOptions(
            bytes,
            hasher: hasher,
            options: options,
          );
        } else if (mime.contains('xml') || _looksLikeXml(bytes)) {
          child = const CdaParser().parseWithOptions(
            bytes,
            hasher: hasher,
            options: options,
          );
        }
      } on ParseException catch (error) {
        warnings.add(
          ParseWarning(
            'dicom.encapsulated_document_parse_failed',
            'encapsulated document could not be parsed: ${error.message}',
          ),
        );
      }
    }
    if (child != null) {
      extractedText = child.text;
    } else if (mime.startsWith('text/') || mime.contains('xml')) {
      extractedText = latin1.decode(bytes, allowInvalid: true);
      if (extractedText.length > options.limits.maxTextCharacters) {
        extractedText = extractedText.substring(
          0,
          options.limits.maxTextCharacters,
        );
      }
    }

    return [
      DocumentAttachment(
        name: title ?? 'encapsulated-document',
        mediaType: mime,
        size: bytes.length,
        digest: hasher.digestFor(bytes),
        bytes: options.includeAttachmentBytes ? bytes : null,
        text: extractedText,
        child: child,
        relationship: 'encapsulatedDocument',
      ),
    ];
  }

  static String _sniffMime(Uint8List bytes) {
    if (_startsWith(bytes, '%PDF')) return 'application/pdf';
    if (_looksLikeXml(bytes)) return 'application/xml';
    return 'application/octet-stream';
  }

  static bool _startsWith(Uint8List bytes, String prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix.codeUnitAt(i)) return false;
    }
    return true;
  }

  static bool _looksLikeXml(Uint8List bytes) {
    var i = 0;
    while (i < bytes.length && i < 64) {
      final c = bytes[i];
      if (c == 0x20 ||
          c == 0x09 ||
          c == 0x0A ||
          c == 0x0D ||
          c == 0xEF ||
          c == 0xBB ||
          c == 0xBF) {
        i++;
        continue;
      }
      return c == 0x3C; // '<'
    }
    return false;
  }

  _DatasetParse _readDataset(
    ByteReader r, {
    required bool explicit,
    required List<ParseWarning> warnings,
    required int depth,
    int? endOffset,
    bool stopAtItemDelimiter = false,
    bool stopAtSequenceDelimiter = false,
    bool capturePixelData = false,
  }) {
    final metadata = <String, Object?>{};
    final attributes = <Map<String, Object?>>[];
    var count = 0;
    var hasPixelData = false;
    Uint8List? encapsulatedDocument;
    Uint8List? pixelData;
    List<Uint8List>? pixelFragments;
    List<int>? basicOffsetTable;
    if (depth > 12) {
      warnings.add(
        ParseWarning(
          'dicom.sequence_depth',
          'sequence nesting limit reached',
          offset: r.position,
        ),
      );
      return _DatasetParse(
        metadata: metadata,
        attributes: attributes,
        elementCount: count,
        hasPixelData: hasPixelData,
        encapsulatedDocument: encapsulatedDocument,
      );
    }

    while (!r.isAtEnd && (endOffset == null || r.position < endOffset)) {
      final mark = r.position;
      try {
        final tag = _readTag(r);
        if (tag == _itemDelimitationTag && stopAtItemDelimiter) {
          _readDelimiterLength(r, warnings);
          break;
        }
        if (tag == _sequenceDelimitationTag && stopAtSequenceDelimiter) {
          _readDelimiterLength(r, warnings);
          break;
        }
        if (tag == _pixelDataTag) {
          hasPixelData = true;
          if (capturePixelData) {
            final pixel = _readPixelElement(
              r,
              explicit: explicit,
              warnings: warnings,
            );
            pixelData = pixel.pixelData;
            pixelFragments = pixel.pixelFragments;
            basicOffsetTable = pixel.basicOffsetTable;
          } else {
            r.seek(mark);
          }
          break;
        }
        if (tag == _itemTag) {
          r.seek(mark);
          break;
        }

        final value = explicit
            ? _readExplicitElement(r, tag, warnings, depth)
            : _readImplicitElement(r, tag, warnings, depth);
        count++;
        if (tag == 0x00400011 && value.bytes != null) {
          encapsulatedDocument = value.bytes;
        }
        final dict = _dictionary[tag];
        final rendered = _present(value);
        if (dict != null && !metadata.containsKey(dict.key)) {
          metadata[dict.key] = rendered;
        }
        attributes.add(_attributeMap(tag, value, rendered));
      } on TruncatedDocumentException catch (e) {
        warnings.add(
          ParseWarning(
            'dicom.truncated_element',
            'dataset truncated; stopped early',
            offset: e.offset,
          ),
        );
        break;
      }
    }

    return _DatasetParse(
      metadata: metadata,
      attributes: attributes,
      elementCount: count,
      hasPixelData: hasPixelData,
      encapsulatedDocument: encapsulatedDocument,
      pixelData: pixelData,
      pixelFragments: pixelFragments,
      basicOffsetTable: basicOffsetTable,
    );
  }

  _PixelElement _readPixelElement(
    ByteReader r, {
    required bool explicit,
    required List<ParseWarning> warnings,
  }) {
    final vr = explicit
        ? ascii.decode(r.readBytes(2), allowInvalid: true)
        : _dictionary[_pixelDataTag]?.vr ?? 'OW';
    final int length;
    if (explicit && _longFormVrs.contains(vr)) {
      r.skip(2);
      length = r.readUint32();
    } else if (explicit) {
      length = r.readUint16();
    } else {
      length = r.readUint32();
    }

    if (length != 0xFFFFFFFF) {
      return _PixelElement(pixelData: r.readBytes(length));
    }

    final fragments = <Uint8List>[];
    List<int>? basicOffsetTable;
    var first = true;
    while (!r.isAtEnd) {
      final itemTag = _readTag(r);
      if (itemTag == _sequenceDelimitationTag) {
        _readDelimiterLength(r, warnings);
        break;
      }
      if (itemTag != _itemTag) {
        warnings.add(
          ParseWarning(
            'dicom.pixel_fragment',
            'expected an encapsulated pixel fragment but found '
                '${_tagHex(itemTag)}',
            offset: r.position - 4,
          ),
        );
        break;
      }
      final itemLength = r.readUint32();
      if (itemLength == 0xFFFFFFFF) {
        warnings.add(
          ParseWarning(
            'dicom.pixel_fragment',
            'undefined-length pixel fragments are not supported',
            offset: r.position - 4,
          ),
        );
        break;
      }
      final bytes = r.readBytes(itemLength);
      if (first) {
        basicOffsetTable = _uint32Values(bytes);
        first = false;
      } else {
        fragments.add(bytes);
      }
    }
    return _PixelElement(
      pixelFragments: fragments,
      basicOffsetTable: basicOffsetTable,
    );
  }

  static List<int> _uint32Values(Uint8List bytes) {
    final count = bytes.length ~/ 4;
    final data = ByteData.sublistView(bytes);
    return [
      for (var i = 0; i < count; i++) data.getUint32(i * 4, Endian.little),
    ];
  }

  _ElementValue _readExplicitElement(
    ByteReader r,
    int tag,
    List<ParseWarning> warnings,
    int depth,
  ) {
    final vr = ascii.decode(r.readBytes(2), allowInvalid: true);
    final int length;
    if (_longFormVrs.contains(vr)) {
      r.skip(2);
      length = r.readUint32();
    } else {
      length = r.readUint16();
    }
    if (vr == 'SQ' || length == 0xFFFFFFFF) {
      return _readSequenceElement(
        r,
        tag,
        vr,
        length,
        warnings,
        depth,
        itemExplicit: true,
      );
    }
    return _ElementValue(
      tag: tag,
      vr: vr,
      endian: r.endian,
      bytes: r.readBytes(length),
      length: length,
    );
  }

  _ElementValue _readImplicitElement(
    ByteReader r,
    int tag,
    List<ParseWarning> warnings,
    int depth,
  ) {
    final vr = _dictionary[tag]?.vr ?? 'UN';
    final length = r.readUint32();
    if (vr == 'SQ' || length == 0xFFFFFFFF) {
      return _readSequenceElement(
        r,
        tag,
        vr,
        length,
        warnings,
        depth,
        itemExplicit: false,
      );
    }
    return _ElementValue(
      tag: tag,
      vr: vr,
      endian: r.endian,
      bytes: r.readBytes(length),
      length: length,
    );
  }

  _ElementValue _readSequenceElement(
    ByteReader r,
    int tag,
    String vr,
    int length,
    List<ParseWarning> warnings,
    int depth, {
    required bool itemExplicit,
  }) {
    final end = length == 0xFFFFFFFF ? null : r.position + length;
    final items = <Map<String, Object?>>[];
    while (!r.isAtEnd && (end == null || r.position < end)) {
      final itemTag = _readTag(r);
      if (itemTag == _sequenceDelimitationTag) {
        _readDelimiterLength(r, warnings);
        break;
      }
      if (itemTag != _itemTag) {
        warnings.add(
          ParseWarning(
            'dicom.sequence_item',
            'expected sequence item but found ${_tagHex(itemTag)}',
            offset: r.position - 4,
          ),
        );
        r.seek((end ?? r.length).clamp(0, r.length));
        break;
      }
      final itemLength = r.readUint32();
      final itemEnd = itemLength == 0xFFFFFFFF ? null : r.position + itemLength;
      final parsed = _readDataset(
        r,
        explicit: itemExplicit,
        warnings: warnings,
        depth: depth + 1,
        endOffset: itemEnd,
        stopAtItemDelimiter: itemLength == 0xFFFFFFFF,
        stopAtSequenceDelimiter: false,
      );
      items.add({'attributes': parsed.attributes, ...parsed.metadata});
    }
    return _ElementValue(
      tag: tag,
      vr: vr,
      endian: r.endian,
      bytes: null,
      length: length,
      sequenceItems: items,
    );
  }

  int _readTag(ByteReader r) {
    final group = r.readUint16();
    final element = r.readUint16();
    return (group << 16) | element;
  }

  void _readDelimiterLength(ByteReader r, List<ParseWarning> warnings) {
    final length = r.readUint32();
    if (length != 0) {
      warnings.add(
        ParseWarning(
          'dicom.delimiter_length',
          'non-zero delimiter length $length ignored',
          offset: r.position - 4,
        ),
      );
      if (length <= r.remaining) r.skip(length);
    }
  }

  Map<String, Object?> _attributeMap(
    int tag,
    _ElementValue value,
    Object? rendered,
  ) {
    final dict = _dictionary[tag];
    return {
      'tag': _tagHex(tag),
      if (dict != null) 'keyword': dict.key,
      'vr': value.vr,
      if (value.sequenceItems != null) 'items': value.sequenceItems,
      if (value.sequenceItems == null) 'value': rendered,
    };
  }

  Object? _present(_ElementValue v) {
    if (v.sequenceItems != null) return v.sequenceItems;
    if (v.bytes == null) return null;
    if (_stringVrs.contains(v.vr)) {
      final decoded = _decodeStringValue(v.bytes!);
      if (decoded.contains(r'\')) {
        final parts = decoded
            .split(r'\')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        return parts.length == 1 ? parts.single : parts;
      }
      return decoded;
    }
    if ((v.vr == 'US' || v.vr == 'UL' || v.vr == 'SS' || v.vr == 'SL') &&
        v.bytes!.length >= 2) {
      final bd = ByteData.sublistView(v.bytes!);
      return switch (v.vr) {
        'US' => bd.getUint16(0, v.endian),
        'UL' => bd.getUint32(0, v.endian),
        'SS' => bd.getInt16(0, v.endian),
        _ => bd.getInt32(0, v.endian),
      };
    }
    return '<${v.length} bytes>';
  }

  /// Decodes a string-valued element under the DICOM default repertoire
  /// (ISO_IR 6 / UTF-8 compatible). Non-ASCII bytes are preserved verbatim
  /// rather than replaced, so callers can apply SpecificCharacterSet themselves.
  static String _decodeStringValue(Uint8List bytes) {
    return latin1
        .decode(bytes, allowInvalid: true)
        .replaceAll('\x00', '')
        .trim();
  }

  static String? _firstString(Object? value) {
    if (value == null) return null;
    if (value is String) return value.trim();
    if (value is List) {
      for (final e in value) {
        if (e is String) return e.trim();
      }
    }
    return null;
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    if (value is Iterable) {
      for (final item in value) {
        final parsed = _asInt(item);
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  static double? _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    if (value is Iterable) {
      for (final item in value) {
        final parsed = _asDouble(item);
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  static String? _joinValues(Object? value) {
    if (value is String) return value;
    if (value is Iterable) {
      final parts = [for (final item in value) '$item'.trim()]
        ..removeWhere((part) => part.isEmpty);
      return parts.isEmpty ? null : parts.join(' x ');
    }
    return value?.toString();
  }

  static bool _isEncapsulated(String transferSyntax) =>
      transferSyntax.isNotEmpty &&
      transferSyntax != _implicitVrLe &&
      transferSyntax != _explicitVrLe &&
      transferSyntax != _explicitVrBe &&
      transferSyntax != _deflatedExplicitVrLe;

  static List<Uint8List>? _compressedFrames(
    _DatasetParse dataset,
    int numberOfFrames,
  ) {
    final fragments = dataset.pixelFragments;
    if (fragments == null || fragments.isEmpty) {
      final defined = dataset.pixelData;
      return defined == null ? null : [defined];
    }
    final total = fragments.fold<int>(0, (sum, f) => sum + f.length);
    final offsets = dataset.basicOffsetTable;
    if (offsets != null && offsets.isNotEmpty) {
      final frames = <Uint8List>[];
      for (var i = 0; i < offsets.length; i++) {
        final start = offsets[i];
        final end = i + 1 < offsets.length ? offsets[i + 1] : total;
        if (start < 0 || start > end || end > total) {
          throw const MalformedDocumentException(
            'DICOM basic offset table points outside pixel data',
          );
        }
        frames.add(_concatFragments(fragments, start, end));
      }
      return frames;
    }
    final declared = numberOfFrames <= 0 ? 1 : numberOfFrames;
    if (declared <= 1) {
      return [_concatFragments(fragments, 0, total)];
    }
    if (fragments.length == declared) return fragments;
    throw UnsupportedFeatureException(
      'multi-frame encapsulated DICOM without a basic offset table is not '
      'supported ($declared frames, ${fragments.length} fragments)',
    );
  }

  static Uint8List _concatFragments(
    List<Uint8List> fragments,
    int start,
    int end,
  ) {
    final output = Uint8List(end - start);
    var fragmentStart = 0;
    var outputOffset = 0;
    for (final fragment in fragments) {
      final fragmentEnd = fragmentStart + fragment.length;
      final copyStart = start > fragmentStart ? start : fragmentStart;
      final copyEnd = end < fragmentEnd ? end : fragmentEnd;
      if (copyEnd > copyStart) {
        output.setRange(
          outputOffset,
          outputOffset + copyEnd - copyStart,
          fragment,
          copyStart - fragmentStart,
        );
        outputOffset += copyEnd - copyStart;
      }
      fragmentStart = fragmentEnd;
    }
    return output;
  }

  String _tagHex(int tag) => dicomTagHex(tag);
}

final class _DicomFileRead {
  const _DicomFileRead({
    required this.meta,
    required this.transferSyntax,
    required this.explicitVr,
    required this.metaElements,
    required this.dataset,
  });

  final Map<String, Object?> meta;
  final String transferSyntax;
  final bool explicitVr;
  final int metaElements;
  final _DatasetParse dataset;
}

final class _PixelElement {
  const _PixelElement({
    this.pixelData,
    this.pixelFragments,
    this.basicOffsetTable,
  });

  final Uint8List? pixelData;
  final List<Uint8List>? pixelFragments;
  final List<int>? basicOffsetTable;
}

final class _DatasetParse {
  const _DatasetParse({
    required this.metadata,
    required this.attributes,
    required this.elementCount,
    required this.hasPixelData,
    this.encapsulatedDocument,
    this.pixelData,
    this.pixelFragments,
    this.basicOffsetTable,
  });

  final Map<String, Object?> metadata;
  final List<Map<String, Object?>> attributes;
  final int elementCount;
  final bool hasPixelData;
  final Uint8List? encapsulatedDocument;

  /// Native pixel bytes when [capturePixelData] was requested.
  final Uint8List? pixelData;

  /// Encapsulated fragments, excluding the basic offset table.
  final List<Uint8List>? pixelFragments;

  final List<int>? basicOffsetTable;
}

final class _ElementValue {
  const _ElementValue({
    required this.tag,
    required this.vr,
    required this.endian,
    required this.bytes,
    required this.length,
    this.sequenceItems,
  });

  final int tag;
  final String vr;
  final Endian endian;
  final Uint8List? bytes;
  final int length;
  final List<Map<String, Object?>>? sequenceItems;
}
