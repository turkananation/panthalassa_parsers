import 'dart:convert';
import 'dart:typed_data';

import 'package:panthalassa_parsers/panthalassa_parsers.dart';
import 'package:test/test.dart';

Uint8List u8(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  final reg = ParserRegistry.standard();

  test('HL7 v2 ADT message: delimiters, message type, version, data text', () {
    // MSH defines | ^ ~ \ & ; PID carries patient data.
    final msg =
        'MSH|^~\\&|EPIC|HOSP|LAB|DH|20260115||ADT^A01|MSG00001|P|2.5.1\r'
        'PID|1||MRN12345^^^HOSP||Achieng^Brenda^A||19900101|F\r'
        'PV1|1|I|ICU^101^A';
    final r = reg.parse(u8(msg));
    expect(r.format, DocumentFormat.hl7v2);
    expect(r.metadata['messageType'], 'ADT^A01');
    expect(r.metadata['version'], '2.5.1');
    expect(r.metadata['controlId'], 'MSG00001');
    expect(r.metadata['sendingApplication'], 'EPIC');
    expect((r.metadata['segmentTypes'] as Map)['PID'], 1);
    expect(r.text, contains('Achieng'));
    expect(r.text, contains('Brenda'));
  });

  test('X12 850 purchase order: ISA delimiters, transaction set, elements', () {
    // 106-char ISA, then GS/ST/segments. Element sep '*', component ':', term '~'.
    const isa =
        'ISA*00*          *00*          *ZZ*SENDER         '
        '*ZZ*RECEIVER       *260115*1200*U*00501*000000001*0*P*:~';
    const rest =
        'GS*PO*SENDER*RECEIVER*20260115*1200*1*X*005010~'
        'ST*850*0001~'
        'BEG*00*SA*PO-9981**20260115~'
        'N1*ST*Esambo Interserve Ltd~'
        'PO1*1*10*EA*4.99**VP*WIDGET-001~'
        'SE*6*0001~GE*1*1~IEA*1*000000001~';
    final r = reg.parse(u8(isa + rest));
    expect(r.format, DocumentFormat.x12);
    expect(r.metadata['x12Version'], '00501');
    expect(r.metadata['interchangeControlNumber'], '000000001');
    expect((r.metadata['transactionSets'] as Map)['850'], 1);
    expect((r.metadata['functionalGroups'] as List), contains('PO'));
    expect(r.text, contains('Esambo Interserve Ltd'));
    expect(r.text, contains('WIDGET-001'));
  });

  test('EDIFACT still parses after additions (regression)', () {
    final r = reg.parse(
      u8(
        "UNA:+.? 'UNB+UNOC:3+SENDER+RECEIVER+260115:1200+1'"
        "BGM+220+ORDER-55+9'UNT+2+1'UNZ+1+1'",
      ),
    );
    expect(r.format, DocumentFormat.edifact);
  });
}
