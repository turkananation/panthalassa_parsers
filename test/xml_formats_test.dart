import 'dart:convert';
import 'dart:typed_data';

import 'package:panthalassa_parsers/panthalassa_parsers.dart';
import 'package:test/test.dart';

Uint8List u8(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  final reg = ParserRegistry.standard();

  test('HL7 CDA (v3) clinical document is detected', () {
    final r = reg.parse(
      u8('''<?xml version="1.0"?>
<ClinicalDocument xmlns="urn:hl7-org:v3">
  <templateId root="2.16.840.1.113883.10.20.22.1.1"/>
  <code code="34133-9" displayName="Summarization of Episode Note"/>
  <title>Continuity of Care Document</title>
  <effectiveTime value="20260115"/>
  <component><structuredBody><component><section>
    <title>Allergies</title><text>No known allergies</text>
  </section></component></structuredBody></component>
</ClinicalDocument>'''),
    );
    expect(r.format, DocumentFormat.cda);
    expect(r.metadata['title'], 'Continuity of Care Document');
    expect(r.metadata['documentType'], 'Summarization of Episode Note');
    expect(r.metadata['sectionCount'], 1);
    expect(r.text, contains('No known allergies'));
  });

  test('ISO 20022 payment message is detected with its message definition', () {
    final r = reg.parse(
      u8('''<?xml version="1.0"?>
<Document xmlns="urn:iso:std:iso:20022:tech:xsd:pain.001.001.09">
  <CstmrCdtTrfInitn><GrpHdr><MsgId>MSG-001</MsgId>
  <InitgPty><Nm>Esambo Interserve Ltd</Nm></InitgPty></GrpHdr></CstmrCdtTrfInitn>
</Document>'''),
    );
    expect(r.format, DocumentFormat.iso20022);
    expect(r.metadata['messageDefinition'], 'pain.001.001.09');
    expect(r.metadata['messageFamily'], 'pain');
    expect(r.metadata['businessArea'], 'CstmrCdtTrfInitn');
    expect(r.text, contains('Esambo Interserve Ltd'));
  });

  test('generic XML falls through to the XML engine', () {
    final r = reg.parse(u8('<note><to>Team</to><body>Ship it</body></note>'));
    expect(r.format, DocumentFormat.xml);
    expect(r.metadata['rootElement'], 'note');
    expect(r.text, contains('Ship it'));
  });

  test('NIEM XML profile is recognised', () {
    final r = reg.parse(
      u8('''<?xml version="1.0"?>
<exch:Message xmlns:exch="http://example.gov/exchange"
  xmlns:nc="http://release.niem.gov/niem/niem-core/5.0/">
  <nc:Person><nc:PersonName><nc:PersonFullName>Otieno Were</nc:PersonFullName>
  </nc:PersonName></nc:Person>
</exch:Message>'''),
    );
    expect(r.format, DocumentFormat.niem);
    expect(r.metadata['profile'], 'NIEM XML');
    expect(r.text, contains('Otieno Were'));
  });

  test('FHIR XML still detected after refactor (regression)', () {
    final r = reg.parse(
      u8('''<?xml version="1.0"?>
<Patient xmlns="http://hl7.org/fhir"><id value="p9"/>
<name><family value="Kiprop"/></name></Patient>'''),
    );
    expect(r.format, DocumentFormat.fhirXml);
    expect(r.metadata['resourceType'], 'Patient');
    expect(r.text, contains('Kiprop'));
  });
}
