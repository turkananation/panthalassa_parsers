import 'dart:convert';
import 'dart:typed_data';

import '../core/byte_reader.dart';
import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_exception.dart';
import '../core/parse_options.dart';
import '../core/parse_result.dart';
import '../core/structured_artifacts.dart';
import 'cda_parser.dart';
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
    0x00280010: (key: 'rows', vr: 'US'),
    0x00280011: (key: 'columns', vr: 'US'),
    0x00280100: (key: 'bitsAllocated', vr: 'US'),
    0x00280101: (key: 'bitsStored', vr: 'US'),
    0x00280102: (key: 'highBit', vr: 'US'),
    0x00280103: (key: 'pixelRepresentation', vr: 'US'),
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

    final bool explicit;
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
      default:
        explicit = true;
        reader.endian = Endian.little;
        if (transferSyntax.isNotEmpty) {
          warnings.add(
            ParseWarning(
              'dicom.encapsulated',
              'transfer syntax $transferSyntax uses encapsulated pixel data; '
                  'pixel data is not decoded',
            ),
          );
        }
    }

    final dataset = _readDataset(
      reader,
      explicit: explicit,
      warnings: warnings,
      depth: 0,
    );

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
        'transferSyntax': transferSyntax,
        if (_transferSyntaxNames[transferSyntax] != null)
          'transferSyntaxName': _transferSyntaxNames[transferSyntax],
        'explicitVr': explicit,
        'metaElements': metaElements,
        'datasetElements': dataset.elementCount,
        'hasPixelData': dataset.hasPixelData,
        ...meta,
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
  }) {
    final metadata = <String, Object?>{};
    final attributes = <Map<String, Object?>>[];
    var count = 0;
    var hasPixelData = false;
    Uint8List? encapsulatedDocument;
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
          r.seek(mark);
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
    );
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

  String _tagHex(int tag) => dicomTagHex(tag);
}

final class _DatasetParse {
  const _DatasetParse({
    required this.metadata,
    required this.attributes,
    required this.elementCount,
    required this.hasPixelData,
    this.encapsulatedDocument,
  });

  final Map<String, Object?> metadata;
  final List<Map<String, Object?>> attributes;
  final int elementCount;
  final bool hasPixelData;
  final Uint8List? encapsulatedDocument;
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
