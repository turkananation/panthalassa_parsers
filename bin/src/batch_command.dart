/// `batch` — parse many files with bounded isolate concurrency.
library;

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:panthalassa_parsers/panthalassa_parsers.dart';

import 'console.dart';
import 'support.dart';

/// Parses file/directory inputs with a bounded worker pool.
final class BatchCommand extends Command<void> {
  BatchCommand() {
    addParseOptions(argParser);
    argParser
      ..addFlag(
        'recursive',
        abbr: 'r',
        negatable: false,
        help: 'Descend into directory inputs recursively.',
      )
      ..addMultiOption(
        'include',
        valueHelp: 'ext',
        help:
            'Only include these extensions (comma-separated or repeatable), '
            'e.g. --include pdf,md.',
      )
      ..addOption(
        'concurrency',
        defaultsTo: '2',
        valueHelp: 'n',
        help: 'Maximum isolates parsing at once.',
      )
      ..addOption(
        'out-dir',
        valueHelp: 'dir',
        help: 'Write one ParseResult JSON per successful input.',
      )
      ..addFlag(
        'fail-fast',
        negatable: false,
        help: 'Stop scheduling new files after the first failure.',
      )
      ..addFlag('json', negatable: false, help: 'Emit machine-readable JSON.')
      ..addFlag(
        'quiet',
        abbr: 'q',
        negatable: false,
        help: 'Suppress per-file progress; keep the final summary.',
      );
  }

  @override
  String get name => 'batch';

  @override
  String get description =>
      'Parse files and directories with bounded isolate concurrency.';

  @override
  String get invocation => 'panthalassa batch <path>... [options]';

  @override
  String get usageFooter => usageExamples([
    'panthalassa batch inbox/ --recursive --include pdf,docx',
    'panthalassa batch inbox/ --json --concurrency 4',
    'panthalassa batch inbox/ --out-dir parsed/',
    'panthalassa batch a.pdf b.pdf --fail-fast',
  ]);

  @override
  Future<void> run() async {
    final paths = argResults!.rest;
    if (paths.isEmpty) {
      usageException('Provide at least one file or directory path.');
    }
    final json = argResults!['json'] as bool;
    final quiet = argResults!['quiet'] as bool;
    final failFast = argResults!['fail-fast'] as bool;
    final concurrency = _positiveInt('concurrency');
    final outDir = argResults!['out-dir'] as String?;
    final include = extensionsFrom(argResults!['include'] as List<String>);
    final options = parseOptionsFrom(argResults!);

    final inputs = await expandBatchInputs(
      paths,
      recursive: argResults!['recursive'] as bool,
      includeExtensions: include,
    );
    if (inputs.isEmpty) {
      console.failure(
        include.isEmpty
            ? 'No files found in the supplied paths.'
            : 'No files matched --include ${include.join(', ')}.',
      );
      exitCode = exitNoInput;
      return;
    }
    if (outDir != null) {
      final directory = Directory(outDir);
      if (await FileSystemEntity.type(outDir) == FileSystemEntityType.file) {
        console.failure('--out-dir points at a file: $outDir');
        exitCode = exitUsage;
        return;
      }
      await directory.create(recursive: true);
    }

    final registry = ParserRegistry.standard();
    final progress = BatchProgress(total: inputs.length, quiet: quiet || json);
    final startedAt = DateTime.now();
    var stopScheduling = false;

    final outcomes = await mapPool<BatchInput, _BatchOutcome>(
      inputs,
      concurrency,
      (item, index) async {
        if (failFast && stopScheduling) {
          return _BatchSkipped(item);
        }
        progress.start(item.path);
        final timer = Stopwatch()..start();
        try {
          final input = await readInput(item.path);
          final result = await registry.parseInIsolate(
            input.bytes,
            options: options,
            hints: input.isStdin
                ? null
                : DocumentHints(filename: input.displayName),
          );
          timer.stop();
          if (outDir != null) {
            await _writeResult(outDir, item, result);
          }
          progress.success(
            item.path,
            format: result.format,
            byteLength: result.byteLength,
            elapsed: timer.elapsed,
          );
          return _BatchSuccess(item, result, timer.elapsed);
        } on Object catch (error) {
          timer.stop();
          progress.failure(item.path, _errorSummary(error));
          if (failFast) stopScheduling = true;
          return _BatchFailure(item, error, timer.elapsed);
        }
      },
    );

    final successes = outcomes.whereType<_BatchSuccess>().toList();
    final failures = outcomes.whereType<_BatchFailure>().toList();
    final skipped = outcomes.whereType<_BatchSkipped>().length;
    final totalBytes = successes.fold<int>(
      0,
      (sum, outcome) => sum + outcome.result.byteLength,
    );
    final elapsed = DateTime.now().difference(startedAt);

    if (json) {
      await emitJson({
        'schemaVersion': 1,
        'command': 'batch',
        'generatedAt': startedAt.toUtc().toIso8601String(),
        'elapsedMs': elapsed.inMilliseconds,
        'concurrency': concurrency,
        'summary': {
          'total': inputs.length,
          'attempted': successes.length + failures.length,
          'succeeded': successes.length,
          'failed': failures.length,
          'skipped': skipped,
          'byteLength': totalBytes,
        },
        'results': [
          for (final outcome in successes)
            {
              'path': outcome.input.path,
              'elapsedMs': outcome.elapsed.inMilliseconds,
              'result': outcome.result.toJson(),
            },
        ],
        'failures': [
          for (final outcome in failures)
            {
              'path': outcome.input.path,
              'elapsedMs': outcome.elapsed.inMilliseconds,
              'error': _errorPayload(outcome.error),
            },
        ],
      }, null);
    } else {
      progress.done(byteLength: totalBytes);
      if (failures.isNotEmpty) {
        console.section('Failures (${failures.length})');
        for (final outcome in failures) {
          console.info(
            '  ${console.ansi.brightRed('✗')} ${outcome.input.path}  '
            '${console.ansi.gray('→')}  ${_errorSummary(outcome.error)}',
          );
        }
      }
      if (skipped > 0) {
        console.hint(
          '$skipped file(s) were skipped after the first failure (--fail-fast).',
        );
      }
    }

    if (failures.isNotEmpty) {
      exitCode = 1;
    } else if (successes.isEmpty) {
      exitCode = exitNoInput;
    }
  }

