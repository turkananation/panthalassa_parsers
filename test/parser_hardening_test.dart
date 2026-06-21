import 'dart:convert';
import 'dart:typed_data';

import 'package:panthalassa_parsers/panthalassa_parsers.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final registry = ParserRegistry.standard();

  group('malformed input hardening', () {
    for (final entry in _fixtures().entries) {
      test(
        '${entry.key} truncations and bit flips stay typed',
        () {
          for (final sample in _mutations(entry.value)) {
            try {
              registry.parse(sample);
            } on ParseException {
              // Expected for malformed recognised inputs and unsupported formats.
            } catch (e, st) {
              fail('untyped error for ${entry.key}: $e\n$st');
            }
          }
        },
        timeout: const Timeout(Duration(seconds: 2)),
      );
    }
  });
}

Map<String, Uint8List> _fixtures() => {
  'dicom': buildMinimalDicom(),
  'nitf': buildNitfWithSegments(),
  'odf': buildMinimalOdf(),
  'pdf': buildSimplePdf(),
  'stanag4607': buildStanag4607Gmti(),
  'stanag4609': buildMpegTsWithKlv(),
  'stanag7023': buildStanag7023Npif(),
  'stanag5516': buildStanag5516Link16(),
  'fhirXml': Uint8List.fromList(
    utf8.encode(
      '<Patient xmlns="http://hl7.org/fhir"><id value="p1"/></Patient>',
    ),
  ),
  'json': Uint8List.fromList(utf8.encode('{"hello":"world"}')),
  'xml': Uint8List.fromList(utf8.encode('<root><value>world</value></root>')),
  'edifact': Uint8List.fromList(utf8.encode("UNB+UNOC:3+S+R+1'UNZ+0+1'")),
  'x12': Uint8List.fromList(
    utf8.encode(
      'ISA*00*          *00*          *ZZ*SENDER         *ZZ*RECEIVER       *260621*1530*U*00401*000000001*0*T*:~GS*HC*S*R*20260621*1530*1*X*005010X222~ST*837*0001~SE*2*0001~GE*1*1~IEA*1*000000001~',
    ),
  ),
  'step': Uint8List.fromList(
    utf8.encode(
      "ISO-10303-21;\nHEADER;\nFILE_SCHEMA(('IFC4'));\nENDSEC;\nDATA;\n#1=THING();\nENDSEC;\nEND-ISO-10303-21;",
    ),
  ),
  'usmtf': Uint8List.fromList(utf8.encode('MSGID/TEST/1//\nREF/A//')),
};

Iterable<Uint8List> _mutations(Uint8List bytes) sync* {
  yield Uint8List(0);
  yield Uint8List.sublistView(bytes, 0, bytes.length ~/ 2);
  if (bytes.isNotEmpty) {
    yield Uint8List.sublistView(bytes, 0, bytes.length - 1);
    final flipped = Uint8List.fromList(bytes);
    flipped[0] ^= 0xFF;
    yield flipped;
  }
  if (bytes.length > 8) {
    final middle = Uint8List.fromList(bytes);
    middle[bytes.length ~/ 2] ^= 0xA5;
    yield middle;
  }
}
