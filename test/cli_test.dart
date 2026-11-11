import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:panthalassa_parsers/panthalassa_parsers.dart';
import 'package:test/test.dart';

import '../bin/src/support.dart';

void main() {
  group('CLI formatting helpers', () {
    test('formatBytes uses binary units', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1024), '1.00 KiB');
      expect(formatBytes(1536), '1.50 KiB');
      expect(formatBytes(7 * 1024 * 1024), '7.00 MiB');
      expect(formatBytes(2 * 1024 * 1024 * 1024), '2.00 GiB');
    });

    test('baseName and extensionOf accept both path separators', () {
      expect(baseName('inbox/report.pdf'), 'report.pdf');
      expect(baseName(r'C:\inbox\report.pdf'), 'report.pdf');
      expect(baseName('inbox/'), 'inbox');
      expect(extensionOf('ARCHIVE.TAR.GZ'), 'gz');
      expect(extensionOf('README'), '');
    });

    test('extensionsFrom normalises commas, whitespace, and leading dots', () {
      expect(extensionsFrom(['.PDF, md', 'TXT', ' , ']), {'pdf', 'md', 'txt'});
    });

    test('shortHash preserves short values and abbreviates long ones', () {
      expect(shortHash('abc', length: 3), 'abc');
      expect(shortHash('abcdef', length: 3), 'abc…');
    });

    test('mapPool preserves input order', () async {
      final results = await mapPool<int, int>(
        List.generate(10, (i) => i),
        3,
        (item, index) async => item * 2,
      );
      expect(results, [0, 2, 4, 6, 8, 10, 12, 14, 16, 18]);
    });

    test('expandBatchInputs filters extensions and de-duplicates', () async {
      final directory = await Directory.systemTemp.createTemp('ptp-cli-');
      addTearDown(() => directory.delete(recursive: true));
      final nested = Directory('${directory.path}/nested')
        ..createSync(recursive: true);
      File('${directory.path}/a.pdf').writeAsBytesSync([1]);
      File('${directory.path}/b.md').writeAsBytesSync([2]);
      File('${nested.path}/c.pdf').writeAsBytesSync([3]);

      final flat = await expandBatchInputs(
        [directory.path],
        recursive: false,
        includeExtensions: {'pdf'},
      );
      expect(flat.map((input) => baseName(input.path)), ['a.pdf']);

      final deep = await expandBatchInputs(
        [directory.path],
        recursive: true,
        includeExtensions: {'pdf'},
      );
      expect(deep.map((input) => baseName(input.path)), ['a.pdf', 'c.pdf']);
    });
  });

  group('hint-gated detection confidence', () {
    final registry = ParserRegistry.standard();

    test('a filename hint raises Markdown confidence above the threshold', () {
      final bytes = Uint8List.fromList(utf8.encode('# Title\n\nBody'));
      final result = registry.detectDetailed(
        bytes,
        hints: const DocumentHints(filename: 'notes.md'),
      );
      expect(result.format, DocumentFormat.markdown);
      expect(result.isConfident, isTrue);
      expect(result.evidence, contains('hint-match'));
    });

    test('hint-only CSV is not misreported without a hint', () {
      final bytes = Uint8List.fromList(utf8.encode('a,b\n1,2'));
      expect(registry.detect(bytes), DocumentFormat.unknown);
      final hinted = registry.detectDetailed(
        bytes,
        hints: const DocumentHints(filename: 'rows.csv'),
      );
      expect(hinted.format, DocumentFormat.csv);
      expect(hinted.isConfident, isTrue);
    });
  });
}
