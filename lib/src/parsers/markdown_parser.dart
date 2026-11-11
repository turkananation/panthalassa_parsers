import 'dart:convert';
import 'dart:typed_data';

import 'package:swissarmyknife/swissarmyknife.dart';

import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_options.dart';
import '../core/parse_result.dart';
import '../core/structured_artifacts.dart';

/// Parser for Markdown documents (CommonMark/GFM-oriented subset).
///
/// Markdown has no reliable magic bytes, so detection requires a
/// [DocumentHints] filename hint (`.md`, `.markdown`, `.mdown`, `.mkd`) or
/// MIME type (`text/markdown`). Without a hint the parser declines rather than
/// misclassifying arbitrary plain text.
///
/// The parser is line-oriented instead of regex-over-whole-document so that
/// pathological inputs cannot trigger super-linear matching. It extracts
/// headings (outline), paragraphs, lists, block quotes, fenced code, YAML front
/// matter, links/images, and GFM pipe tables. No HTML rendering or Markdown
/// execution is performed.
final class MarkdownParser
    implements
        DocumentParser,
        OptionAwareDocumentParser,
        HintAwareDocumentParser {
  const MarkdownParser();

  static const Set<String> _extensions = {
    'md',
    'markdown',
    'mdown',
    'mkd',
    'mkdn',
    'mdwn',
    'mdtxt',
    'mdtext',
  };

  static const Set<String> _mimeTypes = {
    'text/markdown',
    'text/x-markdown',
    'text/x-md',
  };

  static final _atxHeading = RegExp(
    r'^(#{1,6})[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$',
  );
  static final _setextUnderline = RegExp(r'^[ \t]*(=+|-+)[ \t]*$');
  static final _horizontalRule = RegExp(
    r'^[ \t]{0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$',
  );
  static final _fence = RegExp(r'^[ \t]{0,3}(`{3,}|~{3,})[ \t]*([^`]*)$');
  static final _listItem = RegExp(r'^([ \t]*)([-*+]|\d{1,9}[.)])[ \t]+(.*)$');
  static final _blockQuote = RegExp(r'^[ \t]{0,3}>[ \t]?(.*)$');
  static final _imageOrLink = RegExp(
    r'(!?)\[([^\]]*)\]\(([^)\s]+)(?:[ \t]+"[^"]*")?\)',
  );
  static final _inlineCode = RegExp(r'`+([^`]*)`+');
  static final _strong = RegExp(r'(\*\*|__)(.*?)\1');
  static final _emphasis = RegExp(r'(\*|_)([^*_]+)\1');
  static final _strike = RegExp(r'~~(.*?)~~');
  static final _escaped = RegExp(r'\\([\\`*_{}\[\]()#+\-.!>])');

  @override
  DocumentFormat get format => DocumentFormat.markdown;

  String get parserVersion => parserImplementationVersion;

  @override
  bool canParse(Uint8List bytes) {
    // Markdown has no reliable magic; always decline without hints.
    return false;
  }

  @override
  bool canParseWithHints(Uint8List bytes, DocumentHints hints) {
    final ext = hints.extension ?? '';
    final mime = hints.mimeType ?? '';
    final byExt = ext.isNotEmpty && _extensions.contains(ext);
    final byMime = mime.isNotEmpty && _mimeTypes.contains(mime);
    if (!byExt && !byMime) return false;
    if (bytes.isEmpty) return false;
    // Confirm the content looks like valid UTF-8 text.
    final prefix = _peek(bytes, 8192);
    return prefix.toUtf8StringOrNull() != null;
  }

  @override
  ParseResult parse(Uint8List bytes, {required ContentHasher hasher}) =>
      parseWithOptions(bytes, hasher: hasher);

  @override
  ParseResult parseWithOptions(
    Uint8List bytes, {
    required ContentHasher hasher,
    ParseOptions options = const ParseOptions(),
    DocumentHints? hints,
  }) {
    final digest = hasher.digestFor(bytes);
    final decoded = _decodeBytes(bytes);
    final warnings = <ParseWarning>[];
    final metadata = <String, Object?>{};
    final blocks = <TextBlock>[];
    final outline = <OutlineEntry>[];
    final tables = <DocumentTable>[];
    final links = <Map<String, Object?>>[];

    final lines = decoded
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    var lineIndex = 0;

    // YAML front matter: only when a closing delimiter exists and the block
    // contains at least one `key:` pair, so a leading horizontal rule is not
    // mistaken for metadata.
    String? frontMatter;
    if (lines.isNotEmpty && lines.first.trim() == '---') {
      final close = _findFrontMatterClose(lines);
      if (close != null && _looksLikeFrontMatter(lines.sublist(1, close))) {
        frontMatter = lines.sublist(1, close).join('\n');
        lineIndex = close + 1;
      }
    }
    if (frontMatter != null) {
      metadata['frontMatter'] = frontMatter.truncate(64 * 1024);
    }

    var codeBlockCount = 0;
    var listItemCount = 0;
    var tableCount = 0;
    final codeLanguages = <String, int>{};
    var truncatedText = false;
    final textBuffer = StringBuffer();

    void addBlock(String text, {String style = 'paragraph', int? level}) {
      final cleaned = text.trim();
      if (cleaned.isEmpty) return;
      blocks.add(
        TextBlock(
          spans: [TextSpan(cleaned, style: style)],
          style: style,
          level: level,
        ),
      );
      final projected = textBuffer.length + cleaned.length + 1;
      if (projected > options.limits.maxTextCharacters) {
        final remaining = options.limits.maxTextCharacters - textBuffer.length;
        if (remaining > 0) {
          final end = remaining < cleaned.length ? remaining : cleaned.length;
          textBuffer
            ..write(cleaned.substring(0, end))
            ..write('\n');
        }
        truncatedText = true;
        return;
      }
      textBuffer
        ..write(cleaned)
        ..write('\n');
    }

    while (lineIndex < lines.length) {
      final line = lines[lineIndex];

      if (line.isBlank) {
        lineIndex++;
        continue;
      }

      // Fenced code blocks: tolerate an unclosed fence and warn instead of
      // swallowing the remainder silently.
      final fence = _fence.firstMatch(line);
      if (fence != null) {
        final marker = fence.group(1)!;
        final language = fence.group(2)!.trim();
        final codeLines = <String>[];
        lineIndex++;
        var closed = false;
        while (lineIndex < lines.length) {
          final candidate = lines[lineIndex];
          final closing = _fence.firstMatch(candidate);
          if (closing != null &&
              closing.group(1)!.startsWith(marker[0]) &&
              closing.group(1)!.length >= marker.length &&
              closing.group(2)!.trim().isEmpty) {
            lineIndex++;
            closed = true;
            break;
          }
          codeLines.add(candidate);
          lineIndex++;
        }
        if (!closed) {
          warnings.add(
            const ParseWarning(
              'markdown.unclosed_fence',
              'fenced code block was not closed before end of document',
            ),
          );
        }
        codeBlockCount++;
        final code = codeLines.join('\n');
        addBlock(code, style: 'code');
        if (language.isNotEmpty) {
          metadata['codeLanguages'] = {
            ...?metadata['codeLanguages'] as Map<String, Object?>?,
            language:
                ((metadata['codeLanguages'] as Map<String, Object?>?)?[language]
                        as int? ??
                    0) +
                1,
          };
        }
        continue;
      }

      // ATX heading.
      final heading = _atxHeading.firstMatch(line);
      if (heading != null) {
        final level = heading.group(1)!.length;
        final title = _inlineToPlain(heading.group(2)!);
        if (title.isNotEmpty) {
          outline.add(OutlineEntry(title: title, level: level));
          addBlock(title, style: 'heading', level: level);
        }
        lineIndex++;
        continue;
      }

      // Setext heading (text followed by === or ---).
      if (lineIndex + 1 < lines.length) {
        final underline = _setextUnderline.firstMatch(lines[lineIndex + 1]);
        if (underline != null && !line.trim().startsWith('|')) {
          final level = underline.group(1)!.startsWith('=') ? 1 : 2;
          final title = _inlineToPlain(line);
          if (title.isNotEmpty) {
            outline.add(OutlineEntry(title: title, level: level));
            addBlock(title, style: 'heading', level: level);
          }
          lineIndex += 2;
          continue;
        }
      }

      // Horizontal rule (skip it entirely).
      if (_horizontalRule.hasMatch(line)) {
        lineIndex++;
        continue;
      }

      // GFM table: require a separator row so ordinary prose containing `|`
      // is not swallowed as a table.
      if (_looksLikeTableRow(line) &&
          lineIndex + 1 < lines.length &&
          _isTableSeparator(lines[lineIndex + 1])) {
        final tableLines = <String>[line, lines[lineIndex + 1]];
        lineIndex += 2;
        while (lineIndex < lines.length &&
            _looksLikeTableRow(lines[lineIndex])) {
          tableLines.add(lines[lineIndex]);
          lineIndex++;
        }
        final table = _parseTable(tableLines, options);
        if (table != null) {
          tableCount++;
          tables.add(table);
          for (final row in table.rows) {
            addBlock(row.join(' | '), style: 'table-row');
          }
        }
        continue;
      }

      // Block quote.
      final quote = _blockQuote.firstMatch(line);
      if (quote != null) {
        final text = _inlineToPlain(quote.group(1)!);
        addBlock(text, style: 'quote');
        lineIndex++;
        continue;
      }

      // List item.
      final listItem = _listItem.firstMatch(line);
      if (listItem != null) {
        listItemCount++;
        final text = _inlineToPlain(listItem.group(3)!);
        addBlock(text, style: 'list-item');
        lineIndex++;
        continue;
      }

      // Paragraph line: harvest links/images, then strip inline markup.
      for (final match in _imageOrLink.allMatches(line)) {
        if (links.length >= 4096) break;
        links.add({
          'text': _inlineToPlain(match.group(2)!),
          'target': match.group(3)!,
          'isImage': match.group(1) == '!',
        });
      }
      addBlock(_inlineToPlain(line));
      lineIndex++;
    }

    // Trailing metadata summary.
    if (outline.isNotEmpty) metadata['headingCount'] = outline.length;
    if (codeBlockCount > 0) metadata['codeBlockCount'] = codeBlockCount;
    if (listItemCount > 0) metadata['listItemCount'] = listItemCount;
    if (tableCount > 0) metadata['tableCount'] = tableCount;
    if (links.isNotEmpty) metadata['links'] = links;
    if (truncatedText) {
      warnings.add(
        ParseWarning(
          'markdown.text_truncated',
          'text exceeded ${options.limits.maxTextCharacters} characters',
        ),
      );
    }

    if (codeLanguages.isNotEmpty) metadata['codeLanguages'] = codeLanguages;
    final text = textBuffer.toString().trimRight();
    if (text.isNotBlank) {
      metadata['wordCount'] = text.wordCount;
    }

    return ParseResult(
      documentId: digest.sha256,
      digest: digest,
      format: format,
      byteLength: bytes.length,
      metadata: metadata,
      text: text.isBlank ? null : text,
      warnings: warnings,
      structuredText: options.includeStructuredText
          ? StructuredText([TextPage(index: 0, blocks: blocks)])
          : null,
      outline: options.includeOutline ? outline : const [],
      tables: options.includeTables ? tables : const [],
      parserVersion: parserVersion,
    );
  }

  static int? _findFrontMatterClose(List<String> lines) {
    for (var i = 1; i < lines.length; i++) {
      final trimmed = lines[i].trim();
      if (trimmed == '---' || trimmed == '...') return i;
    }
    return null;
  }

  static bool _looksLikeFrontMatter(List<String> lines) {
    if (lines.isEmpty) return false;
    var pairs = 0;
    for (final line in lines) {
      if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
      if (line.contains(':')) pairs++;
    }
    return pairs > 0;
  }

  static bool _looksLikeTableRow(String line) => line.contains('|');

  static bool _isTableSeparator(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return false;
    var sawDash = false;
    for (final rune in trimmed.runes) {
      switch (rune) {
        case 0x7C: // |
        case 0x3A: // :
        case 0x20: // space
        case 0x09: // tab
          continue;
        case 0x2D: // -
          sawDash = true;
          continue;
        default:
          return false;
      }
    }
    return sawDash;
  }

  DocumentTable? _parseTable(List<String> tableLines, ParseOptions options) {
    final rows = <List<String>>[];
    for (var index = 0; index < tableLines.length; index++) {
      final line = tableLines[index];
      if (index == 1 && _isTableSeparator(line)) continue;
      final cells = _splitTableRow(line);
      if (cells.isEmpty) continue;
      if (rows.length >= options.limits.maxTableRows) {
        return DocumentTable(name: null, rows: rows);
      }
      rows.add(cells);
    }
    if (rows.isEmpty) return null;
    final columnLimit = options.limits.maxTableColumns;
    final bounded = [
      for (final row in rows)
        if (row.length > columnLimit) row.sublist(0, columnLimit) else row,
    ];
    return DocumentTable(name: null, rows: bounded);
  }

  static List<String> _splitTableRow(String line) {
    var value = line.trim();
    if (value.startsWith('|')) value = value.substring(1);
    if (value.endsWith('|') && !value.endsWith(r'\|')) {
      value = value.substring(0, value.length - 1);
    }
    final cells = <String>[];
    final buffer = StringBuffer();
    var escaped = false;
    for (var i = 0; i < value.length; i++) {
      final char = value[i];
      if (escaped) {
        buffer.write(char);
        escaped = false;
        continue;
      }
      if (char == r'\') {
        escaped = true;
        continue;
      }
      if (char == '|') {
        cells.add(_inlineToPlain(buffer.toString()));
        buffer.clear();
        continue;
      }
      buffer.write(char);
    }
    cells.add(_inlineToPlain(buffer.toString()));
    return cells;
  }

  static String _inlineToPlain(String input) {
    var text = input.replaceAllMapped(
      _imageOrLink,
      (match) => match.group(2) ?? '',
    );
    text = text.replaceAllMapped(_inlineCode, (match) => match.group(1) ?? '');
    text = text.replaceAllMapped(_strong, (match) => match.group(2) ?? '');
    text = text.replaceAllMapped(_emphasis, (match) => match.group(2) ?? '');
    text = text.replaceAllMapped(_strike, (match) => match.group(1) ?? '');
    text = text.replaceAllMapped(_escaped, (match) => match.group(1) ?? '');
    text = text.removeHtml();
    return text.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
  }

  static Uint8List _peek(Uint8List bytes, int max) =>
      bytes.length <= max ? bytes : Uint8List.sublistView(bytes, 0, max);

  static String _decodeBytes(Uint8List bytes) {
    final utf8Text = bytes.toUtf8StringOrNull();
    return utf8Text ?? latin1.decode(bytes, allowInvalid: true);
  }
}
