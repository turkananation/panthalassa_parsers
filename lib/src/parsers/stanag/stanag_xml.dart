import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../../core/parse_exception.dart';
import 'stanag_parser.dart';

/// Shared helpers for XML-based STANAG standards.
class _XmlPeek {
  /// Returns up to [max] bytes decoded as text iff the slice looks like XML.
  static String? text(Uint8List bytes, [int max = 4096]) {
    final slice = bytes.length <= max
        ? bytes
        : Uint8List.sublistView(bytes, 0, max);
    final t = utf8.decode(slice, allowMalformed: true);
    final trimmed = t.trimLeft();
    if (!trimmed.startsWith('<?xml') && !trimmed.startsWith('<')) return null;
    return t;
  }

  /// The local name of the first element (namespace prefix stripped).
  static String? firstElementLocalName(String xml) {
    var body = xml.trimLeft();
    if (body.startsWith('<?xml')) {
      body = body.replaceFirst(RegExp(r'<\?xml.*?\?>', dotAll: true), '');
    }
    final m = RegExp(r'<\s*([A-Za-z_][\w.\-]*)').firstMatch(body);
    final raw = m?.group(1);
    if (raw == null) return null;
    final colon = raw.indexOf(':');
    return colon == -1 ? raw : raw.substring(colon + 1);
  }

  static XmlDocument parse(Uint8List bytes, String standard) {
    try {
      return XmlDocument.parse(utf8.decode(bytes));
    } on XmlException catch (e) {
      throw MalformedDocumentException('invalid $standard XML: ${e.message}');
    } on FormatException catch (e) {
      throw TextDecodingException(
        '$standard XML is not valid UTF-8: ${e.message}',
      );
    }
  }
}

/// STANAG 4676 — NATO ISR Tracking Standard (NITS).
///
/// An XML/GML message describing tracks and track points. Recognised by its
/// message root or the 4676 namespace; reports track and track-point counts and
/// any security marking. Per-point kinematics extraction is an extension point.
final class Stanag4676TrackingParser implements StanagSubParser {
  const Stanag4676TrackingParser();

  static const _roots = {
    'TrackMessage',
    'TrackMessageType',
    'NITS',
    'TrackCollection',
  };

  @override
  String get standard => 'STANAG 4676';

  @override
  bool matches(Uint8List bytes) {
    final xml = _XmlPeek.text(bytes);
    if (xml == null) return false;
    final root = _XmlPeek.firstElementLocalName(xml);
    if (root != null && _roots.contains(root)) return true;
    return xml.contains('4676') && xml.contains('Track');
  }

