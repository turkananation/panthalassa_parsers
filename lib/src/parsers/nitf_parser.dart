import 'dart:typed_data';

import '../core/byte_reader.dart';
import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_exception.dart';
import '../core/parse_result.dart';

/// Parser for NITF 2.1 / NSIF 1.0 files (MIL-STD-2500C).
///
/// Reads the fixed-width file header at its exact specified offsets (the
/// original spec read a placeholder "file id" at the wrong bytes) to recover
/// version, complexity level, originating station, file date/time, title,
/// security classification, declared file/header lengths, and the image-segment
/// table. Segment bodies are located but not decoded.
final class NitfParser implements DocumentParser {
  const NitfParser();

  // Field offsets within the NITF 2.1 file header (bytes).
  static const _fhdr = 0;
  static const _fver = 4;
  static const _clevel = 9;
  static const _ostaid = 15;
  static const _fdt = 25;
  static const _ftitle = 39;
  static const _fsclas = 119;
  static const _fl = 342; // file length
  static const _hl = 354; // header length
  static const _numi = 360; // number of image segments
  static const _imageTableStart = 363;
  static const _minHeader = 363;

  @override
  DocumentFormat get format => DocumentFormat.nitf;

  @override
  bool canParse(Uint8List bytes) {
    if (bytes.length < 9) return false;
    // FHDR = 'NITF' (or legacy 'NSIF' for the NATO profile).
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
      warnings.add(ParseWarning(
        'nitf.length_mismatch',
        'declared file length $declaredFileLength != actual ${bytes.length}',
      ));
    }

    // Image segment table: NUMI repetitions of LISH(6) + LI(10).
    final images = <Map<String, Object?>>[];
    r.seek(_imageTableStart);
    for (var i = 0; i < numImages; i++) {
      if (r.remaining < 16) {
        warnings.add(const ParseWarning(
            'nitf.truncated_image_table', 'image segment table truncated'));
        break;
      }
      final subheaderLen = int.tryParse(r.readAsciiFixed(6));
      final imageLen = int.tryParse(r.readAsciiFixed(10));
      images.add({'subheaderLength': subheaderLen, 'imageLength': imageLen});
    }

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
        'imageSegments': numImages,
        'images': images,
      },
      text: title.isEmpty ? null : title,
      warnings: warnings,
    );
  }
}
