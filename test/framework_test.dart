import 'dart:convert';
import 'dart:typed_data';

import 'package:panthalassa_parsers/panthalassa_parsers.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final registry = ParserRegistry.standard();

  group('content addressing', () {
    test('id is deterministic for identical bytes', () {
      final a = utf8.encode('UNB+UNOA:1+SENDER+RECIPIENT+200101:1200+1\'');
      const hasher = PqBytesContentHasher();
      expect(hasher.idFor(Uint8List.fromList(a)),
          hasher.idFor(Uint8List.fromList([...a])));
    });

    test('a one-bit change yields a different id (tamper-evidence)', () {
      const hasher = PqBytesContentHasher();
      final original = Uint8List.fromList(utf8.encode('payload'));
      final tampered = Uint8List.fromList(original)..[0] ^= 0x01;
      expect(hasher.idFor(original), isNot(hasher.idFor(tampered)));
    });

    test('id is stable across an isolate boundary', () async {
      final pdf = buildSimplePdf();
      final sync = registry.parse(pdf);
      final iso = await registry.parseInIsolate(pdf);
      expect(iso.documentId, sync.documentId);
      expect(iso.format, DocumentFormat.pdf);
    });
  });

  group('format detection precedence', () {
    test('binary magic wins over text heuristics', () {
      expect(registry.detect(buildMinimalDicom()), DocumentFormat.dicom);
      expect(registry.detect(buildSimplePdf()), DocumentFormat.pdf);
      expect(registry.detect(buildMinimalOdf()), DocumentFormat.odf);
    });

    test('unrecognised input is reported as unknown, not misclassified', () {
      final noise = Uint8List.fromList(List.generate(64, (i) => (i * 7) % 256));
      expect(registry.detect(noise), DocumentFormat.unknown);
    });

    test('parse throws UnsupportedFormatException on unknown input', () {
      final noise = Uint8List.fromList(List.filled(32, 0x42));
      expect(() => registry.parse(noise),
          throwsA(isA<UnsupportedFormatException>()));
    });
  });
}
