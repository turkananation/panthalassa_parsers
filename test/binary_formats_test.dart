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

    test('descends SQ items and renders multi-valued attributes', () {
      final r = registry.parse(buildDicomWithSequenceAndMultiValues());
      expect(r.metadata['modality'], 'MR');
      expect(r.metadata['imageType'], ['ORIGINAL', 'PRIMARY']);
      final sequence = r.metadata['referencedSeriesSequence'] as List;
      expect(sequence, hasLength(1));
      final item = sequence.single as Map;
      expect(item['studyInstanceUid'], '1.2.3.4.5');
      final attributes = r.metadata['attributes'] as List;
      expect(
        attributes.any(
          (a) =>
              a is Map &&
              a['tag'] == '(0008,1115)' &&
              (a['items'] as List).isNotEmpty,
        ),
        true,
      );
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
      expect(
        () => registry.parse(stub),
        throwsA(isA<TruncatedDocumentException>()),
      );
    });

    test('walks segment subheaders and text bodies', () {
      final r = registry.parse(buildNitfWithSegments());
      expect(r.format, DocumentFormat.nitf);
      expect(r.metadata['imageSegments'], 1);
      expect(r.metadata['graphicSegments'], 1);
      expect(r.metadata['textSegments'], 1);
      expect(r.metadata['dataExtensionSegments'], 1);
      expect(r.metadata['reservedExtensionSegments'], 1);

      final image = (r.metadata['images'] as List).single as Map;
      expect(image['imageId'], 'IMG0000001');
      expect(image['rows'], 128);
      expect(image['columns'], 256);

      final text = (r.metadata['texts'] as List).single as Map;
      expect(text['textId'], 'TXT0001');
      expect(text['text'], 'NITF mission note');
      expect(r.text, contains('Panthalassa NITF sample'));
      expect(r.text, contains('NITF mission note'));

      final des = (r.metadata['dataExtensions'] as List).single as Map;
      expect(des['desId'], 'XML_DATA_CONTENT');
      final res = (r.metadata['reservedExtensions'] as List).single as Map;
      expect(res['resId'], 'RESERVED_EXTENSION');
    });
  });
}
