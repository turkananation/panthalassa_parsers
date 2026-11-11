/// panthalassa — a content-addressed document intake CLI.
///
/// Entry point and command wiring. Presentation lives in `src/console.dart`,
/// shared helpers in `src/support.dart`, and the commands in the
/// `*_commands.dart` files. `dart:io` is confined to `bin/`; the library remains
/// pure Dart and web-safe.
library;

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:panthalassa_parsers/panthalassa_parsers.dart';

import 'src/batch_command.dart';
import 'src/console.dart';
import 'src/digest_command.dart';
import 'src/inspect_commands.dart';
import 'src/parse_commands.dart';
import 'src/view_command.dart';

const _description =
    'Content-addressed document intake for the Panthalassa Vault: detect, '
    'parse, render, and digest structured, binary, and composite documents. '
    'Pure Dart, zero FFI, no native dependencies.';

/// Display order and grouping for the styled top-level help.
const Map<String, List<String>> _groups = {
  'Inspect': ['detect', 'formats'],
  'Parse & render': ['parse', 'render', 'view', 'batch'],
  'Content address': ['digest'],
  'Maintenance': ['version'],
};

Future<void> main(List<String> args) async {
  // IOSink writes can fail asynchronously when a downstream pipe closes (for
  // example `panthalassa parse --json | head`). The guarded zone keeps that
  // ordinary shell behaviour from dumping a framework stack trace.
  await runZonedGuarded(
    () async {
      // Resolve color before anything is rendered so the banner, usage, and
      // errors are styled consistently (and stay plain when piped or NO_COLOR
      // is set).
      Console.configure(color: resolveColor(args));
      final runner = PanthalassaRunner();

      // Bare invocation is a friendly help screen, not an error.
      if (args.isEmpty) {
        runner.printUsage();
        return;
      }

      try {
        await runner.run(args);
      } on UsageException catch (error) {
        console.failure(error.message);
        stderr.writeln();
        stderr.writeln(error.usage);
        exitCode = 64; // EX_USAGE
      } on ParseException catch (error) {
        final at = error.offset == null ? '' : ' (offset ${error.offset})';
        console.failure('${error.runtimeType}: ${error.message}$at');
        exitCode = 65; // EX_DATAERR
      } on FileSystemException catch (error) {
        final path = error.path == null ? '' : ' (${error.path})';
        console.failure('${error.message}$path');
        exitCode = 66; // EX_NOINPUT
      } on FormatException catch (error) {
        console.failure('Malformed input: ${error.message}');
        exitCode = 65; // EX_DATAERR
      } on ArgumentError catch (error) {
        // Option validation in shared helpers uses ArgumentError; both
        // package:args and our own checks describe user input, not a bug.
        final name = error.name;
        console.failure(
          name == null ? '${error.message}' : '$name: ${error.message}',
        );
        exitCode = 64; // EX_USAGE
      } on Object catch (error) {
        console.failure('$error');
        exitCode = 70; // EX_SOFTWARE
      }
    },
    (error, stackTrace) {
      if (_isBrokenPipe(error)) return;
      console.failure('$error');
      exitCode = 70; // EX_SOFTWARE
    },
  );
}

/// True for the benign EPIPE caused by a downstream consumer closing early.
bool _isBrokenPipe(Object error) {
  if (error is FileSystemException) {
    final code = error.osError?.errorCode;
    return code == 32 || error.message.toLowerCase().contains('broken pipe');
  }
  return false;
}

/// A [CommandRunner] with a styled, grouped help screen, a `--version` flag,
/// and a `--color`/`--no-color` toggle.
final class PanthalassaRunner extends CommandRunner<void> {
  PanthalassaRunner() : super('panthalassa', _description) {
    argParser
      ..addFlag(
        'version',
        negatable: false,
        help: 'Print the panthalassa version and exit.',
      )
      ..addFlag(
        'color',
        defaultsTo: true,
        help:
            'Use ANSI colors (use --no-color to disable; auto-off when piped).',
      );
    addCommand(DetectCommand());
    addCommand(FormatsCommand());
    addCommand(ParseCommand());
    addCommand(RenderCommand());
    addCommand(ViewCommand());
    addCommand(BatchCommand());
    addCommand(DigestCommand());
    addCommand(VersionCommand());
  }

