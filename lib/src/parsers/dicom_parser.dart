import 'dart:convert';
import 'dart:typed_data';

import '../core/byte_reader.dart';
import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_exception.dart';
import '../core/parse_result.dart';

/// Parser for DICOM Part 10 files (PS3.10).
///
/// Reads the 128-byte preamble and `DICM` magic, parses the File Meta
/// Information group as Explicit VR Little Endian, then walks the main dataset
/// under the indicated transfer syntax. It descends into SQ values, including
/// undefined-length item/delimitation records, and stops before Pixel Data.
final class DicomParser implements DocumentParser {
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
  };

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
  ParseResult parse(Uint8List bytes, {required ContentHasher hasher}) {
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

    return ParseResult(
      documentId: hasher.idFor(bytes),
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
      text: null,
      warnings: warnings,
    );
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
      final decoded = ascii
          .decode(v.bytes!, allowInvalid: true)
          .replaceAll('\x00', '')
          .trim();
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

  String _tagHex(int tag) =>
      '(${(tag >> 16).toRadixString(16).padLeft(4, '0').toUpperCase()},'
      '${(tag & 0xFFFF).toRadixString(16).padLeft(4, '0').toUpperCase()})';
}

final class _DatasetParse {
  const _DatasetParse({
    required this.metadata,
    required this.attributes,
    required this.elementCount,
    required this.hasPixelData,
  });

  final Map<String, Object?> metadata;
  final List<Map<String, Object?>> attributes;
  final int elementCount;
  final bool hasPixelData;
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
