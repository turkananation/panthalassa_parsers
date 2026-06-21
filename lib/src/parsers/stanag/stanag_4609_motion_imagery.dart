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
  static const _st0601LocalSetPrefix = [
    0x06,
    0x0E,
    0x2B,
    0x34,
    0x02,
    0x0B,
    0x01,
    0x01,
    0x0E,
    0x01,
    0x03,
    0x01,
    0x01,
  ];
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

    final payload = _payloadBytes(bytes, packetSize, syncOffset);
    final localSets = _decodeLocalSets(payload);
    final hasKlv =
        localSets.isNotEmpty || _containsSequence(payload, _klvUniversalLabel);
    final sortedPids = pids.toList()..sort();
    final klvMetadata = _flattenKlvMetadata(localSets);

    return StanagParse(
      metadata: {
        'container': 'MPEG-2 TS',
        'packetSize': packetSize,
        'packetCount': packetCount,
        'distinctPidCount': pids.length,
        'pids': sortedPids.take(_maxPidsReported).toList(),
        'hasKlvMetadata': hasKlv,
        if (localSets.isNotEmpty) 'klvLocalSetCount': localSets.length,
        if (localSets.isNotEmpty)
          'klvTags': localSets.expand((set) => set.keys).toSet().toList()
            ..sort(),
        ...klvMetadata,
      },
      text: null, // motion imagery essence, not prose
      warnings: hasKlv
          ? const []
          : const [
              ParseWarning(
                'stanag4609.no_klv',
                'no MISB KLV Universal Label found; metadata may be absent',
              ),
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

  Uint8List _payloadBytes(Uint8List bytes, int packetSize, int syncOffset) {
    final out = BytesBuilder(copy: false);
    for (var i = syncOffset; i + 4 <= bytes.length; i += packetSize) {
      if (bytes[i] != _syncByte) break;
      final adaptationControl = (bytes[i + 3] >> 4) & 0x03;
      if (adaptationControl == 0 || adaptationControl == 2) continue;
      var payloadStart = i + 4;
      if (adaptationControl == 3) {
        if (payloadStart >= bytes.length) continue;
        final adaptationLength = bytes[payloadStart];
        payloadStart += 1 + adaptationLength;
      }
      final packetEnd = (i + packetSize).clamp(0, bytes.length);
      if (payloadStart < packetEnd) {
        out.add(Uint8List.sublistView(bytes, payloadStart, packetEnd));
      }
    }
    return out.toBytes();
  }

  List<Map<int, Uint8List>> _decodeLocalSets(Uint8List payload) {
    final out = <Map<int, Uint8List>>[];
    var searchAt = 0;
    while (searchAt < payload.length) {
      final ul = _indexOf(payload, _st0601LocalSetPrefix, searchAt);
      if (ul == -1 || ul + 16 >= payload.length) break;
      var at = ul + 16; // full 16-byte Universal Label.
      final length = _readBerLength(payload, at);
      if (length == null) break;
      at = length.nextOffset;
      final end = at + length.value;
      if (end > payload.length) break;
      out.add(_decodeLocalSet(Uint8List.sublistView(payload, at, end)));
      searchAt = end;
    }
    return out;
  }

  Map<int, Uint8List> _decodeLocalSet(Uint8List bytes) {
    final out = <int, Uint8List>{};
    var at = 0;
    while (at < bytes.length) {
      final tag = bytes[at++];
      final len = _readBerLength(bytes, at);
      if (len == null) break;
      at = len.nextOffset;
      if (at + len.value > bytes.length) break;
      out[tag] = Uint8List.sublistView(bytes, at, at + len.value);
      at += len.value;
    }
    return out;
  }

  Map<String, Object?> _flattenKlvMetadata(
    List<Map<int, Uint8List>> localSets,
  ) {
    if (localSets.isEmpty) return const {};
    final first = localSets.first;
    final out = <String, Object?>{};
    void putAngle(int tag, String key) {
      final v = first[tag];
      if (v != null && v.length == 2) {
        final raw = ByteData.sublistView(v).getUint16(0, Endian.big);
        out[key] = _round(raw / 65535 * 360);
      }
    }

    void putLat(int tag, String key) {
      final v = first[tag];
      if (v != null && v.length == 4) {
        final raw = ByteData.sublistView(v).getInt32(0, Endian.big);
        out[key] = _round(raw / 2147483647 * 90);
      }
    }

    void putLon(int tag, String key) {
      final v = first[tag];
      if (v != null && v.length == 4) {
        final raw = ByteData.sublistView(v).getInt32(0, Endian.big);
        out[key] = _round(raw / 2147483647 * 180);
      }
    }

    putAngle(5, 'platformHeadingDegrees');
    putLat(13, 'sensorLatitude');
    putLon(14, 'sensorLongitude');
    putLat(23, 'frameCenterLatitude');
    putLon(24, 'frameCenterLongitude');
    final version = first[65];
    if (version != null && version.isNotEmpty) {
      out['uasDatalinkVersion'] = version.first;
    }
    return out;
  }

  ({int value, int nextOffset})? _readBerLength(Uint8List bytes, int offset) {
    if (offset >= bytes.length) return null;
    final first = bytes[offset];
    if ((first & 0x80) == 0) return (value: first, nextOffset: offset + 1);
    final count = first & 0x7F;
    if (count == 0 || count > 4 || offset + 1 + count > bytes.length) {
      return null;
    }
    var value = 0;
    for (var i = 0; i < count; i++) {
      value = (value << 8) | bytes[offset + 1 + i];
    }
    return (value: value, nextOffset: offset + 1 + count);
  }

  int _indexOf(Uint8List haystack, List<int> needle, int start) {
    final last = haystack.length - needle.length;
    for (var i = start; i <= last; i++) {
      var matched = true;
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          matched = false;
          break;
        }
      }
      if (matched) return i;
    }
    return -1;
  }

  double _round(double value) => (value * 10000000).round() / 10000000;
}
