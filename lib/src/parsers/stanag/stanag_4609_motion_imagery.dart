import 'dart:typed_data';

import '../../core/parse_result.dart';
import 'stanag_parser.dart';

/// STANAG 4609 — NATO Digital Motion Imagery Standard.
///
/// 4609 essence is carried in an MPEG-2 Transport Stream (MISB ST 0601 KLV
/// metadata multiplexed alongside the video elementary stream). Recognition
/// validates the TS sync-byte cadence (0x47 every 188 bytes, or every 192 for
/// timecode-prefixed M2TS). The parser reports the packet geometry, the distinct
/// PIDs present, and whether MISB KLV metadata is present (detected by the SMPTE
/// Universal Label prefix). Decoding KLV values and the video essence is an
/// extension point — this layer establishes structure and metadata presence.
final class Stanag4609MotionImageryParser implements StanagSubParser {
  const Stanag4609MotionImageryParser();

  static const _syncByte = 0x47;
  // SMPTE 336M Universal Label prefix used by all MISB KLV local/universal sets.
  static const _klvUniversalLabel = [0x06, 0x0E, 0x2B, 0x34];
  static const _maxPidsReported = 32;

  @override
  String get standard => 'STANAG 4609';

  @override
  bool matches(Uint8List bytes) => _detectGeometry(bytes) != null;

  @override
  StanagParse parse(Uint8List bytes) {
    final geometry = _detectGeometry(bytes);
    if (geometry == null) {
      // matches() gates this, but stay defensive.
      return const StanagParse(metadata: {'container': 'unknown'});
    }
    final (packetSize, syncOffset) = geometry;

    final pids = <int>{};
    var packetCount = 0;
    for (var i = syncOffset; i + 3 < bytes.length; i += packetSize) {
      if (bytes[i] != _syncByte) break; // resync lost; stop counting
      final pid = ((bytes[i + 1] & 0x1F) << 8) | bytes[i + 2];
      pids.add(pid);
      packetCount++;
    }

    final hasKlv = _containsSequence(bytes, _klvUniversalLabel);
    final sortedPids = pids.toList()..sort();

    return StanagParse(
      metadata: {
        'container': 'MPEG-2 TS',
        'packetSize': packetSize,
        'packetCount': packetCount,
        'distinctPidCount': pids.length,
        'pids': sortedPids.take(_maxPidsReported).toList(),
        'hasKlvMetadata': hasKlv,
      },
      text: null, // motion imagery essence, not prose
      warnings: hasKlv
          ? const []
          : const [
              ParseWarning('stanag4609.no_klv',
                  'no MISB KLV Universal Label found; metadata may be absent'),
            ],
    );
  }

  /// Returns `(packetSize, syncOffset)` if the buffer looks like an MPEG-2 TS
  /// (sync byte at a consistent cadence), else `null`.
  (int, int)? _detectGeometry(Uint8List bytes) {
    // 188-byte standard TS: sync at offset 0.
    if (_syncsAt(bytes, 0, 188)) return (188, 0);
    // 192-byte M2TS: 4-byte timecode prefix, sync at offset 4.
    if (_syncsAt(bytes, 4, 192)) return (192, 4);
    // 204-byte TS with Reed-Solomon FEC: sync at offset 0.
    if (_syncsAt(bytes, 0, 204)) return (204, 0);
    return null;
  }

  bool _syncsAt(Uint8List b, int offset, int size) {
    if (b.length < offset + size * 2 + 1) return false;
    return b[offset] == _syncByte &&
        b[offset + size] == _syncByte &&
        b[offset + size * 2] == _syncByte;
  }

  bool _containsSequence(Uint8List haystack, List<int> needle) {
    if (needle.isEmpty || haystack.length < needle.length) return false;
    final last = haystack.length - needle.length;
    for (var i = 0; i <= last; i++) {
      var matched = true;
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          matched = false;
          break;
        }
      }
      if (matched) return true;
    }
    return false;
  }
}
