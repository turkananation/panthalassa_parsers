import 'dart:convert';
import 'dart:typed_data';

import '../../core/byte_reader.dart';
import '../../core/parse_result.dart';
import 'stanag_parser.dart';

/// STANAG 4607 — Ground Moving Target Indicator (GMTI) Format.
///
/// A binary packet with a 32-byte header followed by typed segments (Mission,
/// Dwell, Target Report, …). There is no ASCII magic number, so recognition
/// validates the shape of the packet header: the declared packet size must equal
/// the buffer length (single-packet case), the nationality must be two ASCII
/// letters, and the classification must fall in the defined range. Segment
/// payloads are enumerated by type/size. Common Mission, Dwell, Target Report,
/// Job Definition, and Free Text bodies are decoded when present; unknown or
/// shorter bodies remain safely summarised by type and size.
final class Stanag4607GmtiParser implements StanagSubParser {
  const Stanag4607GmtiParser();

  static const _packetHeaderLength = 32;

  static const _classifications = <int, String>{
    1: 'TOP SECRET',
    2: 'SECRET',
    3: 'CONFIDENTIAL',
    4: 'RESTRICTED',
    5: 'UNCLASSIFIED',
  };

  static const _segmentTypes = <int, String>{
    1: 'Mission',
    2: 'Dwell',
    3: 'HRR',
    5: 'Job Definition',
    6: 'Free Text',
    7: 'Low Reflectivity Index',
    8: 'Group',
    9: 'Attached Target',
    10: 'Test and Status',
    11: 'System-Specific',
    12: 'Processing History',
    13: 'Platform Location',
    101: 'Job Request',
    102: 'Job Acknowledge',
  };

  @override
  String get standard => 'STANAG 4607';

  @override
  bool matches(Uint8List bytes) {
    if (bytes.length < _packetHeaderLength) return false;
    final bd = ByteData.sublistView(bytes);
    if (bd.getUint32(2, Endian.big) != bytes.length) {
      return false; // packet size
    }
    // Header layout: version(0..2) size(2..6) nationality(6..8) classification(8).
    if (!_isUpperAscii(bytes[6]) || !_isUpperAscii(bytes[7])) return false;
    return _classifications.containsKey(bytes[8]);
  }

  @override
  StanagParse parse(Uint8List bytes) {
    final r = ByteReader(bytes, endian: Endian.big);

    final versionId = ascii.decode(r.readBytes(2), allowInvalid: true);
    final packetSize = r.readUint32();
    final nationality = ascii.decode(r.readBytes(2), allowInvalid: true);
    final classification = r.readUint8();
    final classificationSystem = ascii
        .decode(r.readBytes(2), allowInvalid: true)
        .trim();
    r.skip(2); // classification code/control flags
    final exerciseIndicator = r.readUint8();
    final platformId = ascii.decode(r.readBytes(10), allowInvalid: true).trim();
    final missionId = r.readUint32();
    final jobId = r.readUint32();

    final warnings = <ParseWarning>[];
    final segments = <Map<String, Object?>>[];
    while (r.remaining >= 5) {
      final type = r.readUint8();
      final size = r.readUint32();
      if (size < 5 || size - 5 > r.remaining) {
        warnings.add(
          ParseWarning(
            'stanag4607.bad_segment',
            'segment size $size invalid',
            offset: r.position,
          ),
        );
        break;
      }
      final body = r.readBytes(size - 5);
      segments.add({
        'type': type,
        'typeName': _segmentTypes[type] ?? 'Unknown',
        'size': size,
        ..._decodeSegmentBody(type, body, warnings, r.position - body.length),
      });
    }

    return StanagParse(
      metadata: {
        'profile': 'GMTI',
        'versionId': versionId,
        'packetSize': packetSize,
        'nationality': nationality,
        'classification': _classifications[classification] ?? 'Unknown',
        'classificationSystem': classificationSystem,
        'exercise': exerciseIndicator != 0,
        'platformId': platformId,
        'missionId': missionId,
        'jobId': jobId,
        'segmentCount': segments.length,
        'segments': segments,
      },
      text: null, // radar/track data, not prose
      warnings: warnings,
    );
  }

