import 'dart:convert';
import 'dart:typed_data';

import 'package:swissarmyknife/swissarmyknife.dart';

import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_result.dart';

/// Parser for image container metadata (JPEG, PNG, TIFF, WebP, GIF, SVG).
///
/// No pixel decode is performed. The parser reads magic bytes, container
/// headers, and metadata chunks to surface dimensions, colour model, EXIF/GPS,
/// PNG text chunks, XMP presence, and SVG titles/descriptions. Embedded image
/// payloads are never expanded or executed; SVG script and external references
/// are reported as warnings only.
final class ImageMetadataParser implements DocumentParser {
  const ImageMetadataParser();

  static const int _maxSvgScan = 1024 * 1024;

  @override
  DocumentFormat get format => DocumentFormat.image;

  String get parserVersion => parserImplementationVersion;

  @override
  bool canParse(Uint8List bytes) {
    if (bytes.isEmpty) return false;
    return _jpegMagic(bytes) ||
        _pngMagic(bytes) ||
        _gifMagic(bytes) ||
        _webpMagic(bytes) ||
        _tiffMagic(bytes) ||
        _svgMagic(bytes);
  }

  @override
  ParseResult parse(Uint8List bytes, {required ContentHasher hasher}) {
    final digest = hasher.digestFor(bytes);
    final warnings = <ParseWarning>[];
    final metadata = <String, Object?>{};

    if (_jpegMagic(bytes)) {
      _parseJpeg(bytes, metadata, warnings);
    } else if (_pngMagic(bytes)) {
      _parsePng(bytes, metadata, warnings);
    } else if (_gifMagic(bytes)) {
      _parseGif(bytes, metadata, warnings);
    } else if (_webpMagic(bytes)) {
      _parseWebp(bytes, metadata, warnings);
    } else if (_tiffMagic(bytes)) {
      _parseTiff(bytes, metadata, warnings);
    } else if (_svgMagic(bytes)) {
      _parseSvg(bytes, metadata, warnings);
    }

    return ParseResult(
      documentId: digest.sha256,
      digest: digest,
      format: format,
      byteLength: bytes.length,
      metadata: metadata,
      text: null,
      warnings: warnings,
      parserVersion: parserVersion,
    );
  }

  // --- magic detection ------------------------------------------------------

  static bool _jpegMagic(Uint8List b) =>
      b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;

  static bool _pngMagic(Uint8List b) =>
      b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47 &&
      b[4] == 0x0D &&
      b[5] == 0x0A &&
      b[6] == 0x1A &&
      b[7] == 0x0A;

  static bool _gifMagic(Uint8List b) {
    if (b.length < 6) return false;
    return b[0] == 0x47 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x38 &&
        (b[4] == 0x37 || b[4] == 0x39) &&
        b[5] == 0x61;
  }

  static bool _webpMagic(Uint8List b) =>
      b.length >= 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50;

  static bool _tiffMagic(Uint8List b) =>
      b.length >= 4 &&
      ((b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0x00) ||
          (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0x00 && b[3] == 0x2A));

  static bool _svgMagic(Uint8List bytes) {
    if (bytes.isEmpty) return false;
    var text = _peekText(bytes, 4096).trimLeft();
    if (text.startsWith('\uFEFF')) text = text.substring(1).trimLeft();
    if (text.isEmpty) return false;

    // Skip an XML declaration, comments, processing instructions, and a
    // doctype so `<svg>` can be recognised as the document root. This avoids
    // claiming HTML documents that merely embed an SVG fragment.
    for (var guard = 0; guard < 8; guard++) {
      if (text.startsWith('<?')) {
        final end = text.indexOf('?>');
        if (end < 0) return false;
        text = text.substring(end + 2).trimLeft();
        continue;
      }
      if (text.startsWith('<!--')) {
        final end = text.indexOf('-->');
        if (end < 0) return false;
        text = text.substring(end + 3).trimLeft();
        continue;
      }
      if (text.startsWith('<!DOCTYPE')) {
        final end = text.indexOf('>');
        if (end < 0) return false;
        text = text.substring(end + 1).trimLeft();
        continue;
      }
      break;
    }

    if (!text.startsWith('<svg')) return false;
    if (text.length == 4) return true;
    final next = text.codeUnitAt(4);
    return next == 0x3E ||
        next == 0x2F ||
        next == 0x20 ||
        next == 0x09 ||
        next == 0x0A ||
        next == 0x0D;
  }

