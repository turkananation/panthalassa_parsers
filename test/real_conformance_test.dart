import 'dart:convert';
import 'dart:io';

import 'package:panthalassa_parsers/panthalassa_parsers.dart';
import 'package:test/test.dart';

void main() {
  final fixtureDir = Platform.environment['PANTHALASSA_CONFORMANCE_DIR'];
  final enabled = fixtureDir != null && fixtureDir.isNotEmpty;

  test(
    'real-file conformance fixtures parse with stable identities',
    () {
      final root = Directory(fixtureDir!);
      expect(root.existsSync(), true, reason: fixtureDir);

      final manifestFile = File('${root.path}/conformance_manifest.json');
      final manifest = manifestFile.existsSync()
          ? (jsonDecode(manifestFile.readAsStringSync())
                as Map<String, Object?>)
          : const <String, Object?>{};
      final cases = manifest['cases'] is List
          ? manifest['cases'] as List
          : const <Object?>[];

      final registry = ParserRegistry.standard();
      if (cases.isEmpty) {
        final files = root
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => !f.path.endsWith('conformance_manifest.json'))
            .toList();
        expect(files, isNotEmpty);
        for (final file in files) {
          final result = registry.parse(file.readAsBytesSync());
          expect(result.documentId, hasLength(64), reason: file.path);
          expect(
            result.format,
            isNot(DocumentFormat.unknown),
            reason: file.path,
          );
        }
        return;
      }

      for (final raw in cases) {
        final c = raw as Map<String, Object?>;
        final path = c['path'] as String;
        final file = File('${root.path}/$path');
        final result = registry.parse(file.readAsBytesSync());
        expect(result.documentId, c['documentId'], reason: path);
        if (c['format'] case final String format) {
          expect(result.format.name, format, reason: path);
        }
        if (c['textContains'] case final String text) {
          expect(result.text, contains(text), reason: path);
        }
      }
    },
    skip: enabled
        ? false
        : 'Set PANTHALASSA_CONFORMANCE_DIR to run real-file conformance fixtures.',
  );
}