  int _positiveInt(String name) {
    final raw = argResults![name] as String;
    final value = int.tryParse(raw);
    if (value == null || value <= 0) {
      throw ArgumentError.value(raw, '--$name', 'must be a positive integer');
    }
    return value;
  }

  Future<void> _writeResult(
    String outDir,
    BatchInput input,
    ParseResult result,
  ) async {
    final name = input.path == '-' ? 'stdin' : baseName(input.path);
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    final prefix = safe.isEmpty ? 'document' : safe;
    final shortId = result.documentId.substring(0, 12);
    final path = '$outDir${Platform.pathSeparator}$prefix.$shortId.parse.json';
    await emitJson(result.toJson(), path, quiet: true);
  }

  String _errorSummary(Object error) {
    if (error is ParseException) {
      return '${error.runtimeType}: ${error.message}'
          '${error.offset == null ? '' : ' @${error.offset}'}';
    }
    if (error is FileSystemException) {
      final path = error.path == null ? '' : ' (${error.path})';
      return '${error.message}$path';
    }
    return '$error';
  }

  Map<String, Object?> _errorPayload(Object error) {
    if (error is ParseException) {
      return {
        'type': error.runtimeType.toString(),
        'message': error.message,
        if (error.offset != null) 'offset': error.offset,
      };
    }
    if (error is FileSystemException) {
      return {
        'type': 'FileSystemException',
        'message': error.message,
        if (error.path != null) 'path': error.path,
        if (error.osError != null) 'osError': error.osError!.message,
      };
    }
    return {'type': error.runtimeType.toString(), 'message': '$error'};
  }
}

sealed class _BatchOutcome {
  const _BatchOutcome(this.input);

  final BatchInput input;
}

final class _BatchSuccess extends _BatchOutcome {
  const _BatchSuccess(super.input, this.result, this.elapsed);

  final ParseResult result;
  final Duration elapsed;
}

final class _BatchFailure extends _BatchOutcome {
  const _BatchFailure(super.input, this.error, this.elapsed);

  final Object error;
  final Duration elapsed;
}

final class _BatchSkipped extends _BatchOutcome {
  const _BatchSkipped(super.input);
}