  // --- JPEG -----------------------------------------------------------------

  static void _parseJpeg(
    Uint8List bytes,
    Map<String, Object?> metadata,
    List<ParseWarning> warnings,
  ) {
    metadata['mediaType'] = 'image/jpeg';
    metadata['formatFamily'] = 'JPEG';

    var i = 2;
    while (i + 1 < bytes.length) {
      if (bytes[i] != 0xFF) {
        i++;
        continue;
      }
      var markerOffset = i;
      while (markerOffset < bytes.length && bytes[markerOffset] == 0xFF) {
        markerOffset++;
      }
      if (markerOffset >= bytes.length) break;
      final marker = bytes[markerOffset];
      i = markerOffset + 1;

      // Standalone markers carry no length field.
      if (marker == 0xD8 ||
          marker == 0xD9 ||
          marker == 0x01 ||
          (marker >= 0xD0 && marker <= 0xD7)) {
        if (marker == 0xD9) break;
        continue;
      }
      if (marker == 0xDA) break; // start of scan; metadata segments are done
      if (i + 2 > bytes.length) break;
      final length = _u16be(bytes, i);
      if (length < 2) break;
      final segmentStart = i + 2;
      final segmentEnd = i + length;
      if (segmentEnd > bytes.length) break;

      if (marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC) {
        _parseJpegFrame(bytes, segmentStart, segmentEnd, metadata);
      } else if (marker == 0xE1) {
        _parseJpegApp1(bytes, segmentStart, segmentEnd, metadata, warnings);
      } else if (marker == 0xFE) {
        final comment = _ascii(bytes, segmentStart, segmentEnd);
        if (comment.isNotBlank) metadata['comment'] = comment.truncate(4096);
      }
      i = segmentEnd;
    }
  }

  static void _parseJpegFrame(
    Uint8List bytes,
    int start,
    int end,
    Map<String, Object?> metadata,
  ) {
    if (start + 6 > end) return;
    metadata['bitsPerSample'] = bytes[start];
    metadata['height'] = _u16be(bytes, start + 1);
    metadata['width'] = _u16be(bytes, start + 3);
    metadata['componentCount'] = bytes[start + 5];
    final components = bytes[start + 5];
    if (components >= 1 && components <= 4) {
      metadata['colorType'] = switch (components) {
        1 => 'grayscale',
        3 => 'YCbCr',
        4 => 'CMYK',
        _ => '$components-component',
      };
    }
  }

  static void _parseJpegApp1(
    Uint8List bytes,
    int start,
    int end,
    Map<String, Object?> metadata,
    List<ParseWarning> warnings,
  ) {
    if (start + 6 > end) return;
    if (bytes[start] == 0x45 &&
        bytes[start + 1] == 0x78 &&
        bytes[start + 2] == 0x69 &&
        bytes[start + 3] == 0x66 &&
        bytes[start + 4] == 0x00 &&
        bytes[start + 5] == 0x00) {
      _parseExif(
        Uint8List.sublistView(bytes, start + 6, end),
        metadata,
        warnings,
      );
      return;
    }
    const xmpPrefix = 'http://ns.adobe.com/xap/1.0/\x00';
    if (end - start > xmpPrefix.length) {
      final prefix = _ascii(bytes, start, start + xmpPrefix.length);
      if (prefix == xmpPrefix) {
        final xmp = _utf8(bytes, start + xmpPrefix.length, end);
        metadata['xmp'] = xmp.truncate(65536);
        _parseXmpSummary(xmp, metadata);
        return;
      }
    }
    if (bytes[start] == 0x49 &&
        bytes[start + 1] == 0x43 &&
        bytes[start + 2] == 0x43 &&
        bytes[start + 3] == 0x5F) {
      metadata['iccProfileEmbedded'] = true;
    }
  }

  // --- EXIF / TIFF ----------------------------------------------------------

  static void _parseTiff(
    Uint8List bytes,
    Map<String, Object?> metadata,
    List<ParseWarning> warnings,
  ) {
    metadata['mediaType'] = 'image/tiff';
    metadata['formatFamily'] = 'TIFF';
    _parseExif(bytes, metadata, warnings);
  }

