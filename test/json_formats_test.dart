import 'dart:convert';
import 'dart:typed_data';

import 'package:panthalassa_parsers/panthalassa_parsers.dart';
import 'package:test/test.dart';

Uint8List u8(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  final reg = ParserRegistry.standard();

  test('FHIR JSON resource is detected and text extracted', () {
    final r = reg.parse(
      u8('''
{"resourceType":"Patient","id":"p1",
 "name":[{"family":"Mwema","given":["Asha"]}],
 "meta":{"profile":["http://hl7.org/fhir/StructureDefinition/Patient"]}}'''),
    );
    expect(r.format, DocumentFormat.fhirJson);
    expect(r.metadata['resourceType'], 'Patient');
    expect(r.metadata['id'], 'p1');
    expect(r.text, contains('Mwema'));
    expect(r.text, contains('Asha'));
  });

  test('FHIR NDJSON bulk export counts records', () {
    final r = reg.parse(
      u8(
        '{"resourceType":"Patient","id":"a"}\n'
        '{"resourceType":"Observation","id":"b"}\n'
        '{"resourceType":"Patient","id":"c"}\n',
      ),
    );
    expect(r.format, DocumentFormat.fhirJson);
    expect(r.metadata['ndjson'], true);
    expect(r.metadata['recordCount'], 3);
    expect((r.metadata['resourceTypes'] as Map)['Patient'], 2);
  });

  test('W3C Verifiable Credential (JSON-LD) is detected', () {
    final r = reg.parse(
      u8('''
{"@context":["https://www.w3.org/2018/credentials/v1"],
 "type":["VerifiableCredential","UniversityDegreeCredential"],
 "issuer":{"id":"did:example:kenya-gov"},
 "issuanceDate":"2026-01-15T00:00:00Z",
 "credentialSubject":{"degree":{"name":"Bachelor of Civic Tech"}},
 "proof":{"type":"Ed25519Signature2020"}}'''),
    );
    expect(r.format, DocumentFormat.verifiableCredential);
    expect(r.metadata['serialization'], 'json-ld');
    expect(r.metadata['issuer'], 'did:example:kenya-gov');
    expect(r.metadata['hasProof'], true);
    expect(r.text, contains('Bachelor of Civic Tech'));
  });

  test('Verifiable Credential as a JWT decodes the payload', () {
    String seg(Map<String, Object?> m) =>
        base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
    final header = seg({'alg': 'EdDSA', 'typ': 'JWT'});
    final payload = seg({
      'iss': 'did:example:issuer',
      'sub': 'did:example:holder',
      'vc': {
        'type': ['VerifiableCredential'],
        'credentialSubject': {'alumniOf': 'Turkana University'},
      },
    });
    final jwt = '$header.$payload.c2lnbmF0dXJl';
    final r = reg.parse(u8(jwt));
    expect(r.format, DocumentFormat.verifiableCredential);
    expect(r.metadata['serialization'], 'jwt');
    expect(r.metadata['alg'], 'EdDSA');
    expect(r.metadata['issuer'], 'did:example:issuer');
    expect(r.metadata['signed'], true);
    expect(r.text, contains('Turkana University'));
  });

  test('generic JSON falls through to the JSON engine', () {
    final r = reg.parse(u8('{"title":"Quarterly Report","items":["a","b"]}'));
    expect(r.format, DocumentFormat.json);
    expect(r.text, contains('Quarterly Report'));
    expect(
      (r.metadata['topLevelKeys'] as List),
      containsAll(['title', 'items']),
    );
  });

  test('NIEM JSON profile is recognised', () {
    final r = reg.parse(
      u8(
        '{"@context":{"nc":"http://release.niem.gov/niem/niem-core/5.0/"},'
        '"nc:Person":{"nc:PersonName":{"nc:PersonFullName":"Wanjiru Kamau"}}}',
      ),
    );
    expect(r.format, DocumentFormat.niem);
    expect(r.metadata['profile'], 'NIEM JSON');
    expect(r.text, contains('Wanjiru Kamau'));
  });
}
