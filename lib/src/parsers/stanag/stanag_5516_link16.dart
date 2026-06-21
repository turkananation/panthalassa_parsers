import 'dart:convert';
import 'dart:typed_data';

import '../../core/byte_reader.dart';
import '../../core/parse_result.dart';
import 'stanag_parser.dart';

/// STANAG 5516 / Link 16 / TADIL-J framing parser.
///
/// Raw Link 16 radio traffic has no safe file magic. To avoid false positives,
/// this parser recognises only a conservative `L16J` framed interchange used by
/// Panthalassa tooling and test fixtures: a tiny header followed by fixed-size
/// packed J-series words. It reports framing metadata and message labels, not
/// tactical semantic fields.
final class Stanag5516Link16Parser implements StanagSubParser {
  const Stanag5516Link16Parser();

  static const _minHeaderLength = 8;
  static const _defaultWordLength = 10;

  @override
  String get standard => 'STANAG 5516';

  @override
  bool matches(Uint8List bytes) {
    if (bytes.length < _minHeaderLength) return false;
    return bytes[0] == 0x4C && // L
        bytes[1] == 0x31 && // 1
        bytes[2] == 0x36 && // 6
        bytes[3] == 0x4A; // J
  }

  @override
  StanagParse parse(Uint8List bytes) {
    final r = ByteReader(bytes, endian: Endian.big);
    final magic = ascii.decode(r.readBytes(4), allowInvalid: true);
    final version = r.readUint8();
    final wordLength = r.readUint8();
    final messageCount = r.readUint16();
    final effectiveWordLength = wordLength == 0
        ? _defaultWordLength
        : wordLength;

    final warnings = <ParseWarning>[];
    final messages = <Map<String, Object?>>[];
    for (var i = 0; i < messageCount; i++) {
      if (r.remaining < effectiveWordLength) {
        warnings.add(
          ParseWarning(
            'stanag5516.truncated_message',
            'message stream truncated after $i messages',
            offset: r.position,
          ),
        );
        break;
      }
      final word = r.readBytes(effectiveWordLength);
      final series = (word.first >> 3) & 0x1F;
      final subseries = word.first & 0x07;
      messages.add({
        'index': i,
        'label': 'J$series.$subseries',
        'rawHex': _hex(word),
      });
    }

    return StanagParse(
      metadata: {
        'profile': 'Link 16 / TADIL-J',
        'magic': magic,
        'framing': 'Panthalassa L16J',
        'version': version,
        'wordLength': effectiveWordLength,
        'declaredMessageCount': messageCount,
        'messageCount': messages.length,
        'messages': messages,
      },
      warnings: warnings,
    );
  }

  String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
