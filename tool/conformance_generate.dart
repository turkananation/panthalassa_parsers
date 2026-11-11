/// Generates a `conformance_manifest.json` for a directory of real files.
///
/// Each case records the file path, its SHA-256 content id, detected format,
/// and optionally a substring the extracted text must contain. The manifest is
/// consumed by `test/real_conformance_test.dart` when
/// `PANTHALASSA_CONFORMANCE_DIR` is set.
///
/// ```bash
/// dart run tool/conformance_generate.dart /path/to/conformance/fixtures \
///   --out conformance_manifest.json
/// ```
library;

import 'dart:convert';
import 'dart:io';

import 'package:panthalassa_parsers/panthalassa_parsers.dart';

const _manifestName = 'conformance_manifest.json';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Usage: dart run tool/conformance_generate.dart <dir> '
        '[--out <file>]');
    exitCode = 64;
    return;
  }
  final root = Directory(args.first);
  if (!await root.exists()) {
    stderr.writeln('Directory not found: ${root.path}');
    exitCode = 66;
    return;
  }
  final outPath = args.contains('--out')
      ? args[args.indexOf('--out') + 1]
      : '${root.path}/$_manifestName';

  final registry = ParserRegistry.standard();
  final cases = <Map<String, Object?>>[];
  final files = <File>[];
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is File && entity.path != File(outPath).absolute.path) {
      files.add(entity);
    }
  }
  files.sort((a, b) => a.path.compareTo(b.path));

  final rootPath = root.absolute.path.endsWith('/')
      ? root.absolute.path
      : '${root.absolute.path}/';
  String relativePath(String path) => path.startsWith(rootPath)
      ? path.substring(rootPath.length)
      : path;

  for (final file in files) {
    final bytes = await file.readAsBytes();
    final result = registry.parse(bytes);
    final caseEntry = <String, Object?>{
      'path': relativePath(file.path),
      'documentId': result.documentId,
      'format': result.format.name,
    };
    final text = result.text?.trim();
    if (text != null && text.isNotEmpty) {
      // Record a short, stable anchor substring from the start of the text.
      caseEntry['textContains'] = text.split(RegExp(r'\s+')).take(3).join(' ');
    }
    cases.add(caseEntry);
    stdout.writeln('${relativePath(file.path)} -> ${result.format.name}');
  }

  final manifest = <String, Object?>{
    'generated': DateTime.now().toUtc().toIso8601String(),
    'caseCount': cases.length,
    'cases': cases,
  };
  final file = File(outPath);
  await file.parent.create(recursive: true);
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));
  stdout.writeln('Wrote $outPath ($cases.length cases).');
}
