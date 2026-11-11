import 'dart:convert';
import 'dart:typed_data';

import 'package:swissarmyknife/swissarmyknife.dart';

import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_exception.dart';
import '../core/parse_options.dart';
import '../core/parse_result.dart';
import '../core/structured_artifacts.dart';

/// Parser for CSV, TSV, and other delimited text files.
///
/// These formats have no reliable magic bytes, so detection requires a
/// [DocumentHints] filename (`.csv`, `.tsv`, `.tab`) or MIME type (`text/csv`,
/// `text/tab-separated-values`, `application/vnd.ms-excel`, `text/plain`).
/// Without a hint the parser declines rather than claiming arbitrary text.
///
/// Parsing is a single-pass, quote-aware state machine over the whole document,
/// so quoted fields may contain delimiters and embedded newlines. The delimiter
/// is chosen by scoring candidate separators against record-shape consistency
/// across the first records. TSV hints force a tab delimiter.
final class CsvParser
    implements
        DocumentParser,
        OptionAwareDocumentParser,
        HintAwareDocumentParser {
  const CsvParser();

  static const List<int> _candidateDelimiters = [0x2C, 0x09, 0x7C, 0x3B];
  static const Set<String> _extensions = {'csv', 'tsv', 'tab', 'txt'};
  static const Set<String> _mimeTypes = {
    'text/csv',
    'text/tab-separated-values',
    'application/vnd.ms-excel',
    'text/plain',
  };

  @override
  DocumentFormat get format => DocumentFormat.csv;

  String get parserVersion => parserImplementationVersion;

  @override
  bool canParse(Uint8List bytes) {
    // Delimited text has no reliable magic; always decline without hints.
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
    return _peek(bytes, 8192).toUtf8StringOrNull() != null;
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

    if (decoded.usedLatin1Fallback) {
      warnings.add(
        const ParseWarning(
          'csv.encoding_fallback',
          'input is not valid UTF-8; decoded as Latin-1',
        ),
      );
    }

    final text = decoded.text;
    if (text.isBlank) {
      throw const MalformedDocumentException('CSV/TSV has no content rows');
    }

    final forcedDelimiter = _forcedDelimiter(hints);
    final delimiter = forcedDelimiter ?? _detectDelimiter(text, options);
    final delimiterName = switch (delimiter) {
      0x2C => ',',
      0x09 => 'tab',
      0x7C => '|',
      0x3B => ';',
      _ => String.fromCharCode(delimiter),
    };
    metadata['delimiter'] = delimiterName;

    final scan = _scan(
      text,
      delimiter,
      maxRecords: options.limits.maxTableRows + 1,
      maxColumns: options.limits.maxTableColumns,
    );
    if (scan.records.isEmpty) {
      throw const MalformedDocumentException('CSV/TSV has no content rows');
    }
    if (scan.unterminatedQuote) {
      warnings.add(
        const ParseWarning(
          'csv.unterminated_quote',
          'quoted field was not closed before end of document',
        ),
      );
    }
    if (scan.truncatedRows) {
      warnings.add(
        ParseWarning(
          'csv.rows_truncated',
          'row count exceeded ${options.limits.maxTableRows}',
        ),
      );
    }
    if (scan.truncatedColumns) {
      warnings.add(
        ParseWarning(
          'csv.columns_truncated',
          'columns were limited to ${options.limits.maxTableColumns}',
        ),
      );
    }

    final records = scan.records;
    final header = records.first;
    final dataRows = records.length > 1
        ? records.sublist(1)
        : const <List<String>>[];
    metadata['headerRow'] = header;
    metadata['columnCount'] = header.length;
    metadata['rowCount'] = dataRows.length;
    metadata['totalRowCount'] = records.length;
    metadata['isTabSeparated'] = delimiter == 0x09;

    final raggedRows = <int>[];
    for (var i = 0; i < dataRows.length; i++) {
      if (dataRows[i].length != header.length) raggedRows.add(i + 2);
    }
    if (raggedRows.isNotEmpty) {
      warnings.add(
        ParseWarning(
          'csv.ragged_rows',
          '${raggedRows.length} row(s) do not match the '
              '${header.length}-column header',
        ),
      );
      metadata['raggedRowNumbers'] = raggedRows.take(100).toList();
    }

    final table = DocumentTable(name: hints?.filename, rows: records);

    final textBuffer = StringBuffer();
    var textTruncated = false;
    for (final row in records) {
      final line = '${row.join('\t')}\n';
      if (textBuffer.length + line.length > options.limits.maxTextCharacters) {
        final remaining = options.limits.maxTextCharacters - textBuffer.length;
        if (remaining > 0) {
          textBuffer.write(line.substring(0, remaining));
        }
        textTruncated = true;
        break;
      }
      textBuffer.write(line);
    }
    if (textTruncated) {
      warnings.add(
        ParseWarning(
          'csv.text_truncated',
          'text exceeded ${options.limits.maxTextCharacters} characters',
        ),
      );
    }

    return ParseResult(
      documentId: digest.sha256,
      digest: digest,
      format: format,
      byteLength: bytes.length,
      metadata: metadata,
      text: textBuffer.toString().trimRight(),
      warnings: warnings,
      structuredText: options.includeStructuredText
          ? StructuredText([
              TextPage(
                index: 0,
                blocks: [
                  for (final row in records)
                    TextBlock(
                      spans: [
                        for (final cell in row) TextSpan(cell, style: 'cell'),
                      ],
                      style: 'table-row',
                    ),
                ],
              ),
            ])
          : null,
      tables: options.includeTables ? [table] : const [],
      parserVersion: parserVersion,
    );
  }

  static int? _forcedDelimiter(DocumentHints? hints) {
    if (hints == null) return null;
    final ext = hints.extension ?? '';
    final mime = hints.mimeType ?? '';
    if (ext == 'tsv' || ext == 'tab' || mime == 'text/tab-separated-values') {
      return 0x09;
    }
    return null;
  }

  /// Chooses the separator that yields the most consistent multi-column shape
  /// across the first records. Parsing is bounded so a hostile line cannot
  /// allocate an unbounded field list.
  static int _detectDelimiter(String text, ParseOptions options) {
    var best = 0x2C;
    var bestScore = 0.0;
    for (final candidate in _candidateDelimiters) {
      final scan = _scan(
        text,
        candidate,
        maxRecords: 20,
        maxColumns: options.limits.maxTableColumns,
      );
      if (scan.records.isEmpty) continue;
      final counts = <int, int>{};
      for (final record in scan.records) {
        counts[record.length] = (counts[record.length] ?? 0) + 1;
      }
      if (counts.isEmpty) continue;
      final mode = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
      if (mode.key < 2) continue;
      final consistency = mode.value / scan.records.length;
      final score = mode.key * consistency;
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }
    return best;
  }

  static _CsvScan _scan(
    String text,
    int delimiter, {
    required int maxRecords,
    required int maxColumns,
  }) {
    final records = <List<String>>[];
    var fields = <String>[];
    final buffer = StringBuffer();
    var inQuotes = false;
    var fieldStarted = false;
    var truncatedRows = false;
    var truncatedColumns = false;
    var unterminatedQuote = false;
    var i = 0;

    void finishField() {
      if (fields.length < maxColumns) {
        fields.add(buffer.toString());
      } else {
        truncatedColumns = true;
      }
      buffer.clear();
      fieldStarted = false;
    }

    void finishRecord() {
      if (!fieldStarted && fields.isEmpty && buffer.isEmpty) return;
      finishField();
      records.add(fields);
      fields = <String>[];
    }

    while (i < text.length) {
      final code = text.codeUnitAt(i);
      if (inQuotes) {
        if (code == 0x22) {
          if (i + 1 < text.length && text.codeUnitAt(i + 1) == 0x22) {
            buffer.write('"');
            i += 2;
            continue;
          }
          inQuotes = false;
          i++;
          continue;
        }
        buffer.writeCharCode(code);
        i++;
        continue;
      }

      if (code == 0x22 && buffer.isEmpty) {
        inQuotes = true;
        fieldStarted = true;
        i++;
        continue;
      }
      if (code == delimiter) {
        finishField();
        fieldStarted = true;
        i++;
        continue;
      }
      if (code == 0x0D || code == 0x0A) {
        finishRecord();
        if (records.length >= maxRecords) {
          truncatedRows = true;
          break;
        }
        if (code == 0x0D &&
            i + 1 < text.length &&
            text.codeUnitAt(i + 1) == 0x0A) {
          i += 2;
        } else {
          i++;
        }
        continue;
      }
      buffer.writeCharCode(code);
      fieldStarted = true;
      i++;
    }

    if (inQuotes) unterminatedQuote = true;
    if (!truncatedRows &&
        (fieldStarted || fields.isNotEmpty || buffer.isNotEmpty)) {
      finishRecord();
    }

    return _CsvScan(
      records: records,
      truncatedRows: truncatedRows,
      truncatedColumns: truncatedColumns,
      unterminatedQuote: unterminatedQuote,
    );
  }

  static Uint8List _peek(Uint8List bytes, int max) =>
      bytes.length <= max ? bytes : Uint8List.sublistView(bytes, 0, max);

  static _DecodedText _decodeBytes(Uint8List bytes) {
    var start = 0;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      start = 3; // UTF-8 BOM
    }
    final slice = start == 0 ? bytes : Uint8List.sublistView(bytes, start);
    final utf8Text = slice.toUtf8StringOrNull();
    if (utf8Text != null) return _DecodedText(utf8Text, false);
    return _DecodedText(latin1.decode(bytes, allowInvalid: true), true);
  }
}

final class _CsvScan {
  const _CsvScan({
    required this.records,
    required this.truncatedRows,
    required this.truncatedColumns,
    required this.unterminatedQuote,
  });

  final List<List<String>> records;
  final bool truncatedRows;
  final bool truncatedColumns;
  final bool unterminatedQuote;
}

final class _DecodedText {
  const _DecodedText(this.text, this.usedLatin1Fallback);

  final String text;
  final bool usedLatin1Fallback;
}