  static void _parseExif(
    Uint8List tiff,
    Map<String, Object?> metadata,
    List<ParseWarning> warnings,
  ) {
    if (tiff.length < 8) return;
    final bool little;
    if (tiff[0] == 0x49 && tiff[1] == 0x49) {
      little = true;
    } else if (tiff[0] == 0x4D && tiff[1] == 0x4D) {
      little = false;
    } else {
      return;
    }
    if (_u16(tiff, 2, little) != 42) return;
    final ifd0 = _u32(tiff, 4, little);
    final gpsIfd = _readIfd(tiff, ifd0, little, metadata, warnings, gps: false);
    if (gpsIfd != null) {
      _readIfd(tiff, gpsIfd, little, metadata, warnings, gps: true);
    }
  }

  /// Reads one IFD and returns the GPS IFD offset when present (IFD0 only).
  static int? _readIfd(
    Uint8List tiff,
    int offset,
    bool little,
    Map<String, Object?> metadata,
    List<ParseWarning> warnings, {
    required bool gps,
  }) {
    if (offset < 8 || offset + 2 > tiff.length) return null;
    final count = _u16(tiff, offset, little);
    if (count > 4096) {
      warnings.add(
        const ParseWarning(
          'image.exif_ifd_too_large',
          'EXIF IFD entry count exceeded the safety limit',
        ),
      );
      return null;
    }

    int? gpsIfd;
    var entry = offset + 2;
    for (var i = 0; i < count && entry + 12 <= tiff.length; i++) {
      final tag = _u16(tiff, entry, little);
      final type = _u16(tiff, entry + 2, little);
      final valueCount = _u32(tiff, entry + 4, little);
      final valueField = entry + 8;
      final value = _exifValue(tiff, type, valueCount, valueField, little);

      if (gps) {
        _readGpsTag(
          tiff,
          tag,
          type,
          valueCount,
          valueField,
          little,
          value,
          metadata,
        );
      } else {
        switch (tag) {
          case 0x0100: // ImageWidth
            final width = _exifInteger(
              tiff,
              type,
              valueCount,
              valueField,
              little,
            );
            if (width != null && width > 0) metadata['width'] = width;
          case 0x0101: // ImageLength
            final height = _exifInteger(
              tiff,
              type,
              valueCount,
              valueField,
              little,
            );
            if (height != null && height > 0) metadata['height'] = height;
          case 0x010E: // ImageDescription
            final text = _exifAscii(value);
            if (text.isNotBlank) metadata['description'] = text;
          case 0x010F: // Make
            final text = _exifAscii(value);
            if (text.isNotBlank) metadata['make'] = text;
          case 0x0110: // Model
            final text = _exifAscii(value);
            if (text.isNotBlank) metadata['model'] = text;
          case 0x0112: // Orientation
            final orientation = _exifInteger(
              tiff,
              type,
              valueCount,
              valueField,
              little,
            );
            if (orientation != null) {
              metadata['orientation'] = orientation;
              metadata['orientationDescription'] = _orientationDescription(
                orientation,
              );
            }
          case 0x011A: // XResolution
            final resolution = _exifRational(tiff, value, little);
            if (resolution != null) metadata['xResolution'] = resolution;
          case 0x011B: // YResolution
            final resolution = _exifRational(tiff, value, little);
            if (resolution != null) metadata['yResolution'] = resolution;
          case 0x0128: // ResolutionUnit
            final unit = _exifInteger(
              tiff,
              type,
              valueCount,
              valueField,
              little,
            );
            if (unit != null) metadata['resolutionUnit'] = unit;
          case 0x0131: // Software
            final text = _exifAscii(value);
            if (text.isNotBlank) metadata['software'] = text;
          case 0x0132: // DateTime
            final text = _exifAscii(value);
            if (text.isNotBlank) metadata['datetime'] = text;
          case 0x8769: // Exif IFD pointer
            final exifIfd = _exifInteger(
              tiff,
              type,
              valueCount,
              valueField,
              little,
            );
            if (exifIfd != null) {
              _readExifSubIfd(tiff, exifIfd, little, metadata, warnings);
            }
          case 0x8825: // GPS IFD pointer
            gpsIfd = _exifInteger(tiff, type, valueCount, valueField, little);
        }
      }
      entry += 12;
    }
    return gpsIfd;
  }

