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
/// Information group (0002) as Explicit VR Little Endian to recover the Transfer
/// Syntax, then walks the main dataset under the indicated VR/endianness,
/// surfacing a curated set of clinically relevant attributes. Pixel data
/// (7FE0,0010) is detected and reported but never read into memory — decoding
/// pixels is out of scope for a metadata parser. Encapsulated/compressed
/// transfer syntaxes are still traversable because only non-pixel elements are
/// interpreted.
final class DicomParser implements DocumentParser {
  const DicomParser();

  static const _preambleLength = 128;
  static const _pixelDataTag = 0x7FE00010;

  // Transfer syntaxes that change how the dataset is encoded.
  static const _implicitVrLe = '1.2.840.10008.1.2';
  static const _explicitVrLe = '1.2.840.10008.1.2.1';
  static const _explicitVrBe = '1.2.840.10008.1.2.2';

  // String VRs whose values we decode to text.
  static const _stringVrs = {
    'AE', 'AS', 'CS', 'DA', 'DS', 'DT', 'IS', 'LO', 'LT',
    'PN', 'SH', 'ST', 'TM', 'UC', 'UI', 'UR', 'UT',
  };
  // Explicit VRs that use the 12-byte (2 VR + 2 reserved + 4 length) header.
  static const _longFormVrs = {'OB', 'OW', 'OF', 'OD', 'OL', 'SQ', 'UC', 'UR', 'UT', 'UN'};

  /// Curated tag -> (key, label). Extend freely; absence only means the value is
  /// not surfaced in metadata, not that parsing fails.
  static const _dictionary = <int, String>{
    0x00080018: 'sopInstanceUid',
    0x00080020: 'studyDate',
    0x00080030: 'studyTime',
    0x00080060: 'modality',
    0x00080070: 'manufacturer',
    0x00080090: 'referringPhysician',
    0x00081030: 'studyDescription',
    0x0008103E: 'seriesDescription',
    0x00100010: 'patientName',
    0x00100020: 'patientId',
    0x00100030: 'patientBirthDate',
    0x00100040: 'patientSex',
    0x0020000D: 'studyInstanceUid',
    0x0020000E: 'seriesInstanceUid',
    0x00200011: 'seriesNumber',
    0x00280010: 'rows',
    0x00280011: 'columns',
    0x00280100: 'bitsAllocated',
  };

  @override
  DocumentFormat get format => DocumentFormat.dicom;

  @override
  bool canParse(Uint8List bytes) {
    // Standard Part 10: 128-byte preamble then 'DICM'. Use >= 132 (a file of
    // exactly 132 bytes is a valid, if empty, Part 10 header).
    if (bytes.length < _preambleLength + 4) return false;
    return bytes[_preambleLength] == 0x44 && // D
        bytes[_preambleLength + 1] == 0x49 && // I
        bytes[_preambleLength + 2] == 0x43 && // C
        bytes[_preambleLength + 3] == 0x4D; // M
  }

