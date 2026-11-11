/// Shared helpers for the panthalassa CLI: input I/O, hint and option wiring,
/// bounded batch expansion, JSON/text output, and human formatting.
///
/// Everything here is intentionally presentation-light. Commands own their
/// styled output; these helpers return values or write raw payloads.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:panthalassa_parsers/panthalassa_parsers.dart';

import 'console.dart';

/// sysexits.h-style process codes used consistently by every command.
const int exitUsage = 64; // EX_USAGE
const int exitData = 65; // EX_DATAERR
const int exitNoInput = 66; // EX_NOINPUT
const int exitSoftware = 70; // EX_SOFTWARE

/// A parsed input, either a file or standard input.
final class InputDocument {
  const InputDocument({
    required this.path,
    required this.displayName,
    required this.bytes,
  });

  /// The original path, or `-` for stdin.
  final String path;

  /// The name shown to the user and used as a detection hint.
  final String displayName;

  final Uint8List bytes;

  int get byteLength => bytes.length;

  bool get isStdin => path == '-';
}

/// Reads [path], or all of stdin when [path] is `-`.
///
/// File errors are intentionally allowed to propagate so `main` can map them to
/// [exitNoInput] with the conventional path in the message.
Future<InputDocument> readInput(String path, {String? filenameHint}) async {
  if (path == '-') {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stdin) {
      builder.add(chunk);
    }
    return InputDocument(
      path: path,
      displayName: filenameHint ?? '<stdin>',
      bytes: builder.takeBytes(),
    );
  }
  final bytes = await File(path).readAsBytes();
  return InputDocument(
    path: path,
    displayName: filenameHint ?? path,
    bytes: bytes,
  );
}

/// Adds `--filename` / `--mime` hint options for ambiguous formats.
void addHintOptions(ArgParser parser) {
  parser
    ..addOption(
      'filename',
      valueHelp: 'name',
      help:
          'Detection hint filename. Defaults to the input basename; required '
          'for Markdown/CSV when reading stdin.',
    )
    ..addOption(
      'mime',
      valueHelp: 'type',
      help: 'Detection hint MIME type, e.g. text/markdown or text/csv.',
    );
}

/// Builds [DocumentHints] from the shared hint options.
DocumentHints hintsFrom(ArgResults results, String path) {
  final explicitFilename = results['filename'] as String?;
  final mime = results['mime'] as String?;
  final filename = explicitFilename ?? (path == '-' ? null : baseName(path));
  return DocumentHints(filename: filename, mimeType: mime);
}

/// Adds the full [ParseOptions] / [ParseLimits] surface to [parser].
void addParseOptions(ArgParser parser) {
  parser
    ..addFlag(
      'strict',
      negatable: false,
      help:
          'Use ParseLimits.strict (tighter per-request ceilings) as the base '
          'for any --max-* overrides.',
    )
    ..addOption('max-text-chars', valueHelp: 'n', help: 'Text character cap.')
    ..addOption('max-metadata', valueHelp: 'n', help: 'Metadata node cap.')
    ..addOption('max-json-nodes', valueHelp: 'n', help: 'JSON node walk cap.')
    ..addOption(
      'max-table-rows',
      valueHelp: 'n',
      help: 'Retained table row cap.',
    )
    ..addOption(
      'max-table-columns',
      valueHelp: 'n',
      help: 'Retained columns per row.',
    )
    ..addOption(
      'max-attachments',
      valueHelp: 'n',
      help: 'Embedded attachment cap.',
    )
    ..addOption(
      'max-attachment-bytes',
      valueHelp: 'n',
      help: 'Total attachment payload byte cap.',
    )
    ..addOption(
      'max-decompressed-bytes',
      valueHelp: 'n',
      help: 'Total inflated container byte cap.',
    )
    ..addOption(
      'max-decompressed-entry-bytes',
      valueHelp: 'n',
      help: 'Per-entry/stream inflated byte cap.',
    )
    ..addOption(
      'max-recursion-depth',
      valueHelp: 'n',
      help: 'Attachment recursion depth cap.',
    )
    ..addOption('max-pages', valueHelp: 'n', help: 'Page/frame/slide cap.')
    ..addOption(
      'max-segments',
      valueHelp: 'n',
      help: 'Binary segment index cap.',
    )
    ..addFlag(
      'visual',
      defaultsTo: true,
      help: 'Emit visual display-list metadata (use --no-visual to omit).',
    )
    ..addFlag(
      'structured-text',
      defaultsTo: true,
      help: 'Emit page/section-aware structured text.',
    )
    ..addFlag(
      'outline',
      defaultsTo: true,
      help: 'Emit outline/bookmark/navigation entries.',
    )
    ..addFlag('tables', defaultsTo: true, help: 'Emit native tables.')
    ..addFlag(
      'attachments',
      defaultsTo: true,
      help: 'Surface embedded attachment metadata and text.',
    )
    ..addFlag(
      'attachment-bytes',
      negatable: false,
      help:
          'Retain raw attachment bytes in memory (not serialised by default).',
    )
    ..addFlag(
      'parse-attachments',
      negatable: false,
      help: 'Recursively parse supported embedded attachments.',
    )
    ..addFlag(
      'annotations',
      defaultsTo: true,
      help: 'Surface annotations/comments where supported.',
    )
    ..addFlag(
      'form-fields',
      defaultsTo: true,
      help: 'Surface form fields where supported.',
    )
    ..addFlag(
      'signatures',
      defaultsTo: true,
      help: 'Surface signature envelopes (presence only; never verified).',
    )
    ..addFlag(
      'security-labels',
      defaultsTo: true,
      help: 'Emit normalised classification/handling metadata.',
    )
    ..addFlag(
      'reject-encrypted',
      negatable: false,
      help:
          'Fail encrypted/password-protected documents instead of extracting.',
    );
}