  static void _readExifSubIfd(
    Uint8List tiff,
    int offset,
    bool little,
    Map<String, Object?> metadata,
    List<ParseWarning> warnings,
  ) {
    if (offset < 8 || offset + 2 > tiff.length) return;
    final count = _u16(tiff, offset, little);
    if (count > 4096) return;
    var entry = offset + 2;
    for (var i = 0; i < count && entry + 12 <= tiff.length; i++) {
      final tag = _u16(tiff, entry, little);
      final type = _u16(tiff, entry + 2, little);
      final valueCount = _u32(tiff, entry + 4, little);
      final valueField = entry + 8;
      final value = _exifValue(tiff, type, valueCount, valueField, little);
      switch (tag) {
        case 0x829A: // ExposureTime
          final exposure = _exifRational(tiff, value, little);
          if (exposure != null) metadata['exposureTime'] = exposure;
        case 0x829D: // FNumber
          final fNumber = _exifRational(tiff, value, little);
          if (fNumber != null) metadata['fNumber'] = fNumber;
        case 0x8827: // ISO
          final iso = _exifInteger(tiff, type, valueCount, valueField, little);
          if (iso != null) metadata['iso'] = iso;
        case 0x9003: // DateTimeOriginal
          final text = _exifAscii(value);
          if (text.isNotBlank) metadata['datetimeOriginal'] = text;
        case 0x920A: // FocalLength
          final focal = _exifRational(tiff, value, little);
          if (focal != null) metadata['focalLength'] = focal;
        case 0xA002: // PixelXDimension
          final width = _exifInteger(
            tiff,
            type,
            valueCount,
            valueField,
            little,
          );
          if (width != null) metadata['pixelXDimension'] = width;
        case 0xA003: // PixelYDimension
          final height = _exifInteger(
            tiff,
            type,
            valueCount,
            valueField,
            little,
          );
          if (height != null) metadata['pixelYDimension'] = height;
        case 0xA405: // FocalLengthIn35mmFilm
          final focal35 = _exifInteger(
            tiff,
            type,
            valueCount,
            valueField,
            little,
          );
          if (focal35 != null) metadata['focalLengthIn35mm'] = focal35;
      }
      entry += 12;
    }
  }

  static void _readGpsTag(
    Uint8List tiff,
    int tag,
    int type,
    int count,
    int valueField,
    bool little,
    Uint8List? value,
    Map<String, Object?> metadata,
  ) {
    switch (tag) {
      case 0x0000: // GPSVersionID
        if (value != null && value.length >= 4) {
          metadata['gpsVersion'] = value.take(4).join('.');
        }
      case 0x0001:
        final ref = _exifAscii(value);
        if (ref.isNotBlank) metadata['gpsLatitudeRef'] = ref;
      case 0x0002:
        final coordinate = _exifGpsCoordinate(tiff, value, little);
        if (coordinate != null) metadata['gpsLatitude'] = coordinate;
      case 0x0003:
        final ref = _exifAscii(value);
        if (ref.isNotBlank) metadata['gpsLongitudeRef'] = ref;
      case 0x0004:
        final coordinate = _exifGpsCoordinate(tiff, value, little);
        if (coordinate != null) metadata['gpsLongitude'] = coordinate;
      case 0x0005:
        if (value != null && value.isNotEmpty) {
          metadata['gpsAltitudeRef'] = value[0];
        }
      case 0x0006:
        final altitude = _exifRational(tiff, value, little);
        if (altitude != null) metadata['gpsAltitude'] = altitude;
      case 0x001D: // GPSDateStamp
        final text = _exifAscii(value);
        if (text.isNotBlank) metadata['gpsDateStamp'] = text;
    }
  }

  static Uint8List? _exifValue(
    Uint8List tiff,
    int type,
    int count,
    int valueField,
    bool little,
  ) {
    final unit = _exifTypeSize(type);
    if (unit == 0 || count == 0 || count > 0x1000000) return null;
    final size = unit * count;
    if (size <= 4) {
      if (valueField + size > tiff.length) return null;
      return Uint8List.sublistView(tiff, valueField, valueField + size);
    }
    final offset = _u32(tiff, valueField, little);
    if (offset + size > tiff.length) return null;
    return Uint8List.sublistView(tiff, offset, offset + size);
  }

  static int? _exifInteger(
    Uint8List tiff,
    int type,
    int count,
    int valueField,
    bool little,
  ) {
    if (count == 0) return null;
    if (type == 3) {
      return _u16(tiff, valueField, little);
    }
    if (type == 4 || type == 9) {
      return _u32(tiff, valueField, little);
    }
    if (type == 1 && valueField < tiff.length) {
      return tiff[valueField];
    }
    return null;
  }

  static double? _exifRational(Uint8List tiff, Uint8List? value, bool little) {
    if (value == null || value.length < 8) return null;
    final numerator = _u32(value, 0, little);
    final denominator = _u32(value, 4, little);
    if (denominator == 0) return null;
    return numerator / denominator;
  }

