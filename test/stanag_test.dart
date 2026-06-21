import 'dart:convert';
import 'dart:typed_data';

import 'package:panthalassa_parsers/panthalassa_parsers.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final registry = ParserRegistry.standard();
  Uint8List u(String s) => Uint8List.fromList(utf8.encode(s));

  group('STANAG family detection', () {
    test('all sub-standards resolve to DocumentFormat.stanag', () {
      expect(registry.detect(buildStanag4607Gmti()), DocumentFormat.stanag);
      expect(registry.detect(buildMpegTsWithKlv()), DocumentFormat.stanag);
    });
  });

  test('STANAG 4607 GMTI: packet header + segment enumeration', () {
    final r = registry.parse(buildStanag4607Gmti());
    expect(r.format, DocumentFormat.stanag);
    expect(r.metadata['standard'], 'STANAG 4607');
    expect(r.metadata['nationality'], 'US');
    expect(r.metadata['classification'], 'UNCLASSIFIED');
    expect(r.metadata['platformId'], 'PLATFORM01');
    expect(r.metadata['missionId'], 7);
    expect(r.metadata['segmentCount'], 1);
    final segment = (r.metadata['segments'] as List).first as Map;
    expect(segment['typeName'], 'Dwell');
    final dwell = segment['dwell'] as Map;
    expect(dwell['revisitIndex'], 3);
    expect(dwell['dwellIndex'], 9);
    expect(dwell['lastDwell'], true);
    expect(dwell['targetReportCount'], 1);
    expect(dwell['sensorLatitude'], closeTo(1.25, 0.000001));
    expect(dwell['sensorLongitude'], closeTo(36.75, 0.000001));
    final target = (dwell['targetReports'] as List).single as Map;
    expect(target['reportIndex'], 44);
    expect(target['latitude'], closeTo(1.3, 0.000001));
    expect(target['rangeRateMetersPerSecond'], 12.34);
  });

  test('STANAG 4609: MPEG-2 TS geometry, PIDs, KLV presence', () {
    final r = registry.parse(buildMpegTsWithKlv());
    expect(r.metadata['standard'], 'STANAG 4609');
    expect(r.metadata['container'], 'MPEG-2 TS');
    expect(r.metadata['packetSize'], 188);
    expect(r.metadata['packetCount'], 3);
    expect(r.metadata['distinctPidCount'], 3);
    expect(r.metadata['hasKlvMetadata'], true);
    expect(r.metadata['klvLocalSetCount'], 1);
    expect(r.metadata['platformHeadingDegrees'], closeTo(91, 0.01));
    expect(r.metadata['sensorLatitude'], closeTo(1.25, 0.000001));
    expect(r.metadata['sensorLongitude'], closeTo(36.75, 0.000001));
    expect(r.metadata['frameCenterLatitude'], closeTo(1.3, 0.000001));
    expect(r.metadata['frameCenterLongitude'], closeTo(36.8, 0.000001));
    expect(r.metadata['uasDatalinkVersion'], 17);
  });

  test('STANAG 4609: absence of KLV is reported as a warning', () {
    final r = registry.parse(buildMpegTsWithKlv(withKlv: false));
    expect(r.metadata['hasKlvMetadata'], false);
    expect(r.warnings.map((w) => w.code), contains('stanag4609.no_klv'));
  });

  test('STANAG 4676 NITS: track and track-point counts', () {
    final r = registry.parse(
      u(
        '<?xml version="1.0"?>'
        '<TrackMessage xmlns="urn:nato:stanag:4676:0:3:tracks">'
        '<securityClassification>NATO UNCLASSIFIED</securityClassification>'
        '<Track><trackNumber>TRK-001</trackNumber>'
        '<TrackPoint><time>2026-01-01T00:00:00Z</time><lat>1.0</lat>'
        '<lon>36.0</lon><altitude>1600</altitude><speed>42</speed>'
        '<heading>91</heading></TrackPoint>'
        '<TrackPoint><lat>1.1</lat><lon>36.1</lon>'
        '<vx>3</vx><vy>4</vy><vz>-1</vz></TrackPoint></Track>'
        '<Track><trackNumber>TRK-002</trackNumber>'
        '<TrackPoint><lat>2.0</lat></TrackPoint></Track>'
        '</TrackMessage>',
      ),
    );
    expect(r.metadata['standard'], 'STANAG 4676');
    expect(r.metadata['trackCount'], 2);
    expect(r.metadata['trackPointCount'], 3);
    expect(r.metadata['security'], 'NATO UNCLASSIFIED');
    expect(
      (r.metadata['trackNumbers'] as List),
      containsAll(['TRK-001', 'TRK-002']),
    );
    final tracks = r.metadata['trackKinematics'] as List;
    expect(tracks, hasLength(2));
    final firstPoint = ((tracks.first as Map)['points'] as List).first as Map;
    expect(firstPoint['time'], '2026-01-01T00:00:00Z');
    expect(firstPoint['latitude'], 1.0);
    expect(firstPoint['longitude'], 36.0);
    expect(firstPoint['speed'], 42.0);
    final secondPoint = ((tracks.first as Map)['points'] as List)[1] as Map;
    expect(secondPoint['velocity'], {'x': 3.0, 'y': 4.0, 'z': -1.0});
  });

  test('STANAG 7023 NPIF: header and segment index', () {
    final r = registry.parse(buildStanag7023Npif());
    expect(r.metadata['standard'], 'STANAG 7023');
    expect(r.metadata['profile'], 'NPIF');
    expect(r.metadata['edition'], '0001');
    expect(r.metadata['segmentCount'], 2);
    final segments = r.metadata['segments'] as List;
    expect((segments.first as Map)['type'], 'IM');
    expect((segments.last as Map)['type'], 'TX');
  });

  test('STANAG 5516 Link 16: conservative J-series framing', () {
    final r = registry.parse(buildStanag5516Link16());
    expect(r.metadata['standard'], 'STANAG 5516');
    expect(r.metadata['framing'], 'Panthalassa L16J');
    expect(r.metadata['messageCount'], 2);
    final messages = r.metadata['messages'] as List;
    expect((messages.first as Map)['label'], 'J11.0');
    expect((messages.last as Map)['label'], 'J13.1');
  });

  test('STANAG 4774: confidentiality label fields', () {
    final r = registry.parse(
      u(
        '<?xml version="1.0"?>'
        '<OriginatorConfidentialityLabel '
        'xmlns="urn:nato:stanag:4774:confidentialitymetadatalabel:1:0">'
        '<ConfidentialityInformation>'
        '<PolicyIdentifier>NATO</PolicyIdentifier>'
        '<Classification>NATO SECRET</Classification>'
        '<Category TagName="Releasable To" Type="PERMISSIVE">'
        '<GenericValue>KEN</GenericValue></Category>'
        '</ConfidentialityInformation>'
        '</OriginatorConfidentialityLabel>',
      ),
    );
    expect(r.metadata['standard'], 'STANAG 4774');
    expect(r.metadata['policyIdentifier'], 'NATO');
    expect(r.metadata['classification'], 'NATO SECRET');
    expect((r.metadata['categories'] as List), contains('Releasable To'));
  });

  test('STANAG 4778 binding nesting a 4774 label routes to 4778, not 4774', () {
    final r = registry.parse(
      u(
        '<?xml version="1.0"?>'
        '<BindingInformation '
        'xmlns="urn:nato:stanag:4778:bindinginformation:1:0" '
        'xmlns:ds="http://www.w3.org/2000/09/xmldsig#">'
        '<MetadataBinding>'
        '<Metadata><OriginatorConfidentialityLabel>'
        '<ConfidentialityInformation><Classification>NATO SECRET</Classification>'
        '</ConfidentialityInformation></OriginatorConfidentialityLabel></Metadata>'
        '<ds:Signature><ds:SignatureValue>abc123</ds:SignatureValue></ds:Signature>'
        '</MetadataBinding>'
        '</BindingInformation>',
      ),
    );
    expect(r.metadata['standard'], 'STANAG 4778');
    expect(r.metadata['bindingCount'], 1);
    expect(r.metadata['hasConfidentialityLabel'], true);
    expect(r.metadata['hasSignature'], true);
  });
}