/// Builds [ParseOptions] from the shared options and any `--max-*` overrides.
ParseOptions parseOptionsFrom(ArgResults results) {
  final base = (results['strict'] as bool)
      ? ParseLimits.strict
      : ParseLimits.standard;
  final limits = ParseLimits(
    maxTextCharacters: _limit(
      results,
      'max-text-chars',
      base.maxTextCharacters,
    ),
    maxMetadataEntries: _limit(
      results,
      'max-metadata',
      base.maxMetadataEntries,
    ),
    maxJsonNodes: _limit(results, 'max-json-nodes', base.maxJsonNodes),
    maxTableRows: _limit(results, 'max-table-rows', base.maxTableRows),
    maxTableColumns: _limit(results, 'max-table-columns', base.maxTableColumns),
    maxAttachments: _limit(results, 'max-attachments', base.maxAttachments),
    maxAttachmentBytes: _limit(
      results,
      'max-attachment-bytes',
      base.maxAttachmentBytes,
    ),
    maxDecompressedBytes: _limit(
      results,
      'max-decompressed-bytes',
      base.maxDecompressedBytes,
    ),
    maxDecompressedEntryBytes: _limit(
      results,
      'max-decompressed-entry-bytes',
      base.maxDecompressedEntryBytes,
    ),
    maxRecursionDepth: _limit(
      results,
      'max-recursion-depth',
      base.maxRecursionDepth,
    ),
    maxPages: _limit(results, 'max-pages', base.maxPages),
    maxSegments: _limit(results, 'max-segments', base.maxSegments),
  );
  return ParseOptions(
    limits: limits,
    includeVisual: results['visual'] as bool,
    includeStructuredText: results['structured-text'] as bool,
    includeOutline: results['outline'] as bool,
    includeTables: results['tables'] as bool,
    includeAttachments: results['attachments'] as bool,
    includeAttachmentBytes: results['attachment-bytes'] as bool,
    parseAttachments: results['parse-attachments'] as bool,
    includeAnnotations: results['annotations'] as bool,
    includeFormFields: results['form-fields'] as bool,
    includeSignatures: results['signatures'] as bool,
    includeSecurityLabels: results['security-labels'] as bool,
    rejectEncrypted: results['reject-encrypted'] as bool,
  );
}

int _limit(ArgResults results, String name, int fallback) {
  final raw = results[name] as String?;
  if (raw == null) return fallback;
  final parsed = int.tryParse(raw);
  if (parsed == null || parsed <= 0) {
    throw ArgumentError.value(raw, '--$name', 'must be a positive integer');
  }
  return parsed;
}

