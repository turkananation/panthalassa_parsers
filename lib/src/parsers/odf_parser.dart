import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_exception.dart';
import '../core/parse_options.dart';
import '../core/parse_result.dart';
import '../core/structured_artifacts.dart';

/// Parser for OpenDocument Format files (ODT/ODS/ODP — ISO/IEC 26300).
///
/// ODF is a ZIP container. Recognition checks the ZIP local-file-header magic
/// *and* peeks the uncompressed `mimetype` entry (which OpenDocument requires to
/// be the first, STORED entry) so a generic ZIP is never misreported as ODF.
/// Text, headings, tables, slides, metadata, and embedded media are extracted
/// from the container with explicit decompression limits.
final class OdfParser implements DocumentParser, OptionAwareDocumentParser {
  const OdfParser();

  static const _odfMimePrefix = 'application/vnd.oasis.opendocument';

  @override
  DocumentFormat get format => DocumentFormat.odf;

  String get parserVersion => parserImplementationVersion;

  @override
  bool canParse(Uint8List bytes) {
    if (bytes.length < 4) return false;
    // ZIP local file header: 'P' 'K' 0x03 0x04
    if (bytes[0] != 0x50 ||
        bytes[1] != 0x4B ||
        bytes[2] != 0x03 ||
        bytes[3] != 0x04) {
      return false;
    }
    // The OpenDocument spec mandates an uncompressed `mimetype` member as the
    // first entry; its content appears verbatim near the start of the archive.
    final head = ascii.decode(
      Uint8List.sublistView(bytes, 0, bytes.length.clamp(0, 512)),
      allowInvalid: true,
    );
    return head.contains('mimetype') && head.contains(_odfMimePrefix);
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
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const MalformedDocumentException('corrupt ODF (ZIP) container');
    }

    final warnings = <ParseWarning>[];
    final entries = _boundedEntries(archive, options, warnings);

    final mimetype = _readEntry(entries, 'mimetype', options, warnings);
    final mime = mimetype == null
        ? null
        : ascii.decode(mimetype, allowInvalid: true).trim();
    if (mime == null || !mime.startsWith(_odfMimePrefix)) {
      throw const MalformedDocumentException(
        'ODF mimetype entry missing or invalid',
      );
    }

    final contentBytes = _readEntry(entries, 'content.xml', options, warnings);
    if (contentBytes == null) {
      throw const MalformedDocumentException(
        'content.xml not found in ODF container',
      );
    }

    final XmlDocument content;
    try {
      content = XmlDocument.parse(utf8.decode(contentBytes));
    } on XmlException {
      throw const MalformedDocumentException('invalid ODF content.xml');
    } on FormatException {
      throw const TextDecodingException('content.xml is not valid UTF-8');
    }

    final documentClass = _documentClass(mime);
    final textParts = <String>[];
    final blocks = <TextBlock>[];
    final outline = <OutlineEntry>[];
    final tables = <DocumentTable>[];
    final pages = <TextPage>[];

    // Headings first so the outline is available even for formats that also
    // emit tables/slides.
    final headings = content
        .findAllElements('h', namespace: '*')
        .where((e) => e.name.local == 'h')
        .toList(growable: false);
    for (final h in headings.take(options.limits.maxPages)) {
      final title = h.innerText.trim();
      if (title.isEmpty) continue;
      final level = _intAttr(h, 'outline-level') ?? 1;
      outline.add(OutlineEntry(title: title, level: level.clamp(1, 10)));
      blocks.add(
        TextBlock(
          spans: [TextSpan(title)],
          style: 'heading',
          level: level.clamp(1, 10),
        ),
      );
      textParts.add(title);
    }

    if (documentClass == 'spreadsheet') {
      _extractSpreadsheet(content, options, tables, pages, warnings);
    } else if (documentClass == 'presentation') {
      _extractPresentation(content, options, pages, blocks, tables, warnings);
    } else {
      _extractText(content, options, blocks, textParts, tables, warnings);
    }

