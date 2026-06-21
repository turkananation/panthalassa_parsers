import 'dart:convert';
import 'dart:typed_data';

import '../../core/byte_reader.dart';
import '../../core/parse_result.dart';
import 'stanag_parser.dart';

/// STANAG 7023 — NATO Primary Image Format (NPIF).
///
/// NPIF files in this parser are recognised only by a strict `NPIF` binary
/// header. The parser extracts the edition, declared header length, security
/// classification byte, and a compact segment index. It does not decode image
/// pixels; visual rendering consumes the segment metadata and a future imagery
/// decoder.
final class Stanag7023NpifParser implements StanagSubParser {
  const Stanag7023NpifParser();

  static const _minHeaderLength = 16;

  @override
  String get standard => 'STANAG 7023';

  @override
  bool matches(Uint8List bytes) {
    if (bytes.length < _minHeaderLength) return false;
    return bytes[0] == 0x4E && // N
        bytes[1] == 0x50 && // P
        bytes[2] == 0x49 && // I
        bytes[3] == 0x46; // F
  }

  @override
  StanagParse parse(Uint8List bytes) {
    final r = ByteReader(bytes, endian: Endian.big);
    final magic = ascii.decode(r.readBytes(4), allowInvalid: true);
    final edition = ascii.decode(r.readBytes(4), allowInvalid: true).trim();
    final headerLength = r.readUint32();
    final segmentCount = r.readUint16();
    final classification = r.readUint8();
    r.skip(1); // reserved

    final warnings = <ParseWarning>[];
    if (headerLength > bytes.length) {
      warnings.add(
        ParseWarning(
          'stanag7023.header_length',
          'declared header length $headerLength exceeds input length',
        ),
      );
    }

    final segments = <Map<String, Object?>>[];
    for (var i = 0; i < segmentCount; i++) {
      if (r.remaining < 10) {
        warnings.add(
          ParseWarning(
            'stanag7023.segment_index_truncated',
            'segment index truncated after $i entries',
            offset: r.position,
          ),
        );
        break;
      }
      final type = ascii.decode(r.readBytes(2), allowInvalid: true).trim();
      final subheaderLength = r.readUint32();
      final dataLength = r.readUint32();
      segments.add({
        'type': type,
        'subheaderLength': subheaderLength,
        'dataLength': dataLength,
      });
    }

    return StanagParse(
      metadata: {
        'profile': 'NPIF',
        'magic': magic,
        'edition': edition,
        'headerLength': headerLength,
        'classification': classification,
        'segmentCount': segments.length,
        'segments': segments,
      },
      warnings: warnings,
    );
  }
}
