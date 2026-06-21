import 'dart:convert';
import 'dart:typed_data';

import '../core/byte_reader.dart';
import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_exception.dart';
import '../core/parse_result.dart';

/// Parser for NITF 2.1 / NSIF 1.0 files (MIL-STD-2500C).
///
/// Reads the fixed-width file header and all segment length tables, then walks
/// image, graphic, text, DES, and RES segment subheaders/bodies. Image pixels
/// are not decoded; text segment payloads are decoded when they look textual.
final class NitfParser implements DocumentParser {
  const NitfParser();

  static const _fhdr = 0;
  static const _fver = 4;
  static const _clevel = 9;
  static const _ostaid = 15;
  static const _fdt = 25;
  static const _ftitle = 39;
  static const _fsclas = 119;
  static const _fl = 342;
  static const _hl = 354;
  static const _numi = 360;
  static const _imageTableStart = 363;
  static const _minHeader = 363;

  @override
  DocumentFormat get format => DocumentFormat.nitf;

  @override
  bool canParse(Uint8List bytes) {
    if (bytes.length < 9) return false;
    final fhdr = String.fromCharCodes(bytes.sublist(0, 4));
    if (fhdr != 'NITF' && fhdr != 'NSIF') return false;
    final fver = String.fromCharCodes(bytes.sublist(4, 9));
    return fver == '02.10' || fver == '01.10';
  }

  @override
  ParseResult parse(Uint8List bytes, {required ContentHasher hasher}) {
    if (bytes.length < _minHeader) {
      throw TruncatedDocumentException(
        'NITF header requires $_minHeader bytes, found ${bytes.length}',
        offset: bytes.length,
      );
    }
    final r = ByteReader(bytes, endian: Endian.big);

    String field(int offset, int len) {
      r.seek(offset);
      return r.readAsciiFixed(len);
    }

    final version = field(_fver, 5);
    final clevel = field(_clevel, 2);
    final ostaid = field(_ostaid, 10);
    final fdt = field(_fdt, 14);
    final title = field(_ftitle, 80);
    final classification = field(_fsclas, 1);
    final declaredFileLength = int.tryParse(field(_fl, 12));
    final headerLength = int.tryParse(field(_hl, 6));
    final numImages = int.tryParse(field(_numi, 3)) ?? 0;

    final warnings = <ParseWarning>[];
    if (declaredFileLength != null && declaredFileLength != bytes.length) {
      warnings.add(
        ParseWarning(
          'nitf.length_mismatch',
          'declared file length $declaredFileLength != actual ${bytes.length}',
        ),
      );
    }

    r.seek(_imageTableStart);
    final images = _readLengthTable(
      r,
      count: numImages,
      subheaderDigits: 6,
      dataDigits: 10,
      warningPrefix: 'image',
      warnings: warnings,
    );
    final graphics = _readCountedTable(
      r,
      subheaderDigits: 6,
      dataDigits: 10,
      warningPrefix: 'graphic',
      warnings: warnings,
    );
    _readOptionalCount(r, warnings, 'NUMX'); // reserved/reserved extensions
    final texts = _readCountedTable(
      r,
      subheaderDigits: 4,
      dataDigits: 5,
      warningPrefix: 'text',
      warnings: warnings,
    );
    final dataExtensions = _readCountedTable(
      r,
      subheaderDigits: 4,
      dataDigits: 9,
      warningPrefix: 'des',
      warnings: warnings,
    );
    final reservedExtensions = _readCountedTable(
      r,
      subheaderDigits: 4,
      dataDigits: 7,
      warningPrefix: 'res',
      warnings: warnings,
    );

    var bodyOffset = headerLength ?? r.position;
    bodyOffset = bodyOffset.clamp(0, bytes.length);
    final imageSegments = _attachBodies(
      bytes,
      images,
      bodyOffset,
      _parseImageSubheader,
      warnings,
    );
    bodyOffset = _advance(bodyOffset, images);
    final graphicSegments = _attachBodies(
      bytes,
      graphics,
      bodyOffset,
      _parseGraphicSubheader,
      warnings,
    );
    bodyOffset = _advance(bodyOffset, graphics);
    final textSegments = _attachBodies(
      bytes,
      texts,
      bodyOffset,
      _parseTextSubheader,
      warnings,
      decodeBodyText: true,
    );
    bodyOffset = _advance(bodyOffset, texts);
    final desSegments = _attachBodies(
      bytes,
      dataExtensions,
      bodyOffset,
      _parseDesSubheader,
      warnings,
    );
    bodyOffset = _advance(bodyOffset, dataExtensions);
    final resSegments = _attachBodies(
      bytes,
      reservedExtensions,
      bodyOffset,
      _parseResSubheader,
      warnings,
    );

    final textOut = [
      if (title.isNotEmpty) title,
      for (final t in textSegments)
        if (t['text'] case final String s when s.isNotEmpty) s,
    ].join('\n');

    return ParseResult(
      documentId: hasher.idFor(bytes),
      format: format,
      byteLength: bytes.length,
      metadata: {
        'standard': field(_fhdr, 4),
        'version': version,
        'complexityLevel': clevel,
        'originatingStation': ostaid,
        'fileDateTime': fdt,
        'title': title,
        'securityClassification': classification,
        'declaredFileLength': declaredFileLength,
        'headerLength': headerLength,
        'imageSegments': imageSegments.length,
        'graphicSegments': graphicSegments.length,
        'textSegments': textSegments.length,
        'dataExtensionSegments': desSegments.length,
        'reservedExtensionSegments': resSegments.length,
        'images': imageSegments,
        if (graphicSegments.isNotEmpty) 'graphics': graphicSegments,
        if (textSegments.isNotEmpty) 'texts': textSegments,
        if (desSegments.isNotEmpty) 'dataExtensions': desSegments,
        if (resSegments.isNotEmpty) 'reservedExtensions': resSegments,
      },
      text: textOut.isEmpty ? null : textOut,
      warnings: warnings,
    );
  }