  @override
  Future<void> runCommand(ArgResults topLevelResults) async {
    if (topLevelResults['version'] as bool) {
      console.info('panthalassa $panthalassaCliVersion');
      return;
    }
    return super.runCommand(topLevelResults);
  }

  @override
  String get usage {
    final ansi = console.ansi;
    final buffer = StringBuffer()
      ..writeln(console.banner())
      ..writeln();
    for (final line in _wrap(_description, 76)) {
      buffer.writeln('  $line');
    }
    buffer
      ..writeln()
      ..writeln(
        '  ${ansi.bold('Usage:')} ${ansi.cyan('panthalassa')} '
        '<command> [options]',
      )
      ..writeln(
        '         ${ansi.cyan('panthalassa')} help <command>'
        '   ${ansi.dim('full help for a command')}',
      );

    final column = _nameColumn();
    final shown = <String>{};
    for (final group in _groups.entries) {
      final names = group.value.where(_isVisible).toList();
      if (names.isEmpty) continue;
      buffer
        ..writeln()
        ..writeln('  ${ansi.bold(group.key)}');
      for (final name in names) {
        shown.add(name);
        _writeCommandRow(buffer, ansi, name, column);
      }
    }
    final rest = commands.keys
        .where((name) => !shown.contains(name) && _isVisible(name))
        .toList();
    if (rest.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('  ${ansi.bold('More')}');
      for (final name in rest) {
        _writeCommandRow(buffer, ansi, name, column);
      }
    }

    buffer
      ..writeln()
      ..writeln('  ${ansi.bold('Global options')}')
      ..writeln(_indent(argParser.usage, 4))
      ..write(usageFooter);
    return buffer.toString();
  }

  @override
  String get usageFooter {
    final ansi = console.ansi;
    return [
      '',
      '  ${ansi.bold('Examples')}',
      '  ${ansi.gray('# Parse a PDF and write the full content-addressed result')}',
      '  panthalassa parse report.pdf --json --out report.parse.json',
      '',
      '  ${ansi.gray('# List every format, its capabilities, and parser families')}',
      '  panthalassa formats --verbose',
      '',
      '  ${ansi.gray('# Batch-ingest a directory with bounded concurrency')}',
      '  panthalassa batch inbox/ --recursive --include pdf,docx --concurrency 4',
      '',
      '  ${ansi.gray('# Render escaped HTML or a visual SVG preview')}',
      '  panthalassa render report.pdf --format html --out report.html',
      '  panthalassa render report.pdf --format svg --out report.svg',
      '',
      '  ${ansi.gray('# Open a filterable CSV table or a DICOM image viewer')}',
      '  panthalassa view report.csv',
      '  panthalassa view scan.dcm --window-center 40 --window-width 400',
      '',
      '  ${ansi.dim('Docs')}    https://github.com/turkananation/panthalassa_parsers',
      '  ${ansi.dim('Digest')}  SHA-256 is the canonical documentId; SHA-384/512 '
          'travel with every ParseResult.',
      '',
    ].join('\n');
  }

  bool _isVisible(String name) {
    final command = commands[name];
    return command != null && !command.hidden;
  }

  int _nameColumn() => commands.keys
      .where(_isVisible)
      .map((name) => name.length)
      .fold(0, (max, length) => length > max ? length : max);

  void _writeCommandRow(
    StringBuffer buffer,
    Ansi ansi,
    String name,
    int column,
  ) {
    final label = ansi.cyan(name.padRight(column));
    buffer.writeln('    $label  ${commands[name]!.summary}');
  }
}

/// Greedy word wrap to [width] columns.
List<String> _wrap(String text, int width) {
  final words = text.split(' ');
  final lines = <String>[];
  var current = StringBuffer();
  for (final word in words) {
    if (current.isEmpty) {
      current.write(word);
    } else if (current.length + 1 + word.length <= width) {
      current.write(' $word');
    } else {
      lines.add(current.toString());
      current = StringBuffer(word);
    }
  }
  if (current.isNotEmpty) lines.add(current.toString());
  return lines;
}

String _indent(String text, int spaces) {
  final pad = ' ' * spaces;
  return text
      .split('\n')
      .map((line) => line.isEmpty ? line : '$pad$line')
      .join('\n');
}
