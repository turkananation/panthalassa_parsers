/// `parse` and `render` — extract content and project it into text/Markdown/
/// HTML/SVG output.
library;

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:panthalassa_parsers/panthalassa_parsers.dart';

import 'console.dart';
import 'support.dart';

/// `parse` — full parse with a human summary or a machine-readable result.
final class ParseCommand extends Command<void> {
  ParseCommand() {
    addHintOptions(argParser);
    addParseOptions(argParser);
    argParser
      ..addFlag(
        'json',
        negatable: false,
        help: 'Emit the full ParseResult JSON.',
      )
      ..addFlag(
        'text',
        negatable: false,
        help: 'Write only the extracted text to stdout (or --out).',
      )
      ..addFlag(
        'metadata',
        negatable: false,
        help: 'Write only metadata as JSON to stdout (or --out).',
      )
      ..addOption(
        'out',
        valueHelp: 'file',
        help: 'Write the selected payload to a file instead of stdout.',
      )
      ..addOption(
        'preview-lines',
        defaultsTo: '20',
        valueHelp: 'n',
        help: 'Text lines shown in the human summary; 0 disables the preview.',
      )
      ..addFlag(
        'attachment-text',
        defaultsTo: true,
        help:
            'Include attachment text in --json output (--no-attachment-text).',
      )
      ..addFlag(
        'sync',
        negatable: false,
        help: 'Parse on the current isolate instead of spawning one.',
      )
      ..addFlag(
        'quiet',
        abbr: 'q',
        negatable: false,
        help: 'Suppress the human summary and created-file lines.',
      );
  }

  @override
  String get name => 'parse';

  @override
  String get description => 'Detect, parse, and content-address a document.';

  @override
  String get invocation => 'panthalassa parse <file|-> [options]';

  @override
  String get usageFooter => usageExamples([
    '# Human summary plus a text preview',
    'panthalassa parse report.pdf',
    '# Machine-readable ParseResult with all three digests',
    'panthalassa parse report.pdf --json --out report.parse.json',
    '# Extracted text only, ready to pipe',
    'panthalassa parse report.pdf --text > report.txt',
    '# Ambiguous text formats need a hint',
    'panthalassa parse - --filename notes.md < notes.txt',
    '# Tighter ingest limits and recursive attachments',
    'panthalassa parse dossier.pdf --strict --parse-attachments --json',
  ]);

  @override
  Future<void> run() async {
    final inputs = argResults!.rest;
    if (inputs.length != 1) {
      usageException('Provide exactly one input path (use "-" for stdin).');
    }
    final json = argResults!['json'] as bool;
    final text = argResults!['text'] as bool;
    final metadata = argResults!['metadata'] as bool;
    final modeCount = [json, text, metadata].where((enabled) => enabled).length;
    if (modeCount > 1) {
      usageException('Use only one of --json, --text, or --metadata.');
    }
    final out = argResults!['out'] as String?;
    if (out != null && modeCount == 0) {
      usageException('--out requires --json, --text, or --metadata.');
    }
    final quiet = argResults!['quiet'] as bool;
    final previewLines = _previewLines();
    final options = parseOptionsFrom(argResults!);
    final input = await readInput(inputs.single);
    final hints = hintsFrom(argResults!, inputs.single);
    final result = await parseInput(
      ParserRegistry.standard(),
      input,
      options: options,
      hints: hints,
      sync: argResults!['sync'] as bool,
    );

    if (json) {
      await emitJson(
        result.toJson(
          includeAttachmentText: argResults!['attachment-text'] as bool,
        ),
        out,
        quiet: quiet,
      );
      return;
    }
    if (text) {
      await emitText(out, result.text ?? '', quiet: quiet);
      return;
    }
    if (metadata) {
      await emitText(out, jsonText(result.metadata), quiet: quiet);
      return;
    }

    _writeHuman(input, result, previewLines);
  }

  int _previewLines() {
    final raw = argResults!['preview-lines'] as String;
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed < 0) {
      throw ArgumentError.value(
        raw,
        '--preview-lines',
        'must be zero or a positive integer',
      );
    }
    return parsed;
  }

  void _writeHuman(InputDocument input, ParseResult result, int previewLines) {
    console.section('Document');
    console.detail('file', input.displayName);
    console.detail('size', formatBytes(input.byteLength));
    console.detail('format', '${result.format.label} (${result.format.name})');
    console.detail('category', result.format.category.name);
    console.detail('documentId', result.documentId);
    final digest = result.digest;
    if (digest != null) {
      console.detail('sha384', digest.sha384);
      console.detail('sha512', digest.sha512);
    }
    console.detail('parser', result.parserVersion);
    console.detail('schema', '$parseResultSchemaVersion');
    console.detail(
      'text',
      result.hasText ? '${result.text!.length} characters' : '(none)',
    );
    console.detail('metadata', '${result.metadata.length} top-level field(s)');
    if (result.tables.isNotEmpty) {
      console.detail('tables', '${result.tables.length}');
    }
    if (result.outline.isNotEmpty) {
      console.detail('outline', '${result.outline.length}');
    }
    if (result.attachments.isNotEmpty) {
      console.detail('attachments', '${result.attachments.length}');
    }
    if (result.signatures.isNotEmpty) {
      console.detail(
        'signatures',
        '${result.signatures.length} (presence only)',
      );
    }
    if (result.securityLabel != null) {
      console.detail(
        'security label',
        result.securityLabel!.classification ?? '(present)',
      );
    }
    console.detail(
      'warnings',
      result.warnings.isEmpty ? 'none' : '${result.warnings.length}',
    );

    printWarnings(result.warnings);

    if (result.metadata.isNotEmpty) {
      console.section('Metadata');
      var shown = 0;
      for (final entry in result.metadata.entries) {
        if (shown++ >= 40) {
          console.hint('… ${result.metadata.length - 40} more field(s)');
          break;
        }
        final visualPages = entry.value;
        final value = entry.key == 'visualPages' && visualPages is Iterable
            ? '<${visualPages.length} visual page(s)>'
            : shorten(_displayValue(entry.value), 140);
        console.info('  ${console.ansi.cyan(entry.key)}: $value');
      }
    }

    if (previewLines > 0 && result.hasText) {
      final lines = result.text!.split('\n');
      final truncated = lines.length > previewLines;
      console.section(truncated ? 'Text (preview)' : 'Text');
      console.info(lines.take(previewLines).join('\n'));
      if (truncated) {
        console.hint(
          '… ${lines.length - previewLines} more line(s); '
          'use --text to print all.',
        );
      }
    }
  }

  String _displayValue(Object? value, [int depth = 0]) {
    if (value == null) return 'null';
    if (value is String || value is num || value is bool) return '$value';
    if (depth >= 2) {
      if (value is Map) return '<${value.length} field(s)>';
      if (value is Iterable) return '<${value.length} item(s)>';
      return '<${value.runtimeType}>';
    }
    if (value is Iterable) {
      final items = value.take(4).map((item) => _displayValue(item, depth + 1));
      final suffix = value.length > 4 ? ', …' : '';
      return '[${items.join(', ')}$suffix]';
    }
    if (value is Map) {
      final entries = value.entries
          .take(4)
          .map(
            (entry) => '${entry.key}: ${_displayValue(entry.value, depth + 1)}',
          );
      final suffix = value.length > 4 ? ', …' : '';
      return '{${entries.join(', ')}$suffix}';
    }
    return '$value';
  }
}