  static double? _exifGpsCoordinate(
    Uint8List tiff,
    Uint8List? value,
    bool little,
  ) {
    if (value == null || value.length < 24) return null;
    final degrees = _exifRational(tiff, value.sublist(0, 8), little);
    final minutes = _exifRational(tiff, value.sublist(8, 16), little);
    final seconds = _exifRational(tiff, value.sublist(16, 24), little);
    if (degrees == null) return null;
    return degrees + (minutes ?? 0) / 60 + (seconds ?? 0) / 3600;
  }

  static int _exifTypeSize(int type) => switch (type) {
    1 || 2 || 7 => 1, // BYTE, ASCII, UNDEFINED
    3 || 8 => 2, // SHORT, SSHORT
    4 || 9 || 11 => 4, // LONG, SLONG, FLOAT
    5 || 10 || 12 => 8, // RATIONAL, SRATIONAL, DOUBLE
    _ => 0,
  };

  static String _orientationDescription(int orientation) =>
      switch (orientation) {
        1 => 'normal',
        2 => 'mirror-horizontal',
        3 => 'rotate-180',
        4 => 'mirror-vertical',
        5 => 'mirror-horizontal-rotate-270',
        6 => 'rotate-90',
        7 => 'mirror-horizontal-rotate-90',
        8 => 'rotate-270',
        _ => 'unknown',
      };

  // --- PNG ------------------------------------------------------------------

  static void _parsePng(
    Uint8List bytes,
    Map<String, Object?> metadata,
    List<ParseWarning> warnings,
  ) {
    metadata['mediaType'] = 'image/png';
    metadata['formatFamily'] = 'PNG';

    final textChunks = <String, String>{};
    var i = 8;
    while (i + 12 <= bytes.length) {
      final length = _u32be(bytes, i);
      if (length > bytes.length - i - 12) {
        warnings.add(
          const ParseWarning(
            'image.png_chunk_out_of_bounds',
            'PNG chunk length exceeds the remaining file',
          ),
        );
        break;
      }
      final type = _fourCC(bytes, i + 4);
      final dataStart = i + 8;
      final dataEnd = dataStart + length;

      switch (type) {
        case 'IHDR':
          if (length >= 13) {
            metadata['width'] = _u32be(bytes, dataStart);
            metadata['height'] = _u32be(bytes, dataStart + 4);
            metadata['bitDepth'] = bytes[dataStart + 8];
            metadata['colorType'] = _pngColorName(bytes[dataStart + 9]);
            metadata['compression'] = bytes[dataStart + 10];
            metadata['filter'] = bytes[dataStart + 11];
            metadata['interlace'] = bytes[dataStart + 12];
          }
        case 'pHYs':
          if (length >= 9) {
            metadata['pixelsPerUnitX'] = _u32be(bytes, dataStart);
            metadata['pixelsPerUnitY'] = _u32be(bytes, dataStart + 4);
            metadata['physicalUnit'] = bytes[dataStart + 8] == 1
                ? 'meter'
                : 'unknown';
          }
        case 'gAMA':
          if (length >= 4) {
            final gamma = _u32be(bytes, dataStart);
            if (gamma > 0) metadata['gamma'] = gamma / 100000;
          }
        case 'tEXt':
          if (textChunks.length < 32 && length > 0) {
            final raw = _latin1(bytes, dataStart, dataEnd);
            final zero = raw.indexOf('\x00');
            if (zero > 0 && zero < raw.length - 1) {
              textChunks[raw.substring(0, zero)] = raw
                  .substring(zero + 1)
                  .truncate(8192);
            }
          }
        case 'iTXt':
          if (textChunks.length < 32 && length > 0) {
            final raw = _utf8(bytes, dataStart, dataEnd);
            final parts = raw.split('\x00');
            if (parts.length >= 2 && parts.first.isNotEmpty) {
              textChunks[parts.first] = parts.last.truncate(8192);
            }
          }
        case 'eXIf':
          _parseExif(
            Uint8List.sublistView(bytes, dataStart, dataEnd),
            metadata,
            warnings,
          );
        case 'IEND':
          i = bytes.length;
          continue;
      }
      i = dataEnd + 4; // skip CRC
    }
    if (textChunks.isNotEmpty) metadata['textChunks'] = textChunks;
  }

