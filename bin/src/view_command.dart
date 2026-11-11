/// `view` — build a self-contained HTML document viewer and open it.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/command_runner.dart';
import 'package:panthalassa_parsers/panthalassa_parsers.dart';

import 'console.dart';
import 'support.dart';

/// `view` — parse a document, render a viewer, write it, and open a browser.
///
/// The HTML is fully self-contained (CSS, JavaScript, and image assets are
/// embedded), so the output can be opened from `file://` without a server.
/// Format-specific behavior lives in the library's [ViewBuilder]s; this command
/// only handles input, output paths, browser launch, and console reporting.
final class ViewCommand extends Command<void> {
  ViewCommand() {
    addHintOptions(argParser);
    addParseOptions(argParser);
    argParser
      ..addOption(
        'out',
        valueHelp: 'file',
        help: 'Write the viewer HTML to this path instead of the cache.',
      )
      ..addFlag(
        'no-open',
        negatable: false,
        help: 'Write the viewer but do not launch a browser.',
      )
      ..addFlag(
        'print-path',
        negatable: false,
        help: 'Print only the viewer path (for scripts and editors).',
      )
      ..addFlag(
        'json',
        negatable: false,
        help: 'Emit viewer metadata as JSON after writing the file.',
      )
      ..addFlag(
        'raw',
        negatable: false,
        help: 'Write the generated HTML viewer to stdout and do not open it.',
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
        help: 'Suppress status lines (does not affect --json/--print-path).',
      )
      ..addOption(
        'title',
        valueHelp: 'text',
        help: 'Viewer title. Defaults to the input filename.',
      )
      ..addOption(
        'limit',
        defaultsTo: '5000',
        valueHelp: 'n',
        help: 'Maximum table rows to embed (default: 5000).',
      )
      ..addFlag(
        'all-rows',
        negatable: false,
        help: 'Embed every table row, ignoring --limit.',
      )
      ..addOption(
        'frame',
        defaultsTo: '1',
        valueHelp: 'n',
        help: 'DICOM frame to render, one-based (default: 1).',
      )
      ..addFlag(
        'all-frames',
        negatable: false,
        help: 'Render every DICOM frame (capped for static HTML).',
      )
      ..addOption(
        'window-center',
        valueHelp: 'value',
        help: 'DICOM window center override.',
      )
      ..addOption(
        'window-width',
        valueHelp: 'value',
        help: 'DICOM window width override (must be positive).',
      )
      ..addFlag(
        'invert',
        negatable: false,
        help: 'Invert grayscale or colour values in the rendered frame.',
      );
  }

  @override
  String get name => 'view';

  @override
  String get description =>
      'Open a fast document viewer for tables, spreadsheets, images, email, '
      'PDF, DICOM, structured JSON/XML, or any supported format.';

  @override
  String get invocation => 'panthalassa view <file|-> [options]';

  @override
  String get usageFooter => usageExamples([
    '# Open a CSV in the default browser with a filterable table',
    'panthalassa view report.csv',
    '# Preview a spreadsheet, image, email, PDF, or structured payload',
    'panthalassa view workbook.xlsx',
    'panthalassa view scan.jpg',
    'panthalassa view message.eml',
    'panthalassa view report.pdf',
    'panthalassa view payload.json',
    '# Render a DICOM image with a custom window, without opening a browser',
    'panthalassa view scan.dcm --window-center 40 --window-width 400 --no-open',
    '# Print the cached viewer path for an editor integration',
    'panthalassa view scan.dcm --print-path',
    '# Pipe the generated HTML to another tool',
    'panthalassa view report.csv --raw > report.view.html',
  ]);