/// `render` — project a parse result into a text, Markdown, HTML, or SVG view.
final class RenderCommand extends Command<void> {
  RenderCommand() {
    addHintOptions(argParser);
    addParseOptions(argParser);
    argParser
      ..addOption(
        'format',
        allowed: ['text', 'markdown', 'html', 'svg'],
        defaultsTo: 'text',
        valueHelp: 'name',
        help: 'Render format: text, markdown, html, or svg.',
      )
      ..addOption(
        'out',
        valueHelp: 'file',
        help: 'Write the rendered output to a file instead of stdout.',
      )
      ..addFlag(
        'metadata',
        defaultsTo: true,
        help: 'Include the metadata block (use --no-metadata to omit).',
      )
      ..addOption(
        'heading-base-level',
        defaultsTo: '1',
        valueHelp: 'n',
        help: 'Base heading level for Markdown/HTML (1–6).',
      )
      ..addFlag(
        'sync',
        negatable: false,
        help: 'Parse on the current isolate instead of spawning one.',
      )
      ..addFlag(
        'quiet',
        abbr: 'q',
        negatable: false,
        help: 'Suppress created-file lines.',
      );
  }

  @override
  String get name => 'render';

  @override
  String get description =>
      'Render a parsed document as text, Markdown, HTML, or SVG.';

  @override
  String get invocation => 'panthalassa render <file|-> [options]';

  @override
  String get usageFooter => usageExamples([
    'panthalassa render report.pdf --format markdown',
    'panthalassa render report.pdf --format html --out report.html',
    'panthalassa render report.pdf --format svg --out report.svg',
    'panthalassa render report.pdf --no-metadata --format text',
  ]);

  @override
  Future<void> run() async {
    final inputs = argResults!.rest;
    if (inputs.length != 1) {
      usageException('Provide exactly one input path (use "-" for stdin).');
    }
    final format = argResults!['format'] as String;
    final options = parseOptionsFrom(argResults!);
    if (format == 'svg' && !options.includeVisual) {
      usageException(
        '--format svg requires visual metadata; remove --no-visual.',
      );
    }
    final baseLevel = _headingBaseLevel();
    final renderOptions = RenderOptions(
      includeMetadata: argResults!['metadata'] as bool,
      headingBaseLevel: baseLevel,
    );
    final input = await readInput(inputs.single);
    final result = await parseInput(
      ParserRegistry.standard(),
      input,
      options: options,
      hints: hintsFrom(argResults!, inputs.single),
      sync: argResults!['sync'] as bool,
    );
    final ir = DocumentIr.fromParseResult(result);
    final String rendered;
    switch (format) {
      case 'markdown':
        rendered = const MarkdownDocumentRenderer().render(
          ir,
          options: renderOptions,
        );
      case 'html':
        rendered = const HtmlDocumentRenderer().render(
          ir,
          options: renderOptions,
        );
      case 'svg':
        final visual = ir.toVisualDocument();
        if (visual.isEmpty) {
          console.failure('The parsed document has no visual page geometry.');
          console.hint(
            'Try --format text, markdown, or html; or parse a PDF/NITF/DICOM '
            'with visual metadata.',
          );
          exitCode = exitData;
          return;
        }
        rendered = const SvgVisualRenderer().render(visual);
      case _:
        rendered = const TextDocumentRenderer().render(
          ir,
          options: renderOptions,
        );
    }
    if (rendered.isEmpty) {
      console.warn('The renderer produced empty output.');
    }
    await emitText(
      argResults!['out'] as String?,
      rendered,
      quiet: argResults!['quiet'] as bool,
    );
  }

  int _headingBaseLevel() {
    final raw = argResults!['heading-base-level'] as String;
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed < 1 || parsed > 6) {
      throw ArgumentError.value(
        raw,
        '--heading-base-level',
        'must be an integer from 1 to 6',
      );
    }
    return parsed;
  }
}