/// Parses on the current isolate or a background isolate.
Future<ParseResult> parseInput(
  ParserRegistry registry,
  InputDocument input, {
  required ParseOptions options,
  DocumentHints? hints,
  bool sync = false,
}) async {
  if (sync) {
    return registry.parse(input.bytes, options: options, hints: hints);
  }
  return registry.parseInIsolate(input.bytes, options: options, hints: hints);
}

/// Pretty JSON used by every `--json` path.
String jsonText(Object? value) =>
    const JsonEncoder.withIndent('  ').convert(value);

/// Emits [payload] to [outPath], or to stdout when [outPath] is null or `-`.
///
/// Writes exactly one trailing newline for terminal/file readability. Raw
/// parser text and rendered documents can be written with [writeRawOutput]
/// when the caller needs byte-for-byte control.
Future<void> emitText(
  String? outPath,
  String payload, {
  bool quiet = false,
}) async {
  if (outPath == null || outPath == '-') {
    console.writeRaw(payload);
    if (!payload.endsWith('\n')) console.writeRaw('\n');
    return;
  }
  final file = File(outPath);
  await file.parent.create(recursive: true);
  await file.writeAsString(payload);
  if (!quiet) console.created(outPath);
}

/// Emits a JSON document to [outPath], or to stdout when omitted.
Future<void> emitJson(Object? value, String? outPath, {bool quiet = false}) =>
    emitText(outPath, jsonText(value), quiet: quiet);

/// Writes raw content without altering line endings or appending a newline.
Future<void> writeRawOutput(
  String? outPath,
  String payload, {
  bool quiet = false,
}) async {
  if (outPath == null || outPath == '-') {
    console.writeRaw(payload);
    return;
  }
  final file = File(outPath);
  await file.parent.create(recursive: true);
  await file.writeAsString(payload);
  if (!quiet) console.created(outPath);
}

/// Human byte count with binary units.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100
      ? 0
      : value >= 10
      ? 1
      : 2;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// Compact duration for progress output.
String formatDuration(Duration duration) {
  if (duration.inMilliseconds < 1000) return '${duration.inMilliseconds}ms';
  if (duration.inSeconds < 60) {
    return '${(duration.inMilliseconds / 1000).toStringAsFixed(1)}s';
  }
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds.remainder(60);
  return '${minutes}m ${seconds}s';
}

/// Shortens a hash for human summaries; machine output always uses full values.
String shortHash(String hash, {int length = 16}) =>
    hash.length <= length ? hash : '${hash.substring(0, length)}…';

/// Returns the final path component, accepting both `/` and `\`.
String baseName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final trimmed = normalized.endsWith('/')
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
  final slash = trimmed.lastIndexOf('/');
  return slash < 0 ? trimmed : trimmed.substring(slash + 1);
}

/// Lowercase extension without the dot, or an empty string.
String extensionOf(String path) {
  final name = baseName(path);
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

/// True when [format] matches a human query against its enum name or label.
bool formatMatches(DocumentFormat format, String query) {
  final q = query.trim().toLowerCase();
  return format.name.toLowerCase().contains(q) ||
      format.label.toLowerCase().contains(q);
}

/// Normalises comma-separated `--include` values into an extension set.
Set<String> extensionsFrom(List<String> values) {
  final extensions = <String>{};
  for (final value in values) {
    for (final part in value.split(',')) {
      final cleaned = part.trim().toLowerCase().replaceFirst(
        RegExp(r'^\.'),
        '',
      );
      if (cleaned.isNotEmpty) extensions.add(cleaned);
    }
  }
  return extensions;
}

/// One resolved batch input with its display path preserved.
final class BatchInput {
  const BatchInput(this.path);

  final String path;

  String get name => baseName(path);
}

/// Expands file/directory arguments into a deterministic, de-duplicated file
/// list. Directories are non-recursive unless [recursive] is true.
///
/// A directory with no matching files contributes nothing; the caller decides
/// whether that is an empty job or an error.
Future<List<BatchInput>> expandBatchInputs(
  List<String> inputs, {
  required bool recursive,
  required Set<String> includeExtensions,
}) async {
  final out = <BatchInput>[];
  final seen = <String>{};

  Future<void> addFile(String path) async {
    if (includeExtensions.isNotEmpty &&
        !includeExtensions.contains(extensionOf(path))) {
      return;
    }
    final key = File(path).absolute.path;
    if (seen.add(key)) out.add(BatchInput(path));
  }

  Future<void> addPath(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw FileSystemException('Input not found', path);
    }
    if (type == FileSystemEntityType.directory) {
      final entries = await Directory(
        path,
      ).list(recursive: recursive, followLinks: false).toList();
      entries.sort((a, b) => a.path.compareTo(b.path));
      for (final entity in entries) {
        if (entity is File) {
          await addFile(entity.path);
        }
      }
      return;
    }
    await addFile(path);
  }

  for (final input in inputs) {
    if (input == '-') {
      if (inputs.length != 1) {
        throw const FormatException(
          'stdin ("-") cannot be combined with other batch inputs',
        );
      }
      out.add(const BatchInput('-'));
      continue;
    }
    await addPath(input);
  }
  return out;
}