  @override
  Future<void> run() async {
    final inputs = argResults!.rest;
    if (inputs.length != 1) {
      usageException('Provide exactly one input path (use "-" for stdin).');
    }

    final json = argResults!['json'] as bool;
    final raw = argResults!['raw'] as bool;
    final printPath = argResults!['print-path'] as bool;
    final noOpen = argResults!['no-open'] as bool;
    final quiet = argResults!['quiet'] as bool;
    final out = argResults!['out'] as String?;
    final stdoutHtml = raw || out == '-';

    if (json && stdoutHtml) {
      usageException('--json cannot be combined with --raw or --out -.');
    }
    if (printPath && (json || stdoutHtml)) {
      usageException(
        '--print-path cannot be combined with --json, --raw, or --out -.',
      );
    }
    if (raw && out != null) {
      usageException('--raw already writes to stdout; remove --out.');
    }

    final options = ViewerOptions(
      title: _title(),
      rowLimit: _rowLimit(),
      allRows: argResults!['all-rows'] as bool,
      frame: _frame(),
      allFrames: argResults!['all-frames'] as bool,
      windowCenter: _optionalDouble('window-center'),
      windowWidth: _windowWidth(),
      invert: argResults!['invert'] as bool,
    );
    if (options.allFrames && argResults!.wasParsed('frame')) {
      usageException('--all-frames and --frame are mutually exclusive.');
    }

    final input = await readInput(
      inputs.single,
      filenameHint: argResults!['filename'] as String?,
    );
    final result = await parseInput(
      ParserRegistry.standard(),
      input,
      options: parseOptionsFrom(argResults!),
      hints: hintsFrom(argResults!, inputs.single),
      sync: argResults!['sync'] as bool,
    );

    final registry = ViewerRegistry.standard();
    final builder = registry.builderFor(result);
    final viewer = registry.build(
      ViewerRequest(
        result: result,
        bytes: input.bytes,
        filename: input.displayName,
        options: options,
      ),
    );
    final html = const ViewerHtmlRenderer().render(viewer);

    if (stdoutHtml) {
      console.writeRaw(html);
      return;
    }

    final outputPath = out ?? _cachePath(input.displayName, html);
    final wrote = await _writeIfChanged(outputPath, html);
    if (wrote && out != null && !quiet && !json && !printPath) {
      console.created(outputPath);
    }

    final shouldOpen = !noOpen && !json && !printPath;
    var opened = false;
    if (shouldOpen) {
      opened = await _openInBrowser(outputPath);
      if (!opened) {
        console.warn(
          'Could not launch a browser automatically. '
          'Open this file manually:',
        );
        console.info('  $outputPath');
      }
    }

    if (printPath) {
      console.raw(outputPath);
      return;
    }

    if (json) {
      await emitJson(
        {
          'path': input.displayName,
          'output': outputPath,
          'format': result.format.name,
          'label': result.format.label,
          'builder': builder.id,
          'title': viewer.title,
          'documentId': result.documentId,
          'byteLength': input.byteLength,
          'viewerBytes': utf8.encode(html).length,
          'sections': viewer.sections.length,
          'assets': viewer.assets.length,
          'notices': [
            for (final notice in viewer.notices)
              {'level': notice.level.name, 'message': notice.message},
          ],
          'opened': opened,
          if (result.tables.isNotEmpty) 'tables': result.tables.length,
        },
        null,
        quiet: true,
      );
      return;
    }

    if (quiet) return;

    console.section('Viewer');
    console.detail('file', input.displayName);
    console.detail('format', '${result.format.label} (${result.format.name})');
    console.detail('builder', builder.id);
    if (viewer.subtitle != null && viewer.subtitle!.isNotEmpty) {
      console.detail('summary', viewer.subtitle!);
    }
    if (result.tables.isNotEmpty) {
      console.detail('tables', '${result.tables.length}');
    }
    if (viewer.assets.isNotEmpty) {
      console.detail('assets', '${viewer.assets.length}');
    }
    console.detail('documentId', result.documentId);
    console.detail(
      'viewer',
      '$outputPath (${formatBytes(_stringBytes(html))})',
    );
    for (final notice in viewer.notices.where(
      (notice) => notice.level != ViewerNoticeLevel.info,
    )) {
      console.warn(notice.message);
    }
    if (opened) {
      console.success('Opened the viewer in your default browser.');
      console.hint('Use --no-open or --print-path for scripts and editors.');
    } else if (!shouldOpen && !noOpen) {
      console.hint('Viewer written; browser launch was skipped.');
    } else if (noOpen) {
      console.success('Viewer written.');
      console.hint('Re-run without --no-open to launch a browser.');
    }
  }

  String? _title() {
    final value = argResults!['title'] as String?;
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  int _rowLimit() {
    final raw = argResults!['limit'] as String;
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed < 1) {
      throw ArgumentError.value(raw, '--limit', 'must be a positive integer');
    }
    return parsed;
  }

  int _frame() {
    final raw = argResults!['frame'] as String;
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed < 1) {
      throw ArgumentError.value(
        raw,
        '--frame',
        'must be a one-based frame number',
      );
    }
    return parsed - 1;
  }

  double? _optionalDouble(String option) {
    final raw = argResults![option] as String?;
    if (raw == null) return null;
    final parsed = double.tryParse(raw.trim());
    if (parsed == null || !parsed.isFinite) {
      throw ArgumentError.value(raw, '--$option', 'must be a number');
    }
    return parsed;
  }

  double? _windowWidth() {
    final value = _optionalDouble('window-width');
    if (value != null && value <= 0) {
      throw ArgumentError.value(
        argResults!['window-width'],
        '--window-width',
        'must be greater than zero',
      );
    }
    return value;
  }
}

