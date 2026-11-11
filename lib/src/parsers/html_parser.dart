import 'dart:convert';
import 'dart:typed_data';

import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_options.dart';
import '../core/parse_result.dart';
import '../core/structured_artifacts.dart';

/// Parser for HTML / XHTML documents.
///
/// Detection looks for `<!doctype html` or `<html` after the XML parsers have
/// had a chance, so XHTML that is also valid FHIR/XML is claimed by the more
/// specific parser first. Extraction is tolerant: tag stripping, heading,
/// link, table, and metadata harvesting use regexes rather than a strict DOM,
/// so malformed HTML still yields usable text.
///
/// Text content is extracted; scripts, styles, and external resource references
/// are surfaced as warnings but never fetched.
final class HtmlParser
    implements
        DocumentParser,
        OptionAwareDocumentParser,
        HintAwareDocumentParser {
  const HtmlParser();

  static final _doctypeRegExp = RegExp(
    r'<!doctype\s+html',
    caseSensitive: false,
  );
  static final _htmlOpenRegExp = RegExp(r'<\s*html\b', caseSensitive: false);
  static final _titleRegExp = RegExp(
    r'<title[^>]*>(.*?)</title>',
    caseSensitive: false,
    dotAll: true,
  );
  static final _metaRegExp = RegExp(
    "<meta[^>]+(?:name|property|http-equiv)\\s*=\\s*[\"']([^\"']+)[\"'][^>]+content\\s*=\\s*[\"']([^\"']*)[\"']",
    caseSensitive: false,
  );
  static final _headingRegExp = RegExp(
    r'<h([1-6])[^>]*>(.*?)</h\1>',
    caseSensitive: false,
    dotAll: true,
  );
  static final _linkRegExp = RegExp(
    "<a[^>]+href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>",
    caseSensitive: false,
    dotAll: true,
  );
  static final _tableRegExp = RegExp(
    r'<table[^>]*>(.*?)</table>',
    caseSensitive: false,
    dotAll: true,
  );
  static final _tableRowRegExp = RegExp(
    r'<tr[^>]*>(.*?)</tr>',
    caseSensitive: false,
    dotAll: true,
  );
  static final _tableCellRegExp = RegExp(
    r'<t[hd][^>]*>(.*?)</t[hd]>',
    caseSensitive: false,
    dotAll: true,
  );
  static final _tagRegExp = RegExp(r'<[^>]*>');
  static final _scriptRegExp = RegExp(
    r'<(script|style)[^>]*>.*?</\1>',
    caseSensitive: false,
    dotAll: true,
  );
  static final _entityRegExp = RegExp(
    r'&(#\d+|#x[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);',
  );

  @override
  DocumentFormat get format => DocumentFormat.html;

  String get parserVersion => parserImplementationVersion;

  @override
  bool canParse(Uint8List bytes) {
    final prefix = _peek(bytes, 2048);
    if (prefix.isEmpty) return false;
    final lower = prefix.toLowerCase();
    return _doctypeRegExp.hasMatch(lower) || _htmlOpenRegExp.hasMatch(lower);
  }

  @override
  bool canParseWithHints(Uint8List bytes, DocumentHints hints) {
    if (!canParse(bytes)) return false;
    final ext = hints.extension ?? '';
    if (ext.isEmpty) return true;
    return switch (ext) {
      'html' || 'htm' || 'xhtml' => true,
      _ => false,
    };
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
    final source = _decodeBytes(bytes);
    final warnings = <ParseWarning>[];
    final metadata = <String, Object?>{};

    // Remove script/style content first.
    final clean = source.replaceAllMapped(_scriptRegExp, (m) => ' ');

    // Title.
    final titleMatch = _titleRegExp.firstMatch(clean);
    final title = titleMatch != null ? _unescape(titleMatch.group(1)!) : '';
    if (title.isNotEmpty) metadata['title'] = title;

    // Meta tags.
    final metaEntries = <String, String>{};
    for (final m in _metaRegExp.allMatches(clean)) {
      metaEntries[m.group(1)!] = m.group(2) ?? '';
    }
    if (metaEntries.isNotEmpty) metadata['meta'] = metaEntries;

    // Headings.
    final headings = <OutlineEntry>[];
    for (final m in _headingRegExp.allMatches(clean)) {
      final level = int.tryParse(m.group(1)!) ?? 1;
      final text = _stripTags(m.group(2)!).trim();
      if (text.isNotEmpty) {
        headings.add(OutlineEntry(title: text, level: level.clamp(1, 6)));
      }
    }

    // Links.
    final links = <Map<String, String>>[];
    for (final m in _linkRegExp.allMatches(clean)) {
      links.add({
        'href': _unescape(m.group(1)!),
        'text': _stripTags(m.group(2)!).trim(),
      });
    }
    if (links.isNotEmpty) metadata['links'] = links;

    // External resource references (images, stylesheets, etc.) — warnings only.
    final externalRefs = <String>[];
    final externalRegExp = RegExp(
      "<(?:img|link|script|iframe)[^>]+(?:src|href)\\s*=\\s*[\"']([^\"']+)[\"']",
      caseSensitive: false,
    );
    for (final m in externalRegExp.allMatches(clean)) {
      externalRefs.add(m.group(1)!);
    }
    if (externalRefs.isNotEmpty) {
      metadata['externalResources'] = externalRefs;
      warnings.add(
        ParseWarning(
          'html.external_resources',
          '${externalRefs.length} external resource reference(s) not fetched',
        ),
      );
    }

    // Tables.
    final tables = <DocumentTable>[];
    for (final m in _tableRegExp.allMatches(clean)) {
      if (tables.length >= options.limits.maxTableRows) {
        warnings.add(
          const ParseWarning(
            'html.table_limit',
            'table count exceeded the configured limit',
          ),
        );
        break;
      }
      final tbl = _parseTable(m.group(1)!);
      if (tbl != null && tbl.rows.isNotEmpty) tables.add(tbl);
    }

    // Plain text: strip all tags, decode entities, collapse whitespace.
    var text = clean.replaceAllMapped(_tagRegExp, (m) => ' ');
    text = _unescapeEntities(text);
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();

    return ParseResult(
      documentId: digest.sha256,
      digest: digest,
      format: format,
      byteLength: bytes.length,
      metadata: metadata,
      text: text.isEmpty ? null : text,
      warnings: warnings,
      outline: options.includeOutline ? headings : const [],
      tables: options.includeTables ? tables : const [],
      structuredText: options.includeStructuredText && headings.isNotEmpty
          ? StructuredText([
              TextPage(
                index: 0,
                blocks: [
                  for (final h in headings)
                    TextBlock(
                      spans: [TextSpan(h.title)],
                      style: 'heading',
                      level: h.level,
                    ),
                  if (text.isNotEmpty)
                    TextBlock(spans: [TextSpan(text)], style: 'paragraph'),
                ],
              ),
            ])
          : null,
      parserVersion: parserVersion,
    );
  }

  DocumentTable? _parseTable(String tableHtml) {
    final rows = <List<String>>[];
    for (final rowMatch in _tableRowRegExp.allMatches(tableHtml)) {
      final rowContent = rowMatch.group(1)!;
      final cells = <String>[];
      for (final cellMatch in _tableCellRegExp.allMatches(rowContent)) {
        cells.add(_stripTags(cellMatch.group(1)!).trim());
      }
      if (cells.isNotEmpty) rows.add(cells);
    }
    if (rows.isEmpty) return null;
    return DocumentTable(rows: rows);
  }

  static String _stripTags(String html) {
    return html.replaceAllMapped(_tagRegExp, (m) => ' ');
  }

  static String _unescape(String html) {
    return _unescapeEntities(html);
  }

  static String _unescapeEntities(String text) {
    return text.replaceAllMapped(_entityRegExp, (m) {
      final entity = m.group(1)!;
      if (entity.startsWith('#x')) {
        final code = int.tryParse(entity.substring(2), radix: 16);
        if (code != null) return String.fromCharCode(code);
      } else if (entity.startsWith('#')) {
        final code = int.tryParse(entity.substring(1));
        if (code != null) return String.fromCharCode(code);
      }
      return switch (entity.toLowerCase()) {
        'amp' => '&',
        'lt' => '<',
        'gt' => '>',
        'quot' => '"',
        'apos' => "'",
        'nbsp' => ' ',
        'copy' => '©',
        'reg' => '®',
        'trade' => '™',
        'mdash' => '—',
        'ndash' => '–',
        'lsquo' => '‘',
        'rsquo' => '’',
        'ldquo' => '“',
        'rdquo' => '”',
        'hellip' => '…',
        'euro' => '€',
        _ => m.group(0)!,
      };
    });
  }

  String _peek(Uint8List bytes, int max) {
    final slice = bytes.length <= max
        ? bytes
        : Uint8List.sublistView(bytes, 0, max);
    try {
      return latin1.decode(slice, allowInvalid: true);
    } catch (_) {
      return '';
    }
  }

  String _decodeBytes(Uint8List bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      return latin1.decode(bytes, allowInvalid: true);
    } catch (_) {
      return latin1.decode(bytes, allowInvalid: true);
    }
  }
}