    // Flat text: preserve the historical paragraph order for ODT, and add sheet
    // or slide content where the document class has no flowing paragraphs.
    if (documentClass == 'text') {
      for (final p in content.findAllElements('p', namespace: '*')) {
        final t = p.innerText.trim();
        if (t.isNotEmpty) textParts.add(t);
      }
    } else {
      for (final page in pages) {
        final t = page.text.trim();
        if (t.isNotEmpty) textParts.add(t);
      }
    }
    if (tables.isNotEmpty) {
      for (final table in tables) {
        textParts.add(
          table.rows
              .map((r) => r.where((c) => c.isNotEmpty).join('\t'))
              .join('\n'),
        );
      }
    }

    final meta = _readMeta(entries, options, warnings);
    final attachments = options.includeAttachments
        ? _attachments(entries, hasher, options, warnings)
        : const <DocumentAttachment>[];

    final text = textParts
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .join('\n');
    final pagesOut = pages.isNotEmpty
        ? pages
        : [
            TextPage(
              index: 0,
              blocks: blocks,
              coordinateSpace: TextCoordinateSpace.unknown,
            ),
          ];

    return ParseResult(
      documentId: digest.sha256,
      digest: digest,
      format: format,
      byteLength: bytes.length,
      metadata: {
        'mimetype': mime,
        'documentClass': documentClass,
        'paragraphCount': textParts.length,
        if (outline.isNotEmpty) 'outlineCount': outline.length,
        if (tables.isNotEmpty) 'tableCount': tables.length,
        ...meta,
      },
      text: text.isEmpty ? null : text,
      warnings: warnings,
      structuredText: options.includeStructuredText
          ? StructuredText(pagesOut)
          : null,
      outline: options.includeOutline ? outline : const [],
      tables: options.includeTables ? tables : const [],
      attachments: attachments,
      parserVersion: parserVersion,
    );
  }

  static String _documentClass(String mime) {
    if (mime.length <= _odfMimePrefix.length) return 'unknown';
    final rest = mime.substring(_odfMimePrefix.length);
    if (rest.startsWith('.')) return rest.substring(1);
    return rest.isEmpty ? 'unknown' : rest;
  }

  // --- text documents -------------------------------------------------------

  void _extractText(
    XmlDocument content,
    ParseOptions options,
    List<TextBlock> blocks,
    List<String> textParts,
    List<DocumentTable> tables,
    List<ParseWarning> warnings,
  ) {
    for (final p in content.findAllElements('p', namespace: '*')) {
      final t = p.innerText.trim();
      if (t.isEmpty) continue;
      blocks.add(TextBlock(spans: [TextSpan(t)], style: 'paragraph'));
    }
    for (final table in content.findAllElements('table', namespace: '*')) {
      if (table.name.local != 'table') continue;
      if (tables.length >= options.limits.maxMetadataEntries) {
        warnings.add(
          const ParseWarning(
            'odf.table_limit',
            'table count exceeded the configured limit',
          ),
        );
        break;
      }
      final parsed = _table(table, options, warnings);
      if (parsed != null) tables.add(parsed);
    }
  }

  // --- spreadsheets ---------------------------------------------------------

  void _extractSpreadsheet(
    XmlDocument content,
    ParseOptions options,
    List<DocumentTable> tables,
    List<TextPage> pages,
    List<ParseWarning> warnings,
  ) {
    var sheetIndex = 0;
    for (final table in content.findAllElements('table', namespace: '*')) {
      if (table.name.local != 'table') continue;
      if (sheetIndex >= options.limits.maxPages) {
        warnings.add(
          const ParseWarning(
            'odf.sheet_limit',
            'sheet count exceeded the configured limit',
          ),
        );
        break;
      }
      final parsed = _table(table, options, warnings);
      if (parsed == null) continue;
      tables.add(parsed);
      final text = parsed.rows
          .map((r) => r.where((c) => c.isNotEmpty).join('\t'))
          .join('\n');
      pages.add(
        TextPage(
          index: sheetIndex,
          label: parsed.name,
          coordinateSpace: TextCoordinateSpace.unknown,
          blocks: text.isEmpty
              ? const []
              : [
                  TextBlock(spans: [TextSpan(text)], style: 'sheet'),
                ],
        ),
      );
      sheetIndex++;
    }
  }

  // --- presentations --------------------------------------------------------

  void _extractPresentation(
    XmlDocument content,
    ParseOptions options,
    List<TextPage> pages,
    List<TextBlock> blocks,
    List<DocumentTable> tables,
    List<ParseWarning> warnings,
  ) {
    var slideIndex = 0;
    for (final slide in content.findAllElements('page', namespace: '*')) {
      if (slide.name.local != 'page') continue;
      if (slideIndex >= options.limits.maxPages) {
        warnings.add(
          const ParseWarning(
            'odf.slide_limit',
            'slide count exceeded the configured limit',
          ),
        );
        break;
      }
      final slideName = _attr(slide, 'name');
      final slideBlocks = <TextBlock>[];
      for (final p in slide.findAllElements('p', namespace: '*')) {
        final t = p.innerText.trim();
        if (t.isEmpty) continue;
        slideBlocks.add(TextBlock(spans: [TextSpan(t)], style: 'paragraph'));
      }
      // Speaker notes live under presentation:notes, outside draw:page text in
      // some generators; include them as a distinct role.
      for (final notes in slide.findAllElements('notes', namespace: '*')) {
        final t = notes.innerText.trim();
        if (t.isNotEmpty) {
          slideBlocks.add(
            TextBlock(spans: [TextSpan(t)], style: 'note', role: 'notes'),
          );
        }
      }
      if (slideName != null && slideName.isNotEmpty) {
        slideBlocks.insert(
          0,
          TextBlock(spans: [TextSpan(slideName)], style: 'heading', level: 1),
        );
      }
      pages.add(
        TextPage(
          index: slideIndex,
          label: slideName,
          coordinateSpace: TextCoordinateSpace.unknown,
          blocks: slideBlocks,
        ),
      );
      for (final table in slide.findAllElements('table', namespace: '*')) {
        if (table.name.local != 'table') continue;
        final parsed = _table(table, options, warnings);
        if (parsed != null) tables.add(parsed);
      }
      slideIndex++;
    }
    if (pages.isEmpty) {
      for (final p in content.findAllElements('p', namespace: '*')) {
        final t = p.innerText.trim();
        if (t.isNotEmpty) blocks.add(TextBlock(spans: [TextSpan(t)]));
      }
    }
  }

  // --- tables ---------------------------------------------------------------

  DocumentTable? _table(
    XmlElement table,
    ParseOptions options,
    List<ParseWarning> warnings,
  ) {
    final name = _attr(table, 'name');
    final rows = <List<String>>[];
    var truncated = false;
    for (final rowEl in table.findAllElements('table-row', namespace: '*')) {
      final rowRepeat = (_intAttr(rowEl, 'number-rows-repeated') ?? 1).clamp(
        1,
        100000,
      );
      final cells = <String>[];
      for (final child in rowEl.children.whereType<XmlElement>()) {
        if (child.name.local == 'table-cell' ||
            child.name.local == 'covered-table-cell') {
          _appendCell(child, cells, options, () => truncated = true);
        }
      }
      if (cells.isEmpty) continue;
      final remaining = options.limits.maxTableRows - rows.length;
      if (remaining <= 0) {
        truncated = true;
        break;
      }
      final repeat = rowRepeat > remaining ? remaining : rowRepeat;
      for (var i = 0; i < repeat; i++) {
        rows.add(List<String>.from(cells));
      }
      if (repeat < rowRepeat) {
        truncated = true;
        break;
      }
    }
    if (truncated) {
      warnings.add(
        const ParseWarning(
          'odf.table_truncated',
          'table exceeded the configured row/column limits',
        ),
      );
    }
    if (rows.isEmpty) return null;
    return DocumentTable(name: name, rows: rows);
  }

  void _appendCell(
    XmlElement cell,
    List<String> out,
    ParseOptions options,
    void Function() truncate,
  ) {
    final value = _cellText(cell);
    final repeat = (_intAttr(cell, 'number-columns-repeated') ?? 1).clamp(
      1,
      100000,
    );
    final remaining = options.limits.maxTableColumns - out.length;
    if (remaining <= 0) {
      truncate();
      return;
    }
    final n = repeat > remaining ? remaining : repeat;
    for (var i = 0; i < n; i++) {
      out.add(value);
    }
    if (n < repeat) truncate();
  }

  String _cellText(XmlElement cell) {
    final paragraphs = cell
        .findAllElements('p', namespace: '*')
        .map((p) => p.innerText.trim())
        .where((t) => t.isNotEmpty)
        .toList(growable: false);
    if (paragraphs.isNotEmpty) return paragraphs.join(' ');
    final formula = _attr(cell, 'formula');
    final valueType = _attr(cell, 'value-type');
    if (valueType != null) {
      final value =
          _attr(cell, 'value') ??
          _attr(cell, 'date-value') ??
          _attr(cell, 'time-value') ??
          _attr(cell, 'boolean-value');
      if (value != null) return value;
    }
    return formula ?? '';
  }

  // --- metadata -------------------------------------------------------------

  Map<String, Object?> _readMeta(
    List<ArchiveFile> entries,
    ParseOptions options,
    List<ParseWarning> warnings,
  ) {
    final metaBytes = _readEntry(entries, 'meta.xml', options, warnings);
    if (metaBytes == null) return const {};
    try {
      final doc = XmlDocument.parse(utf8.decode(metaBytes));
      String text(String local) => doc
          .findAllElements(local, namespace: '*')
          .map((e) => e.innerText.trim())
          .firstWhere((v) => v.isNotEmpty, orElse: () => '');

      final title = text('title');
      final creator = text('creator');
      final initialCreator = text('initial-creator');
      final created = text('creation-date');
      final modified = text('date');
      final subject = text('subject');
      final description = text('description');
      final generator = text('generator');
      final keywords = doc
          .findAllElements('keyword', namespace: '*')
          .map((e) => e.innerText.trim())
          .where((v) => v.isNotEmpty)
          .toList(growable: false);
      final pageCount = doc
          .findAllElements('document-statistic', namespace: '*')
          .map((e) => _intAttr(e, 'page-count'))
          .whereType<int>()
          .firstOrNull;
      final wordCount = doc
          .findAllElements('document-statistic', namespace: '*')
          .map((e) => _intAttr(e, 'word-count'))
          .whereType<int>()
          .firstOrNull;
      return {
        if (title.isNotEmpty) 'title': title,
        if (creator.isNotEmpty) 'creator': creator,
        if (initialCreator.isNotEmpty) 'initialCreator': initialCreator,
        if (created.isNotEmpty) 'creationDate': created,
        if (modified.isNotEmpty) 'modDate': modified,
        if (subject.isNotEmpty) 'subject': subject,
        if (description.isNotEmpty) 'description': description,
        if (generator.isNotEmpty) 'generator': generator,
        if (keywords.isNotEmpty) 'keywords': keywords,
        'pageCount': ?pageCount,
        'wordCount': ?wordCount,
      };
    } catch (_) {
      warnings.add(
        const ParseWarning('odf.meta_invalid', 'meta.xml could not be parsed'),
      );
      return const {};
    }
  }

  // --- attachments ----------------------------------------------------------

  List<DocumentAttachment> _attachments(
    List<ArchiveFile> entries,
    ContentHasher hasher,
    ParseOptions options,
    List<ParseWarning> warnings,
  ) {
    final out = <DocumentAttachment>[];
    var total = 0;
    for (final entry in entries) {
      final name = entry.name;
      if (!name.startsWith('Pictures/') &&
          !name.startsWith('EmbeddedObjects/') &&
          !name.startsWith('ObjectReplacements/')) {
        continue;
      }
      if (out.length >= options.limits.maxAttachments) {
        warnings.add(
          const ParseWarning(
            'odf.attachment_limit',
            'attachment count exceeded the configured limit',
          ),
        );
        break;
      }
      final declared = entry.size;
      if (declared < 0 ||
          declared > options.limits.maxDecompressedEntryBytes ||
          total + declared > options.limits.maxAttachmentBytes) {
        warnings.add(
          const ParseWarning(
            'odf.attachment_byte_limit',
            'attachment payload exceeded the configured byte limit',
          ),
        );
        continue;
      }
      Uint8List? data;
      try {
        data = Uint8List.fromList(entry.content as List<int>);
      } catch (_) {
        data = null;
      }
      if (data == null) continue;
      total += data.length;
      out.add(
        DocumentAttachment(
          name: name.split('/').last,
          mediaType: _mediaType(name),
          size: data.length,
          digest: hasher.digestFor(data),
          bytes: options.includeAttachmentBytes ? data : null,
          path: name.split('/'),
        ),
      );
    }
    return out;
  }

  static String? _mediaType(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.png')) return 'image/png';
    if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
    if (n.endsWith('.gif')) return 'image/gif';
    if (n.endsWith('.svg')) return 'image/svg+xml';
    if (n.endsWith('.webp')) return 'image/webp';
    if (n.endsWith('.tif') || n.endsWith('.tiff')) return 'image/tiff';
    if (n.endsWith('.xml')) return 'application/xml';
    if (n.endsWith('.json')) return 'application/json';
    if (n.endsWith('.pdf')) return 'application/pdf';
    if (n.endsWith('.odt')) return 'application/vnd.oasis.opendocument.text';
    if (n.endsWith('.ods')) {
      return 'application/vnd.oasis.opendocument.spreadsheet';
    }
    if (n.endsWith('.odp')) {
      return 'application/vnd.oasis.opendocument.presentation';
    }
    return null;
  }

  // --- ZIP bounds -----------------------------------------------------------

  List<ArchiveFile> _boundedEntries(
    Archive archive,
    ParseOptions options,
    List<ParseWarning> warnings,
  ) {
    final out = <ArchiveFile>[];
    var total = 0;
    var truncated = false;
    for (final file in archive.files) {
      if (!file.isFile) continue;
      final size = file.size;
      if (size < 0 || size > options.limits.maxDecompressedEntryBytes) {
        truncated = true;
        continue;
      }
      if (total + size > options.limits.maxDecompressedBytes) {
        truncated = true;
        break;
      }
      total += size;
      out.add(file);
    }
    if (truncated) {
      warnings.add(
        const ParseWarning(
          'odf.decompression_limit',
          'ODF container exceeded the configured decompression limits',
        ),
      );
    }
    return out;
  }

  Uint8List? _readEntry(
    List<ArchiveFile> entries,
    String name,
    ParseOptions options,
    List<ParseWarning> warnings,
  ) {
    for (final file in entries) {
      if (file.name != name) continue;
      if (file.size > options.limits.maxDecompressedEntryBytes) {
        warnings.add(
          ParseWarning(
            'odf.entry_too_large',
            '$name exceeded the per-entry decompression limit',
          ),
        );
        return null;
      }
      try {
        return Uint8List.fromList(file.content as List<int>);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static String? _attr(XmlElement e, String local) {
    for (final a in e.attributes) {
      if (a.name.local == local) return a.value;
    }
    return null;
  }

  static int? _intAttr(XmlElement e, String local) {
    final v = _attr(e, local);
    return v == null ? null : int.tryParse(v);
  }
}
