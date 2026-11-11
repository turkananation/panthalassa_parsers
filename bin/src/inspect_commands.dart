/// Detection, format catalog, and version commands.
library;

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:panthalassa_parsers/panthalassa_parsers.dart';

import 'console.dart';
import 'support.dart';

/// `detect` — report the detected format, confidence, and evidence.
final class DetectCommand extends Command<void> {
  DetectCommand() {
    addHintOptions(argParser);
    argParser
      ..addFlag('json', negatable: false, help: 'Emit machine-readable JSON.')
      ..addFlag(
        'require-match',
        negatable: false,
        help: 'Exit 65 when no parser recognises the input.',
      );
  }

  @override
  String get name => 'detect';

  @override
  String get description =>
      'Detect a document format without extracting its contents.';

  @override
  String get invocation => 'panthalassa detect <file|-> [options]';

  @override
  String get usageFooter => usageExamples([
    '# Use the filename as the ambiguity hint',
    'panthalassa detect notes.md',
    '# Parse stdin as CSV without guessing from content alone',
    'cat rows.txt | panthalassa detect - --filename rows.csv --mime text/csv',
    '# Machine-readable detection for an ingest gate',
    'panthalassa detect report.pdf --json --require-match',
  ]);

  @override
  Future<void> run() async {
    final inputs = argResults!.rest;
    if (inputs.length != 1) {
      usageException('Provide exactly one input path (use "-" for stdin).');
    }
    final input = await readInput(inputs.single);
    final registry = ParserRegistry.standard();
    final hints = hintsFrom(argResults!, inputs.single);
    final result = registry.detectDetailed(input.bytes, hints: hints);
    final payload = {
      'path': input.displayName,
      'byteLength': input.byteLength,
      'format': result.format.name,
      'label': result.format.label,
      'category': result.format.category.name,
      'confidence': result.confidence,
      'confident': result.isConfident,
      'evidence': result.evidence,
      'hints': {
        if (hints.filename != null) 'filename': hints.filename,
        if (hints.mimeType != null) 'mimeType': hints.mimeType,
      },
    };

    if (argResults!['json'] as bool) {
      await emitJson(payload, null);
    } else {
      console.section('Detection');
      console.detail('file', input.displayName);
      console.detail('size', formatBytes(input.byteLength));
      console.detail(
        'format',
        '${result.format.label} (${result.format.name})',
      );
      console.detail('category', result.format.category.name);
      console.detail(
        'confidence',
        '${(result.confidence * 100).toStringAsFixed(0)}%',
      );
      console.detail('evidence', result.evidence.join(' · '));
      if (result.format == DocumentFormat.unknown) {
        console.warn('No registered parser recognised the input.');
        console.hint(
          'Markdown and CSV/TSV require --filename or --mime when the input is '
          'not a named file.',
        );
      } else if (result.isConfident) {
        console.success('${result.format.label} detected');
      } else {
        console.warn(
          'Detection is low-confidence; pass --filename or --mime to '
          'disambiguate.',
        );
      }
    }

    if ((argResults!['require-match'] as bool) &&
        result.format == DocumentFormat.unknown) {
      exitCode = exitData;
    }
  }
}

/// `formats` — list every registered format, its capabilities, and detector.
final class FormatsCommand extends Command<void> {
  FormatsCommand() {
    argParser
      ..addFlag('json', negatable: false, help: 'Emit machine-readable JSON.')
      ..addFlag(
        'brief',
        negatable: false,
        help: 'One line per format, without capabilities.',
      )
      ..addFlag(
        'verbose',
        negatable: false,
        help: 'Include parser class names and parser version.',
      );
  }

  @override
  String get name => 'formats';

  @override
  String get description =>
      'List supported formats, categories, and declared capabilities.';

  @override
  String get invocation => 'panthalassa formats [query] [options]';

  @override
  String get usageFooter => usageExamples([
    'panthalassa formats',
    'panthalassa formats pdf',
    'panthalassa formats --json',
    'panthalassa formats --brief',
  ]);