  static String _pngColorName(int colorType) => switch (colorType) {
    0 => 'grayscale',
    2 => 'RGB',
    3 => 'indexed-color',
    4 => 'grayscale+alpha',
    6 => 'RGBA',
    _ => 'unknown($colorType)',
  };

  // --- GIF ------------------------------------------------------------------

  static void _parseGif(
    Uint8List bytes,
    Map<String, Object?> metadata,
    List<ParseWarning> warnings,
  ) {
    metadata['mediaType'] = 'image/gif';
    metadata['formatFamily'] = 'GIF';
    if (bytes.length < 13) return;

    metadata['width'] = _u16le(bytes, 6);
    metadata['height'] = _u16le(bytes, 8);
    final packed = bytes[10];
    metadata['colorResolution'] = ((packed >> 4) & 0x07) + 1;
    metadata['hasGlobalColorTable'] = (packed & 0x80) != 0;
    metadata['version'] = _ascii(bytes, 0, 6);

    // Walk extensions/comments and count image descriptors without decoding
    // pixel data.
    var i = 13;
    if ((packed & 0x80) != 0) {
      final tableSize = 3 * (1 << ((packed & 0x07) + 1));
      i += tableSize;
    }
    var imageCount = 0;
    var comments = 0;
    while (i + 1 < bytes.length && imageCount < 100000) {
      final block = bytes[i];
      if (block == 0x3B) break; // trailer
      if (block == 0x21) {
        if (i + 2 >= bytes.length) break;
        final label = bytes[i + 1];
        if (label == 0xFE && comments < 32) {
          final text = _gifSubBlocks(bytes, i + 2);
          if (text.text.isNotBlank) {
            metadata['comment${comments == 0 ? '' : comments + 1}'] = text.text
                .truncate(4096);
          }
          comments++;
          i = text.nextOffset;
          continue;
        }
        final skip = _gifSkipSubBlocks(bytes, i + 2);
        if (skip.nextOffset <= i) break;
        i = skip.nextOffset;
        continue;
      }
      if (block == 0x2C) {
        imageCount++;
        if (i + 10 > bytes.length) break;
        final localPacked = bytes[i + 9];
        var next = i + 10;
        if ((localPacked & 0x80) != 0) {
          next += 3 * (1 << ((localPacked & 0x07) + 1));
        }
        if (next >= bytes.length) break;
        next++; // LZW minimum code size
        final skip = _gifSkipSubBlocks(bytes, next);
        if (skip.nextOffset <= i) break;
        i = skip.nextOffset;
        continue;
      }
      break;
    }
    if (imageCount > 0) metadata['frameCount'] = imageCount;
  }

  static _GifText _gifSubBlocks(Uint8List bytes, int offset) {
    final buffer = StringBuffer();
    var i = offset;
    var steps = 0;
    while (i < bytes.length && steps < 100000) {
      final size = bytes[i];
      i++;
      if (size == 0) return _GifText(buffer.toString(), i);
      if (i + size > bytes.length) break;
      buffer.write(_latin1(bytes, i, i + size));
      i += size;
      steps++;
    }
    return _GifText(buffer.toString(), i);
  }

  static _GifSkip _gifSkipSubBlocks(Uint8List bytes, int offset) {
    var i = offset;
    var steps = 0;
    while (i < bytes.length && steps < 100000) {
      final size = bytes[i];
      i++;
      if (size == 0) return _GifSkip(i);
      if (i + size > bytes.length) return _GifSkip(bytes.length);
      i += size;
      steps++;
    }
    return _GifSkip(i);
  }

  // --- WebP -----------------------------------------------------------------