  @override
  ParseResult parse(Uint8List bytes, {required ContentHasher hasher}) {
    final warnings = <ParseWarning>[];
    final reader = ByteReader(bytes, endian: Endian.little);
    reader.seek(_preambleLength + 4); // past preamble + 'DICM'

    // 1. File Meta Information (group 0002) is always Explicit VR LE.
    final meta = <String, Object?>{};
    String transferSyntax = _explicitVrLe;
    while (!reader.isAtEnd) {
      final mark = reader.position;
      final group = reader.readUint16();
      if (group != 0x0002) {
        reader.seek(mark); // first non-meta element: stop the meta scan
        break;
      }
      final element = reader.readUint16();
      final tag = (group << 16) | element;
      final value = _readExplicitValue(reader, warnings);
      if (tag == 0x00020010) {
        transferSyntax = _asString(value).replaceAll('\x00', '').trim();
      }
      final name = _dictionary[tag];
      if (name != null) meta[name] = _present(value);
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
        // Compressed/encapsulated syntaxes: dataset header is Explicit VR LE.
        explicit = true;
        reader.endian = Endian.little;
        if (transferSyntax.isNotEmpty) {
          warnings.add(ParseWarning('dicom.encapsulated',
              'compressed transfer syntax $transferSyntax; pixel data not decoded'));
        }
    }

    // 2. Main dataset.
    final attributes = <String, Object?>{...meta};
    var elementCount = 0;
    var hasPixelData = false;
    while (!reader.isAtEnd) {
      final group = reader.readUint16();
      final element = reader.readUint16();
      final tag = (group << 16) | element;

      if (tag == _pixelDataTag) {
        hasPixelData = true;
        break; // do not read pixel data into memory
      }

      final _ElementValue value;
      try {
        value = explicit
            ? _readExplicitValue(reader, warnings)
            : _readImplicitValue(reader);
      } on TruncatedDocumentException catch (e) {
        warnings.add(ParseWarning('dicom.truncated_element',
            'dataset truncated; stopped early', offset: e.offset));
        break;
      }
      elementCount++;
      final name = _dictionary[tag];
      if (name != null && !attributes.containsKey(name)) {
        attributes[name] = _present(value);
      }
    }

    return ParseResult(
      documentId: hasher.idFor(bytes),
      format: format,
      byteLength: bytes.length,
      metadata: {
        'transferSyntax': transferSyntax,
        'explicitVr': explicit,
        'metaElements': meta.length,
        'datasetElements': elementCount,
        'hasPixelData': hasPixelData,
        ...attributes,
      },
      text: null, // imaging data, not prose
      warnings: warnings,
    );
  }

  _ElementValue _readExplicitValue(ByteReader r, List<ParseWarning> warnings) {
    final vrBytes = r.readBytes(2);
    final vr = ascii.decode(vrBytes, allowInvalid: true);
    final int length;
    if (_longFormVrs.contains(vr)) {
      r.skip(2); // reserved
      length = r.readUint32();
    } else {
      length = r.readUint16();
    }
    if (length == 0xFFFFFFFF) {
      // Undefined length (sequence/encapsulated): we don't descend; flag it.
      warnings.add(const ParseWarning(
          'dicom.undefined_length', 'undefined-length element skipped'));
      return const _ElementValue(vr: 'SQ', bytes: null, length: 0);
    }
    final data = r.readBytes(length);
    return _ElementValue(vr: vr, bytes: data, length: length);
  }

  _ElementValue _readImplicitValue(ByteReader r) {
    final length = r.readUint32();
    if (length == 0xFFFFFFFF) {
      return const _ElementValue(vr: 'UN', bytes: null, length: 0);
    }
    final data = r.readBytes(length);
    return _ElementValue(vr: 'UN', bytes: data, length: length);
  }

  String _asString(_ElementValue v) =>
      v.bytes == null ? '' : ascii.decode(v.bytes!, allowInvalid: true);

  /// Renders a value for metadata: strings decoded and trimmed; small integers
  /// read; everything else summarised by length to keep results compact.
  Object? _present(_ElementValue v) {
    if (v.bytes == null) return null;
    if (_stringVrs.contains(v.vr)) {
      return ascii.decode(v.bytes!, allowInvalid: true).replaceAll('\x00', '').trim();
    }
    if ((v.vr == 'US' || v.vr == 'UL') && v.bytes!.length >= 2) {
      final bd = ByteData.sublistView(v.bytes!);
      return v.vr == 'US'
          ? bd.getUint16(0, Endian.little)
          : bd.getUint32(0, Endian.little);
    }
    return '<${v.length} bytes>';
  }
}

class _ElementValue {
  const _ElementValue({required this.vr, required this.bytes, required this.length});
  final String vr;
  final Uint8List? bytes;
  final int length;
}
