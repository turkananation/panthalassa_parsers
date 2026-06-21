import 'dart:typed_data';

import 'package:panthalassa_parsers/panthalassa_parsers.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final registry = ParserRegistry.standard();

  group('DICOM', () {
    test('detects Part 10 and extracts meta + dataset attributes', () {
      final r = registry.parse(buildMinimalDicom());
      expect(r.format, DocumentFormat.dicom);
      expect(r.metadata['transferSyntax'], '1.2.840.10008.1.2.1');
      expect(r.metadata['explicitVr'], true);
      expect(r.metadata['modality'], 'CT');
      expect(r.metadata['patientName'], 'DOE^JANE');
      expect(r.metadata['hasPixelData'], false);
    });

    test('the >=132 boundary is respected (no off-by-one)', () {
      // Exactly 132 bytes: 128 preamble + DICM, no elements. Must still detect.
      final bytes = Uint8List(132)
        ..[128] = 0x44
        ..[129] = 0x49
        ..[130] = 0x43
        ..[131] = 0x4D;
      expect(registry.detect(bytes), DocumentFormat.dicom);
    });
  });

  group('NITF', () {
    test('truncated header surfaces a typed TruncatedDocumentException', () {
      // 'NITF02.10' header but far shorter than the 363-byte file header.
      final stub = Uint8List.fromList(
        'NITF02.10'.codeUnits + List.filled(20, 0x20),
      );
      // Detection succeeds on the magic…
      expect(registry.detect(stub), DocumentFormat.nitf);
      // …but parsing a truncated header fails cleanly.
      expect(() => registry.parse(stub),
          throwsA(isA<TruncatedDocumentException>()));
    });
  });
}