  Map<String, Object?> _decodeSegmentBody(
    int type,
    Uint8List body,
    List<ParseWarning> warnings,
    int offset,
  ) {
    try {
      return switch (type) {
        1 => _decodeMission(body),
        2 => _decodeDwell(body),
        5 => _decodeJobDefinition(body),
        6 => _decodeFreeText(body),
        _ => const {},
      };
    } catch (e) {
      warnings.add(
        ParseWarning(
          'stanag4607.segment_body',
          'segment body decode failed for type $type: $e',
          offset: offset,
        ),
      );
      return const {};
    }
  }

  Map<String, Object?> _decodeMission(Uint8List body) {
    final text = ascii.decode(body, allowInvalid: true).trim();
    if (text.isEmpty) return const {};
    return {'missionText': text};
  }

  Map<String, Object?> _decodeJobDefinition(Uint8List body) {
    if (body.length < 5) return const {};
    final r = ByteReader(body, endian: Endian.big);
    final jobDefinitionId = r.readUint32();
    final priority = r.readUint8();
    final sensor = r.remaining == 0
        ? null
        : ascii.decode(r.readBytes(r.remaining), allowInvalid: true).trim();
    return {
      'jobDefinition': {
        'jobDefinitionId': jobDefinitionId,
        'priority': priority,
        if (sensor != null && sensor.isNotEmpty) 'sensor': sensor,
      },
    };
  }

  Map<String, Object?> _decodeFreeText(Uint8List body) {
    final text = ascii.decode(body, allowInvalid: true).trim();
    return text.isEmpty ? const {} : {'freeText': text};
  }

  Map<String, Object?> _decodeDwell(Uint8List body) {
    if (body.length < 27) return const {};
    final r = ByteReader(body, endian: Endian.big);
    final maskHi = r.readUint32();
    final maskLo = r.readUint32();
    final revisitIndex = r.readUint16();
    final dwellIndex = r.readUint16();
    final lastDwell = r.readUint8() != 0;
    final targetReportCount = r.readUint16();
    final sensorLatitude = _scaledLatitude(r.readInt32());
    final sensorLongitude = _scaledLongitude(r.readInt32());
    final sensorAltitudeMeters = r.readInt32();

    final targetReports = <Map<String, Object?>>[];
    while (targetReports.length < targetReportCount && r.remaining >= 18) {
      targetReports.add({
        'reportIndex': r.readUint16(),
        'latitude': _scaledLatitude(r.readInt32()),
        'longitude': _scaledLongitude(r.readInt32()),
        'heightMeters': r.readInt32(),
        'rangeRateMetersPerSecond': r.readInt16() / 100,
        'crossRangeRateMetersPerSecond': r.readInt16() / 100,
      });
    }

    return {
      'dwell': {
        'existenceMask': '${_hex32(maskHi)}${_hex32(maskLo)}',
        'revisitIndex': revisitIndex,
        'dwellIndex': dwellIndex,
        'lastDwell': lastDwell,
        'targetReportCount': targetReportCount,
        'sensorLatitude': sensorLatitude,
        'sensorLongitude': sensorLongitude,
        'sensorAltitudeMeters': sensorAltitudeMeters,
        if (targetReports.isNotEmpty) 'targetReports': targetReports,
      },
    };
  }

  double _scaledLatitude(int raw) => _round(raw / 2147483647 * 90);
  double _scaledLongitude(int raw) => _round(raw / 2147483647 * 180);
  double _round(double value) => (value * 10000000).round() / 10000000;

  String _hex32(int value) =>
      value.toRadixString(16).padLeft(8, '0').toUpperCase();

  bool _isUpperAscii(int b) => b >= 0x41 && b <= 0x5A;
}
