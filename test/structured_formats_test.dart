import 'dart:convert';
import 'dart:typed_data';

import 'package:panthalassa_parsers/panthalassa_parsers.dart';
import 'package:test/test.dart';

void main() {
  final registry = ParserRegistry.standard();
  Uint8List u(String s) => Uint8List.fromList(utf8.encode(s));

  test('FHIR/XML: resource type, id, and text are extracted', () {
    final r = registry.parse(
      u(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<Patient xmlns="http://hl7.org/fhir">'
        '<id value="patient-123"/>'
        '<name><family value="Mwema"/></name>'
        '</Patient>',
      ),
    );
    expect(r.format, DocumentFormat.fhirXml);
    expect(r.metadata['resourceType'], 'Patient');
    expect(r.metadata['id'], 'patient-123');
    expect(r.text, contains('Mwema'));
  });

  test('generic non-FHIR XML is not claimed as FHIR', () {
    final registry = ParserRegistry.standard();
    expect(
      registry.detect(u('<note><to>x</to></note>')),
      isNot(DocumentFormat.fhirXml),
    );
  });

  test('EDIFACT: UNA delimiters honoured, segments counted', () {
    final r = registry.parse(
      u(
        "UNA:+.? 'UNB+UNOA:1+SENDER+RECIPIENT+200101:1200+REF001'"
        "UNH+1+ORDERS:D:96A:UN'BGM+220+ORDER123'UNT+3+1'UNZ+1+REF001'",
      ),
    );
    expect(r.format, DocumentFormat.edifact);
    expect(r.metadata['sender'], 'SENDER');
    expect(r.metadata['recipient'], 'RECIPIENT');
    expect(r.metadata['interchangeRef'], 'REF001');
    expect((r.metadata['messageTypes'] as List), contains('ORDERS:D:96A:UN'));
  });

  test('EDIFACT: release character escapes a separator', () {
    final r = registry.parse(
      u("UNB+UNOA:1+ACME?+CO+RCP+200101:1200+1'UNH+1+INVOIC:D:96A:UN'UNT+2+1'"),
    );
    // "ACME?+CO" -> the escaped '+' is literal, so sender is "ACME+CO".
    expect(r.metadata['sender'], 'ACME+CO');
  });

  test('STEP (ISO 10303-21): header and instance index', () {
    final r = registry.parse(
      u(
        "ISO-10303-21;\n"
        "HEADER;\n"
        "FILE_DESCRIPTION(('a model'),'2;1');\n"
        "FILE_NAME('part.step','2024-01-01',(''),(''),'','','');\n"
        "FILE_SCHEMA(('AUTOMOTIVE_DESIGN'));\n"
        "ENDSEC;\n"
        "DATA;\n"
        "#1=CARTESIAN_POINT('',(0.,0.,0.));\n"
        "#2=DIRECTION('',(1.,0.,0.));\n"
        "#3=CARTESIAN_POINT('',(1.,1.,1.));\n"
        "ENDSEC;\nEND-ISO-10303-21;",
      ),
    );
    expect(r.format, DocumentFormat.step);
    expect(r.metadata['schema'], 'AUTOMOTIVE_DESIGN');
    expect(r.metadata['instanceCount'], 3);
    final top = r.metadata['topEntities'] as List;
    expect(top.first['entity'], 'CARTESIAN_POINT');
    expect(top.first['count'], 2);
  });

  test(
    'USMTF: sets parsed, MSGID surfaced; loose slashes not misclassified',
    () {
      final r = registry.parse(
        u(
          'EXER/TEST EXERCISE//\n'
          'MSGID/SITREP/TASK FORCE 71//\n'
          'GENTEXT/SITUATION/ALL QUIET//\n',
        ),
      );
      expect(r.format, DocumentFormat.usmtf);
      expect(r.metadata['messageType'], 'SITREP');
      expect(
        (r.metadata['setIds'] as List),
        containsAll(['EXER', 'MSGID', 'GENTEXT']),
      );

      expect(
        registry.detect(u('see https://a/b and c/d/e for details')),
        isNot(DocumentFormat.usmtf),
      );
    },
  );
}
