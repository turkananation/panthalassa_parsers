// Minimal CLI to exercise the parsers on a real file.
//
//   dart run example/parse_file.dart path/to/document.pdf
//
// Uses dart:io only here in the example (not in the library), so the library
// stays web-safe.
import 'dart:convert';
import 'dart:io';

import 'package:panthalassa_parsers/panthalassa_parsers.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run example/parse_file.dart <file>');
    exitCode = 64;
    return;
  }

  final file = File(args.first);
  if (!file.existsSync()) {
    stderr.writeln('no such file: ${args.first}');
    exitCode = 66;
    return;
  }

  final bytes = await file.readAsBytes();
  final registry = ParserRegistry.standard();

  try {
    final result = await registry.parseInIsolate(bytes);
    stdout.writeln('format      : ${result.format.label}');
    stdout.writeln('documentId  : ${result.documentId}');
    stdout.writeln('bytes       : ${result.byteLength}');
    stdout.writeln(
      'metadata    : ${const JsonEncoder.withIndent('  ').convert(result.metadata)}',
    );
    if (result.warnings.isNotEmpty) {
      stdout.writeln('warnings    :');
      for (final w in result.warnings) {
        stdout.writeln('  - $w');
      }
    }
    if (result.hasText) {
      final preview = result.text!.length > 1000
          ? '${result.text!.substring(0, 1000)}…'
          : result.text!;
      stdout.writeln('text        :\n$preview');
    }
  } on ParseException catch (e) {
    stderr.writeln('parse failed: $e');
    exitCode = 65;
  }
}