  static void _parseWebp(
    Uint8List bytes,
    Map<String, Object?> metadata,
    List<ParseWarning> warnings,
  ) {
    metadata['mediaType'] = 'image/webp';
    metadata['formatFamily'] = 'WebP';

    var i = 12;
    while (i + 8 <= bytes.length) {
      final type = _fourCC(bytes, i);
      final size = _u32le(bytes, i + 4);
      final dataStart = i + 8;
      if (size > bytes.length - dataStart) {
        warnings.add(
          const ParseWarning(
            'image.webp_chunk_out_of_bounds',
            'WebP chunk length exceeds the remaining file',
          ),
        );
        break;
      }
      final dataEnd = dataStart + size;

      switch (type) {
        case 'VP8X':
          if (size >= 10) {
            metadata['width'] = _u24le(bytes, dataStart + 4) + 1;
            metadata['height'] = _u24le(bytes, dataStart + 7) + 1;
            metadata['extendedFormat'] = true;
          }
        case 'VP8 ':
          if (size >= 10) {
            metadata['width'] = (_u16le(bytes, dataStart + 6) & 0x3FFF);
            metadata['height'] = (_u16le(bytes, dataStart + 8) & 0x3FFF);
            metadata['codec'] = 'VP8';
          }
        case 'VP8L':
          if (size >= 5 && bytes[dataStart] == 0x2F) {
            final b1 = bytes[dataStart + 1];
            final b2 = bytes[dataStart + 2];
            final b3 = bytes[dataStart + 3];
            final b4 = bytes[dataStart + 4];
            metadata['width'] = (((b2 & 0x3F) << 8) | b1) + 1;
            metadata['height'] =
                (((b4 & 0x0F) << 10) | (b3 << 2) | (b2 >> 6)) + 1;
            metadata['codec'] = 'VP8L';
          }
        case 'EXIF':
          _parseExif(
            Uint8List.sublistView(bytes, dataStart, dataEnd),
            metadata,
            warnings,
          );
        case 'XMP ':
          metadata['xmp'] = _utf8(bytes, dataStart, dataEnd).truncate(65536);
          _parseXmpSummary(metadata['xmp']! as String, metadata);
      }
      i = dataEnd + (size & 1); // chunks are padded to even size
    }
  }

  // --- SVG ------------------------------------------------------------------

  static void _parseSvg(
    Uint8List bytes,
    Map<String, Object?> metadata,
    List<ParseWarning> warnings,
  ) {
    metadata['mediaType'] = 'image/svg+xml';
    metadata['formatFamily'] = 'SVG';

    final head = _peekText(bytes, _maxSvgScan);
    if (bytes.length > _maxSvgScan) {
      warnings.add(
        const ParseWarning(
          'image.svg_scan_truncated',
          'SVG metadata scan was limited to 1 MiB',
        ),
      );
    }
    if (!head.contains('<svg', 0)) return;

    final widthMatch = RegExp(
      r'''<svg\b[^>]*\bwidth\s*=\s*["']?([0-9.]+)''',
      caseSensitive: false,
    ).firstMatch(head);
    final heightMatch = RegExp(
      r'''<svg\b[^>]*\bheight\s*=\s*["']?([0-9.]+)''',
      caseSensitive: false,
    ).firstMatch(head);
    if (widthMatch != null) {
      metadata['width'] = double.tryParse(widthMatch.group(1)!);
    }
    if (heightMatch != null) {
      metadata['height'] = double.tryParse(heightMatch.group(1)!);
    }

    final viewBox = RegExp(
      r'''\bviewBox\s*=\s*["']([^"']+)''',
      caseSensitive: false,
    ).firstMatch(head);
    if (viewBox != null) metadata['viewBox'] = viewBox.group(1)!.trim();

    final title = RegExp(
      r'<title[^>]*>(.*?)</title>',
      dotAll: true,
      caseSensitive: false,
    ).firstMatch(head);
    if (title != null) {
      metadata['title'] = title.group(1)!.trim().truncate(4096);
    }
    final description = RegExp(
      r'<desc[^>]*>(.*?)</desc>',
      dotAll: true,
      caseSensitive: false,
    ).firstMatch(head);
    if (description != null) {
      metadata['description'] = description.group(1)!.trim().truncate(8192);
    }
    final svgMetadata = RegExp(
      r'<metadata[^>]*>(.*?)</metadata>',
      dotAll: true,
      caseSensitive: false,
    ).firstMatch(head);
    if (svgMetadata != null) {
      metadata['embeddedMetadata'] = svgMetadata
          .group(1)!
          .trim()
          .truncate(8192);
    }

    if (RegExp(
      r'<\s*script\b|\bon[a-z]+\s*=',
      caseSensitive: false,
    ).hasMatch(head)) {
      warnings.add(
        const ParseWarning(
          'image.svg_script',
          'SVG contains script or event-handler attributes; not executed',
        ),
      );
    }

    final external = <String>[];
    final javascript = <String>[];
    final references = RegExp(
      r'''(?:href|xlink:href)\s*=\s*["']([^"']+)["']''',
      caseSensitive: false,
    );
    for (final match in references.allMatches(head)) {
      final target = match.group(1)!.trim();
      if (target.isEmpty ||
          target.startsWith('#') ||
          target.startsWith('data:')) {
        continue;
      }
      if (target.toLowerCase().startsWith('javascript:')) {
        javascript.add(target);
      } else if (external.length < 256) {
        external.add(target);
      }
    }
    if (external.isNotEmpty) {
      metadata['externalResources'] = external;
      warnings.add(
        ParseWarning(
          'image.svg_external_resources',
          '${external.length} external resource reference(s) were not fetched',
        ),
      );
    }
    if (javascript.isNotEmpty) {
      warnings.add(
        ParseWarning(
          'image.svg_javascript_uri',
          '${javascript.length} javascript: URI reference(s) were not executed',
        ),
      );
    }
  }