  @override
  StanagParse parse(Uint8List bytes) {
    final doc = _XmlPeek.parse(bytes, standard);
    final tracks = doc.findAllElements('Track', namespace: '*').length;
    final points =
        doc.findAllElements('TrackPoint', namespace: '*').length +
        doc.findAllElements('TrackPointDetail', namespace: '*').length;
    final security = doc
        .findAllElements('securityClassification', namespace: '*')
        .firstOrNull
        ?.innerText
        .trim();
    final source = doc
        .findAllElements('trackSource', namespace: '*')
        .firstOrNull
        ?.innerText
        .trim();

    final ids = doc
        .findAllElements('trackNumber', namespace: '*')
        .map((e) => e.innerText.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final kinematics = _trackKinematics(doc);

    return StanagParse(
      metadata: {
        'trackCount': tracks,
        'trackPointCount': points,
        if (security != null && security.isNotEmpty) 'security': security,
        if (source != null && source.isNotEmpty) 'source': source,
        if (ids.isNotEmpty) 'trackNumbers': ids,
        if (kinematics.isNotEmpty) 'trackKinematics': kinematics,
      },
      text: ids.isEmpty ? null : ids.join('\n'),
    );
  }

  List<Map<String, Object?>> _trackKinematics(XmlDocument doc) {
    final tracks = doc.findAllElements('Track', namespace: '*');
    final out = <Map<String, Object?>>[];
    for (final track in tracks) {
      final trackNumber = _firstText(track, const [
        'trackNumber',
        'trackId',
        'id',
      ]);
      final points = <Map<String, Object?>>[];
      final pointElements = [
        ...track.findElements('TrackPoint', namespace: '*'),
        ...track.findElements('TrackPointDetail', namespace: '*'),
      ];
      for (final point in pointElements) {
        final parsed = <String, Object?>{};
        final time = _firstText(point, const ['time', 'timestamp', 'Time']);
        if (time != null) parsed['time'] = time;
        final lat = _firstDouble(point, const ['lat', 'latitude', 'Latitude']);
        final lon = _firstDouble(point, const [
          'lon',
          'longitude',
          'Longitude',
        ]);
        final alt = _firstDouble(point, const ['alt', 'altitude', 'elevation']);
        final speed = _firstDouble(point, const ['speed', 'groundSpeed']);
        final heading = _firstDouble(point, const ['heading', 'course']);
        if (lat != null) parsed['latitude'] = lat;
        if (lon != null) parsed['longitude'] = lon;
        if (alt != null) parsed['altitude'] = alt;
        if (speed != null) parsed['speed'] = speed;
        if (heading != null) parsed['heading'] = heading;
        final vx = _firstDouble(point, const [
          'vx',
          'velocityX',
          'eastVelocity',
        ]);
        final vy = _firstDouble(point, const [
          'vy',
          'velocityY',
          'northVelocity',
        ]);
        final vz = _firstDouble(point, const [
          'vz',
          'velocityZ',
          'verticalVelocity',
        ]);
        if (vx != null || vy != null || vz != null) {
          parsed['velocity'] = {
            'x': ?vx,
            'y': ?vy,
            'z': ?vz,
          };
        }
        if (parsed.isNotEmpty) points.add(parsed);
      }
      if (points.isNotEmpty) {
        out.add({
          'trackNumber': ?trackNumber,
          'points': points,
        });
      }
    }
    return out;
  }

  String? _firstText(XmlElement parent, List<String> names) {
    for (final name in names) {
      final value = parent
          .findElements(name, namespace: '*')
          .firstOrNull
          ?.innerText
          .trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  double? _firstDouble(XmlElement parent, List<String> names) {
    final text = _firstText(parent, names);
    return text == null ? null : double.tryParse(text);
  }
}

/// STANAG 4774 — Confidentiality Metadata Label Syntax.
///
/// An XML label binding a classification and categories to a piece of data.
/// Recognised strictly by the `OriginatorConfidentialityLabel` root so that a
/// 4778 container nesting such a label is not misrouted here.
final class Stanag4774LabelParser implements StanagSubParser {
  const Stanag4774LabelParser();

  static const _root = 'OriginatorConfidentialityLabel';

  @override
  String get standard => 'STANAG 4774';

  @override
  bool matches(Uint8List bytes) {
    final xml = _XmlPeek.text(bytes);
    if (xml == null) return false;
    return _XmlPeek.firstElementLocalName(xml) == _root;
  }

  @override
  StanagParse parse(Uint8List bytes) {
    final doc = _XmlPeek.parse(bytes, standard);
    final policy = doc
        .findAllElements('PolicyIdentifier', namespace: '*')
        .firstOrNull
        ?.innerText
        .trim();
    final classification = doc
        .findAllElements('Classification', namespace: '*')
        .firstOrNull
        ?.innerText
        .trim();
    final categories = doc
        .findAllElements('Category', namespace: '*')
        .map(
          (e) =>
              e.getAttribute('TagName') ??
              e.getAttribute('Type') ??
              e.innerText.trim(),
        )
        .where((s) => s.isNotEmpty)
        .toList();

    return StanagParse(
      metadata: {
        if (policy != null && policy.isNotEmpty) 'policyIdentifier': policy,
        if (classification != null && classification.isNotEmpty)
          'classification': classification,
        if (categories.isNotEmpty) 'categories': categories,
      },
      text: classification,
    );
  }
}

/// STANAG 4778 — Metadata Binding Mechanism.
///
/// An XML container that cryptographically binds metadata (often a 4774 label)
/// to data, typically carrying an XML-DSig signature. Recognised by its binding
/// container root; reports the binding count and whether a label and signature
/// are present. Signature verification is out of scope for a parser.
final class Stanag4778BindingParser implements StanagSubParser {
  const Stanag4778BindingParser();

  static const _roots = {
    'BindingInformation',
    'BindingInformationType',
    'MetadataBindingContainer',
    'OriginatorConfidentialityLabelledData',
  };

  @override
  String get standard => 'STANAG 4778';

  @override
  bool matches(Uint8List bytes) {
    final xml = _XmlPeek.text(bytes);
    if (xml == null) return false;
    final root = _XmlPeek.firstElementLocalName(xml);
    if (root != null && _roots.contains(root)) return true;
    return xml.contains('4778') && xml.contains('Binding');
  }

  @override
  StanagParse parse(Uint8List bytes) {
    final doc = _XmlPeek.parse(bytes, standard);
    final bindings =
        doc.findAllElements('Binding', namespace: '*').length +
        doc.findAllElements('MetadataBinding', namespace: '*').length;
    final hasLabel = doc
        .findAllElements('OriginatorConfidentialityLabel', namespace: '*')
        .isNotEmpty;
    final hasSignature = doc
        .findAllElements('Signature', namespace: '*')
        .isNotEmpty;

    return StanagParse(
      metadata: {
        'bindingCount': bindings,
        'hasConfidentialityLabel': hasLabel,
        'hasSignature': hasSignature,
      },
      text: null,
    );
  }
}