/// Runs [task] over [items] with at most [concurrency] in flight, preserving
/// input order. Task exceptions propagate after the pool drains.
Future<List<T>> mapPool<I, T>(
  List<I> items,
  int concurrency,
  Future<T> Function(I item, int index) task,
) async {
  if (items.isEmpty) return <T>[];
  final safeConcurrency = concurrency.clamp(1, items.length);
  final results = List<T?>.filled(items.length, null);
  var next = 0;

  Future<void> worker() async {
    while (true) {
      final index = next;
      next++;
      if (index >= items.length) return;
      results[index] = await task(items[index], index);
    }
  }

  await Future.wait([for (var i = 0; i < safeConcurrency; i++) worker()]);
  return results.cast<T>();
}

/// Per-file success/failure progress for `batch`.
final class BatchProgress {
  BatchProgress({required this.total, this.quiet = false})
    : _startedAt = DateTime.now();

  final int total;
  final bool quiet;
  final DateTime _startedAt;

  int _finished = 0;
  int _successes = 0;
  int _failures = 0;

  int get successes => _successes;
  int get failures => _failures;

  void start(String path) {
    if (quiet) return;
    console.liveProgress(
      'parsing [${_finished + 1}/$total] ${shorten(path, 48)}',
    );
  }

  void success(
    String path, {
    required DocumentFormat format,
    required int byteLength,
    required Duration elapsed,
  }) {
    _finished++;
    _successes++;
    if (quiet) return;
    console.progressDone();
    console.info(
      '[$_finished/$total] ${console.ansi.green('SUCCESS')}: $path '
      '(${format.label}, ${formatBytes(byteLength)}, '
      '${formatDuration(elapsed)})',
    );
  }

  void failure(String path, Object error) {
    _finished++;
    _failures++;
    if (quiet) return;
    console.progressDone();
    console.info(
      '[$_finished/$total] ${console.ansi.brightRed('FAILED')}: $path '
      '($error)',
    );
  }

  void done({required int byteLength}) {
    console.progressDone();
    final elapsed = DateTime.now().difference(_startedAt);
    final finished = _successes + _failures;
    final rate = finished == 0 ? 0.0 : (_successes / finished) * 100;
    final summary =
        'Batch complete: $finished file(s) in ${formatDuration(elapsed)} '
        '(${formatBytes(byteLength)}) | Successes: $_successes | '
        'Failures: $_failures | Success Rate: '
        '${rate.toStringAsFixed(1)}%';
    if (_failures > 0) {
      console.failure(summary);
    } else {
      console.success(summary);
    }
  }
}

/// Truncates [text] to [max] characters from the middle, for progress lines.
String shorten(String text, int max) {
  if (text.length <= max) return text;
  if (max < 5) return text.substring(0, max);
  final head = (max - 1) ~/ 2;
  final tail = max - head - 1;
  return '${text.substring(0, head)}…${text.substring(text.length - tail)}';
}

/// Human warning block shared by parse and batch.
void printWarnings(List<ParseWarning> warnings) {
  if (warnings.isEmpty) return;
  console.section('Warnings (${warnings.length})');
  for (final warning in warnings) {
    final offset = warning.offset == null ? '' : ' @${warning.offset}';
    console.info(
      '  ${console.ansi.yellow('⚠')} ${console.ansi.bold(warning.code)}$offset'
      '  ${warning.message}',
    );
  }
}