  // --- XMP ------------------------------------------------------------------

  static void _parseXmpSummary(String xmp, Map<String, Object?> metadata) {
    if (xmp.isBlank) return;
    final patterns = <String, RegExp>{
      'xmpTitle': RegExp(
        r'<dc:title>.*?<rdf:li[^>]*>(.*?)</rdf:li>',
        dotAll: true,
      ),
      'xmpCreator': RegExp(
        r'<dc:creator>.*?<rdf:li[^>]*>(.*?)</rdf:li>',
        dotAll: true,
      ),
      'xmpCreatorTool': RegExp(
        r'<xmp:CreatorTool>(.*?)</xmp:CreatorTool>',
        dotAll: true,
      ),
      'xmpCreateDate': RegExp(
        r'<xmp:CreateDate>(.*?)</xmp:CreateDate>',
        dotAll: true,
      ),
      'xmpModifyDate': RegExp(
        r'<xmp:ModifyDate>(.*?)</xmp:ModifyDate>',
        dotAll: true,
      ),
    };
    for (final entry in patterns.entries) {
      final match = entry.value.firstMatch(xmp);
      if (match != null) {
        final value = match.group(1)!.trim();
        if (value.isNotBlank) metadata[entry.key] = value.truncate(4096);
      }
    }
  }

  // --- byte helpers ---------------------------------------------------------

  static int _u16(Uint8List b, int o, bool little) {
    if (o + 2 > b.length) return 0;
    return little ? (b[o] | (b[o + 1] << 8)) : ((b[o] << 8) | b[o + 1]);
  }

  static int _u32(Uint8List b, int o, bool little) {
    if (o + 4 > b.length) return 0;
    return little
        ? (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24))
        : ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]);
  }

  static int _u16be(Uint8List b, int o) => _u16(b, o, false);
  static int _u16le(Uint8List b, int o) => _u16(b, o, true);
  static int _u32be(Uint8List b, int o) => _u32(b, o, false);
  static int _u32le(Uint8List b, int o) => _u32(b, o, true);

  static int _u24le(Uint8List b, int o) {
    if (o + 3 > b.length) return 0;
    return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16);
  }

  static String _fourCC(Uint8List bytes, int offset) {
    if (offset + 4 > bytes.length) return '';
    return latin1.decode(
      Uint8List.sublistView(bytes, offset, offset + 4),
      allowInvalid: true,
    );
  }

  static String _ascii(Uint8List bytes, int start, int end) {
    if (start < 0) start = 0;
    if (end > bytes.length) end = bytes.length;
    if (end <= start) return '';
    return latin1
        .decode(Uint8List.sublistView(bytes, start, end), allowInvalid: true)
        .trim();
  }

  static String _latin1(Uint8List bytes, int start, int end) =>
      _ascii(bytes, start, end);

  static String _utf8(Uint8List bytes, int start, int end) {
    if (start < 0) start = 0;
    if (end > bytes.length) end = bytes.length;
    if (end <= start) return '';
    return utf8.decode(
      Uint8List.sublistView(bytes, start, end),
      allowMalformed: true,
    );
  }

  static String _exifAscii(Uint8List? value) {
    if (value == null || value.isEmpty) return '';
    var end = value.length;
    while (end > 0 && value[end - 1] == 0) {
      end--;
    }
    return latin1
        .decode(Uint8List.sublistView(value, 0, end), allowInvalid: true)
        .trim();
  }

  static String _peekText(Uint8List bytes, int max) {
    final end = bytes.length <= max ? bytes.length : max;
    return utf8.decode(
      Uint8List.sublistView(bytes, 0, end),
      allowMalformed: true,
    );
  }
}

final class _GifText {
  const _GifText(this.text, this.nextOffset);

  final String text;
  final int nextOffset;
}

final class _GifSkip {
  const _GifSkip(this.nextOffset);

  final int nextOffset;
}