  List<Map<String, Object?>> _readCountedTable(
    ByteReader r, {
    required int subheaderDigits,
    required int dataDigits,
    required String warningPrefix,
    required List<ParseWarning> warnings,
  }) {
    final count = _readOptionalCount(r, warnings, warningPrefix);
    return _readLengthTable(
      r,
      count: count,
      subheaderDigits: subheaderDigits,
      dataDigits: dataDigits,
      warningPrefix: warningPrefix,
      warnings: warnings,
    );
  }

  int _readOptionalCount(
    ByteReader r,
    List<ParseWarning> warnings,
    String label,
  ) {
    if (r.remaining < 3) {
      warnings.add(
        ParseWarning(
          'nitf.${label.toLowerCase()}_count',
          '$label count is truncated',
          offset: r.position,
        ),
      );
      return 0;
    }
    return int.tryParse(r.readAsciiFixed(3)) ?? 0;
  }

  List<Map<String, Object?>> _readLengthTable(
    ByteReader r, {
    required int count,
    required int subheaderDigits,
    required int dataDigits,
    required String warningPrefix,
    required List<ParseWarning> warnings,
  }) {
    final out = <Map<String, Object?>>[];
    for (var i = 0; i < count; i++) {
      final need = subheaderDigits + dataDigits;
      if (r.remaining < need) {
        warnings.add(
          ParseWarning(
            'nitf.truncated_${warningPrefix}_table',
            '$warningPrefix segment table truncated',
            offset: r.position,
          ),
        );
        break;
      }
      out.add({
        'subheaderLength': int.tryParse(r.readAsciiFixed(subheaderDigits)) ?? 0,
        'dataLength': int.tryParse(r.readAsciiFixed(dataDigits)) ?? 0,
      });
    }
    return out;
  }

  List<Map<String, Object?>> _attachBodies(
    Uint8List bytes,
    List<Map<String, Object?>> table,
    int start,
    Map<String, Object?> Function(Uint8List) parseSubheader,
    List<ParseWarning> warnings, {
    bool decodeBodyText = false,
  }) {
    final out = <Map<String, Object?>>[];
    var offset = start;
    for (final entry in table) {
      final subLen = entry['subheaderLength'] as int? ?? 0;
      final dataLen = entry['dataLength'] as int? ?? 0;
      final subEnd = offset + subLen;
      final dataEnd = subEnd + dataLen;
      if (subEnd > bytes.length || dataEnd > bytes.length) {
        warnings.add(
          ParseWarning(
            'nitf.segment_bounds',
            'segment at $offset exceeds file length',
            offset: offset,
          ),
        );
        break;
      }
      final subheader = Uint8List.sublistView(bytes, offset, subEnd);
      final data = Uint8List.sublistView(bytes, subEnd, dataEnd);
      out.add({
        ...entry,
        'offset': offset,
        ...parseSubheader(subheader),
        if (decodeBodyText && data.isNotEmpty) 'text': _decodeTextBody(data),
      });
      offset = dataEnd;
    }
    return out;
  }