  @override
  Future<void> run() async {
    final query = argResults!.rest;
    if (query.length > 1) {
      usageException('Provide at most one format query.');
    }
    final filter = query.isEmpty ? null : query.single;
    final grouped = <DocumentFormat, List<DocumentParser>>{};
    for (final parser in ParserRegistry.standard().parsers) {
      grouped.putIfAbsent(parser.format, () => []).add(parser);
    }
    final ordered = grouped.entries.toList()
      ..sort((a, b) => a.key.index.compareTo(b.key.index));

    final entries = <Map<String, Object?>>[];
    for (final entry in ordered) {
      if (filter != null && !formatMatches(entry.key, filter)) continue;
      final parsers = entry.value;
      final capabilities =
          parsers.first.capabilities.map((c) => c.name).toList()..sort();
      // Only Markdown and CSV/TSV are content-ambiguous in the built-in set.
      // Other hint-aware parsers use hints to refine an already-positive match.
      final requiresHints =
          entry.key == DocumentFormat.markdown ||
          entry.key == DocumentFormat.csv;
      entries.add({
        'format': entry.key.name,
        'label': entry.key.label,
        'category': entry.key.category.name,
        'capabilities': capabilities,
        'hintAware': parsers.any((p) => p is HintAwareDocumentParser),
        'requiresHints': requiresHints,
        'parserVersion': parsers.first.parserVersion,
        'parsers': [
          for (final parser in parsers) parser.runtimeType.toString(),
        ],
      });
    }

    if (entries.isEmpty) {
      console.failure(
        filter == null
            ? 'No formats are registered.'
            : 'No format matched "${query.single}".',
      );
      console.hint('Run `panthalassa formats` to list every supported format.');
      exitCode = exitData;
      return;
    }

    if (argResults!['json'] as bool) {
      await emitJson({'count': entries.length, 'formats': entries}, null);
      return;
    }

    final brief = argResults!['brief'] as bool;
    final verbose = argResults!['verbose'] as bool;
    console.section('Supported formats (${entries.length})');
    final byCategory = <String, List<Map<String, Object?>>>{};
    for (final entry in entries) {
      byCategory.putIfAbsent(entry['category']! as String, () => []).add(entry);
    }
    for (final category in FormatCategory.values) {
      final categoryEntries = byCategory[category.name];
      if (categoryEntries == null || categoryEntries.isEmpty) continue;
      console.info('\n  ${console.ansi.bold(category.name)}');
      for (final entry in categoryEntries) {
        final hints = entry['requiresHints'] == true
            ? ' ${console.ansi.yellow('· needs hints')}'
            : '';
        console.info(
          '    ${console.ansi.cyan(entry['label']! as String)} '
          '(${entry['format']})$hints',
        );
        if (brief) continue;
        final capabilities = (entry['capabilities']! as List).join(' · ');
        console.info('      ${console.ansi.gray(capabilities)}');
        if (verbose) {
          final parsers = (entry['parsers']! as List).join(', ');
          console.info(
            '      ${console.ansi.gray('parsers: $parsers · '
            'version: ${entry['parserVersion']}')}',
          );
        }
      }
    }
    console.hint(
      '\nMarkdown and CSV/TSV are detected only when --filename or --mime is '
      'supplied; other formats may use hints to disambiguate an already '
      'positive match.',
    );
  }
}

/// `version` — the subcommand form of the top-level `--version` flag.
final class VersionCommand extends Command<void> {
  VersionCommand() {
    argParser.addFlag(
      'json',
      negatable: false,
      help: 'Emit machine-readable JSON.',
    );
  }

  @override
  String get name => 'version';

  @override
  String get description => 'Print the CLI and package versions.';

  @override
  Future<void> run() async {
    if (argResults!['json'] as bool) {
      await emitJson({
        'cli': 'panthalassa',
        'version': panthalassaCliVersion,
        'package': 'panthalassa_parsers',
        'packageVersion': panthalassaCliVersion,
        'parserVersion': parserImplementationVersion,
        'parseResultSchemaVersion': parseResultSchemaVersion,
      }, null);
      return;
    }
    console.info('panthalassa $panthalassaCliVersion');
    console.detail('package', 'panthalassa_parsers $panthalassaCliVersion');
    console.detail('parser', parserImplementationVersion);
    console.detail('schema', '$parseResultSchemaVersion');
  }
}
