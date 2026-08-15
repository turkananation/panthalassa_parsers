import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:panthalassa_parsers/panthalassa_parsers.dart';

void main() {
  group('STANAG 5516 Parsing Tests', () {
    // Constructing a valid Panthalassa L16J binary envelope layout
    final List<int> rawLink16Hex = [
      // === 8-BYTE PANTHALASSA L16J HEADER ===
      0x4C, 0x31, 0x36, 0x4A, // Magic: 'L', '1', '6', 'J'
      0x01, // Version: 1
      0x0A, // Word Length: 10 bytes per message
      0x00, 0x02, // Message Count: 2 messages expected
      // === MESSAGE 1 (10 Bytes) ===
      // To get 'J3.2': (3 << 3) | 2 = 24 | 2 = 26 (0x1A)
      0x1A, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A,

      // === MESSAGE 2 (10 Bytes) ===
      // To get 'J2.2': (2 << 3) | 2 = 16 | 2 = 18 (0x12)
      0x12, 0xFF, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA, 0x99, 0x88, 0x77,
    ];

    test(
      'Should parse static hexadecimal fixture synchronously without throwing exceptions',
      () {
        final Uint8List testBytes = Uint8List.fromList(rawLink16Hex);
        final ParserRegistry registry = ParserRegistry.standard();

        // 1. Detection Phase (Validates 'L16J' magic matching rule maps to the STANAG family group)
        final detectedFormat = registry.detect(testBytes);
        expect(
          detectedFormat.label,
          contains('STANAG'),
          reason:
              'The registry groups family detections under the high-level STANAG label.',
        );

        // 2. Parser Execution Phase
        try {
          final ParseResult result = registry.parse(testBytes);

          // Core Layout Assertions
          expect(result.format.label, contains('STANAG'));
          expect(result.documentId, isNotNull);
          expect(result.metadata, isA<Map<String, dynamic>>());

          // Target Metadata Deep Property Validations
          final metadata = result.metadata;
          expect(metadata['magic'], equals('L16J'));
          expect(metadata['profile'], equals('Link 16 / TADIL-J'));
          expect(metadata['messageCount'], equals(2));

          // Verify nested structural message list arrays matching your extractor logic
          final messages = metadata['messages'] as List;
          expect(messages[0]['label'], equals('J3.2'));
          expect(messages[1]['label'], equals('J2.2'));

          print('--- Test Execution Success ---');
          print('Captured Metadata Matrix: $metadata');
        } on ParseException catch (exception) {
          fail(
            'Parsing execution failed with package-level ParseException: $exception',
          );
        }
      },
    );

    test(
      'Should enforce safety bounds on partial data blocks to verify truncation rules',
      () {
        // Create a truncated payload containing only 6 bytes of the 8-byte header block
        final Uint8List truncatedBytes = Uint8List.fromList(
          rawLink16Hex.take(6).toList(),
        );
        final ParserRegistry registry = ParserRegistry.standard();

        expect(
          () => registry.parse(truncatedBytes),
          throwsA(isA<ParseException>()),
          reason:
              'Providing an incomplete header block frame must trigger a framework ParseException.',
        );
      },
    );
  });
}