  int _advance(int start, List<Map<String, Object?>> table) {
    var offset = start;
    for (final entry in table) {
      offset +=
          (entry['subheaderLength'] as int? ?? 0) +
          (entry['dataLength'] as int? ?? 0);
    }
    return offset;
  }

  Map<String, Object?> _parseImageSubheader(Uint8List bytes) => {
    if (_field(bytes, 0, 2).isNotEmpty) 'type': _field(bytes, 0, 2),
    if (_field(bytes, 2, 10).isNotEmpty) 'imageId': _field(bytes, 2, 10),
    if (_field(bytes, 12, 14).isNotEmpty)
      'imageDateTime': _field(bytes, 12, 14),
    if (_field(bytes, 26, 17).isNotEmpty) 'targetId': _field(bytes, 26, 17),
    if (_field(bytes, 43, 80).isNotEmpty) 'title': _field(bytes, 43, 80),
    if (_field(bytes, 123, 1).isNotEmpty)
      'securityClassification': _field(bytes, 123, 1),
    if (_field(bytes, 167, 8).isNotEmpty)
      'rows': int.tryParse(_field(bytes, 167, 8)),
    if (_field(bytes, 175, 8).isNotEmpty)
      'columns': int.tryParse(_field(bytes, 175, 8)),
  };

  Map<String, Object?> _parseGraphicSubheader(Uint8List bytes) => {
    if (_field(bytes, 0, 2).isNotEmpty) 'type': _field(bytes, 0, 2),
    if (_field(bytes, 2, 10).isNotEmpty) 'graphicId': _field(bytes, 2, 10),
    if (_field(bytes, 12, 20).isNotEmpty) 'name': _field(bytes, 12, 20),
    if (_field(bytes, 32, 1).isNotEmpty)
      'securityClassification': _field(bytes, 32, 1),
  };

  Map<String, Object?> _parseTextSubheader(Uint8List bytes) => {
    if (_field(bytes, 0, 2).isNotEmpty) 'type': _field(bytes, 0, 2),
    if (_field(bytes, 2, 7).isNotEmpty) 'textId': _field(bytes, 2, 7),
    if (_field(bytes, 9, 14).isNotEmpty) 'textDateTime': _field(bytes, 9, 14),
    if (_field(bytes, 23, 80).isNotEmpty) 'title': _field(bytes, 23, 80),
    if (_field(bytes, 103, 1).isNotEmpty)
      'securityClassification': _field(bytes, 103, 1),
    if (_field(bytes, 106, 3).isNotEmpty) 'format': _field(bytes, 106, 3),
  };

  Map<String, Object?> _parseDesSubheader(Uint8List bytes) => {
    if (_field(bytes, 0, 2).isNotEmpty) 'type': _field(bytes, 0, 2),
    if (_field(bytes, 2, 25).isNotEmpty) 'desId': _field(bytes, 2, 25),
    if (_field(bytes, 27, 2).isNotEmpty) 'version': _field(bytes, 27, 2),
    if (_field(bytes, 29, 1).isNotEmpty)
      'securityClassification': _field(bytes, 29, 1),
  };

  Map<String, Object?> _parseResSubheader(Uint8List bytes) => {
    if (_field(bytes, 0, 2).isNotEmpty) 'type': _field(bytes, 0, 2),
    if (_field(bytes, 2, 25).isNotEmpty) 'resId': _field(bytes, 2, 25),
    if (_field(bytes, 27, 1).isNotEmpty)
      'securityClassification': _field(bytes, 27, 1),
  };

  String _field(Uint8List bytes, int offset, int length) {
    if (offset >= bytes.length) return '';
    final end = (offset + length).clamp(0, bytes.length);
    return ascii
        .decode(Uint8List.sublistView(bytes, offset, end), allowInvalid: true)
        .replaceAll(RegExp(r'[\x00 ]+$'), '');
  }

  String _decodeTextBody(Uint8List bytes) =>
      utf8.decode(bytes, allowMalformed: true).trim();
}