/// Writes [html] unless the destination already has identical content.
///
/// Returns true when the file was written, false when it was already current.
Future<bool> _writeIfChanged(String path, String html) async {
  final file = File(path);
  if (await file.exists()) {
    try {
      if (await file.readAsString() == html) return false;
    } on FileSystemException {
      // Fall through and overwrite unreadable/invalid content.
    }
  }
  await file.parent.create(recursive: true);
  await file.writeAsString(html);
  return true;
}

/// Content-addressed cache path so repeated views reuse the same file.
String _cachePath(String filename, String html) {
  const hasher = PqBytesContentHasher();
  final digest = hasher
      .digestFor(Uint8List.fromList(utf8.encode(html)))
      .sha256
      .substring(0, 16);
  final stem = _safeStem(filename);
  return '${_cacheRoot().path}${Platform.pathSeparator}'
      '$stem-$digest.html';
}

String _safeStem(String filename) {
  var name = baseName(filename);
  final dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  name = name.replaceAll(RegExp('[^A-Za-z0-9._-]+'), '-');
  name = name.replaceAll(RegExp(r'^[.\-]+|[.\-]+$'), '');
  if (name.isEmpty) name = 'view';
  if (name.length > 64) name = name.substring(0, 64);
  return name;
}

Directory _cacheRoot() {
  final env = Platform.environment;
  String? base;
  if (Platform.isWindows) {
    base = env['LOCALAPPDATA'] ?? env['APPDATA'];
    if (base != null && base.isNotEmpty) {
      return Directory(
        '$base${Platform.pathSeparator}panthalassa'
        '${Platform.pathSeparator}view',
      );
    }
  } else if (Platform.isMacOS) {
    final home = env['HOME'];
    if (home != null && home.isNotEmpty) {
      return Directory('$home/Library/Caches/panthalassa/view');
    }
  } else {
    base = env['XDG_CACHE_HOME'];
    if (base != null && base.isNotEmpty) {
      return Directory('$base/panthalassa/view');
    }
    final home = env['HOME'];
    if (home != null && home.isNotEmpty) {
      return Directory('$home/.cache/panthalassa/view');
    }
  }
  return Directory(
    '${Directory.systemTemp.path}${Platform.pathSeparator}'
    'panthalassa-view',
  );
}

/// Launches the platform browser opener (or `$BROWSER`) detached.
Future<bool> _openInBrowser(String path) async {
  final candidates = _browserCommands(path);
  if (candidates.isEmpty) return false;
  for (final command in candidates) {
    try {
      await Process.start(
        command.first,
        command.sublist(1),
        mode: ProcessStartMode.detached,
      );
      return true;
    } on ProcessException {
      continue;
    } on FileSystemException {
      continue;
    }
  }
  return false;
}

List<List<String>> _browserCommands(String path) {
  final commands = <List<String>>[];
  final browser = Platform.environment['BROWSER']?.trim();
  if (browser != null && browser.isNotEmpty) {
    final expanded = _expandBrowser(browser, path);
    if (expanded.isNotEmpty) commands.add(expanded);
  }
  if (Platform.isWindows) {
    commands.add(['cmd', '/c', 'start', '', path]);
  } else if (Platform.isMacOS) {
    commands.add(['open', path]);
  } else {
    // A terminal-only Linux session has no browser to open; skip the noisy
    // xdg-open failure and let the caller print the path.
    final hasDisplay =
        (Platform.environment['DISPLAY']?.isNotEmpty ?? false) ||
        (Platform.environment['WAYLAND_DISPLAY']?.isNotEmpty ?? false);
    if (hasDisplay || browser != null && browser.isNotEmpty) {
      commands.add(['xdg-open', path]);
    }
  }
  return commands;
}

List<String> _expandBrowser(String browser, String path) {
  // Respect a colon-separated fallback list, but only on POSIX where that is
  // the documented convention.
  var chosen = browser;
  if (!Platform.isWindows) {
    for (final part in browser.split(':')) {
      if (part.trim().isNotEmpty) {
        chosen = part.trim();
        break;
      }
    }
  }
  final parts = chosen
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty) return const [];
  var replaced = false;
  final command = <String>[];
  for (final part in parts) {
    if (part.contains('%s')) {
      command.add(part.replaceAll('%s', path));
      replaced = true;
    } else {
      command.add(part);
    }
  }
  if (!replaced) command.add(path);
  return command;
}

int _stringBytes(String value) => utf8.encode(value).length;
