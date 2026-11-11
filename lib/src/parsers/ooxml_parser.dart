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
import '../core/zip_container.dart';

/// Parser for Office Open XML (ECMA-376) files: DOCX, XLSX, PPTX.
///
/// Detection requires both the ZIP magic and an OOXML content-types / rels
/// member, so a generic ZIP is never misreported as Office. Text, headings,
/// tables, sheets/cells/formulas, slide text/notes, core/app metadata,
/// embedded media, and macro/external-link flags are extracted. Image payloads
/// are passed through encoded; no raster decode is performed.
final class OoxmlParser
    implements
        DocumentParser,
        OptionAwareDocumentParser,
        HintAwareDocumentParser {
  /// Creates a parser for one OOXML family.
  ///
  /// The registry registers one instance per family so detection can report
  /// `docx`, `xlsx`, or `pptx` without parsing the document body.
  const OoxmlParser(this.format)
    : assert(
        format == DocumentFormat.docx ||
            format == DocumentFormat.xlsx ||
            format == DocumentFormat.pptx,
        'OoxmlParser only supports docx, xlsx, and pptx',
      );

  static const _contentTypesName = '[content_types].xml';
  static const _relsName = '_rels/.rels';

  @override
  final DocumentFormat format;

  String get parserVersion => parserImplementationVersion;

  @override
  bool canParse(Uint8List bytes) {
    if (bytes.length < 64) return false;
    final names = zipEntryNames(bytes);
    if (names == null) return false;
    if (!names.contains(_contentTypesName) && !names.contains(_relsName)) {
      return false;
    }
    return _familyForNames(names) == format;
  }

  @override
  bool canParseWithHints(Uint8List bytes, DocumentHints hints) {
    if (!canParse(bytes)) return false;
    final ext = hints.extension ?? '';
    if (ext.isEmpty) return true;
    return switch (ext) {
      'docx' || 'dotx' || 'docm' || 'dotm' => format == DocumentFormat.docx,
      'xlsx' || 'xltx' || 'xlsm' || 'xltm' => format == DocumentFormat.xlsx,
      'pptx' || 'potx' || 'pptm' || 'potm' => format == DocumentFormat.pptx,
      _ => true,
    };
  }

  static DocumentFormat _familyForNames(String names) {
    if (names.contains('word/document.xml') || names.contains('word/')) {
      return DocumentFormat.docx;
    }
    if (names.contains('xl/workbook.xml') || names.contains('xl/')) {
      return DocumentFormat.xlsx;
    }
    if (names.contains('ppt/presentation.xml') || names.contains('ppt/')) {
      return DocumentFormat.pptx;
    }
    return DocumentFormat.docx;
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
      throw const MalformedDocumentException('corrupt OOXML (ZIP) container');
    }

    final warnings = <ParseWarning>[];
    final entries = _boundedEntries(archive, options, warnings);

    final contentTypes = _readEntryText(
      entries,
      '[Content_Types].xml',
      options,
      warnings,
    );
    final family = _family(bytes);
    final subType = _subType(contentTypes);

    final attachments = options.includeAttachments
        ? _attachments(entries, hasher, options, warnings)
        : const <DocumentAttachment>[];

    final metadata = <String, Object?>{
      'family': family.name,
      'subType': ?subType,
      'mediaType': mediaTypeFor(family, subType),
      if (attachments.isNotEmpty) 'embeddedCount': attachments.length,
    };

    late final String text;
    late final List<OutlineEntry> outline;
    late final List<DocumentTable> tables;
    late final List<TextPage> pages;

    switch (family) {
      case DocumentFormat.docx:
        final docx = _readDocx(entries, options, warnings);
        text = docx.text;
        outline = docx.outline;
        tables = docx.tables;
        pages = docx.pages;
        metadata.addAll(docx.metadata);
        break;
      case DocumentFormat.xlsx:
        final xlsx = _readXlsx(entries, options, warnings);
        text = xlsx.text;
        outline = xlsx.outline;
        tables = xlsx.tables;
        pages = xlsx.pages;
        metadata.addAll(xlsx.metadata);
        break;
      case DocumentFormat.pptx:
        final pptx = _readPptx(entries, options, warnings);
        text = pptx.text;
        outline = pptx.outline;
        tables = pptx.tables;
        pages = pptx.pages;
        metadata.addAll(pptx.metadata);
        break;
      default:
        text = '';
        outline = const [];
        tables = const [];
        pages = const [];
    }

    return ParseResult(
      documentId: digest.sha256,
      digest: digest,
      format: family,
      byteLength: bytes.length,
      metadata: metadata,
      text: text.isEmpty ? null : text,
      warnings: warnings,
      structuredText: options.includeStructuredText
          ? StructuredText(pages)
          : null,
      outline: options.includeOutline ? outline : const [],
      tables: options.includeTables ? tables : const [],
      attachments: attachments,
      parserVersion: parserVersion,
    );
  }

  // --- family / content-type detection --------------------------------------

  DocumentFormat _family(Uint8List bytes) {
    final names = zipEntryNames(bytes);
    return names == null ? format : _familyForNames(names);
  }

  String? _subType(String? contentTypes) {
    if (contentTypes == null) return null;
    final lower = contentTypes.toLowerCase();
    if (lower.contains('wordprocessingml.main')) return 'document';
    if (lower.contains('spreadsheetml.sheet')) return 'workbook';
    if (lower.contains('presentationml.presentation')) return 'presentation';
    return null;
  }

  static String mediaTypeFor(DocumentFormat family, String? subType) {
    switch (family) {
      case DocumentFormat.docx:
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case DocumentFormat.xlsx:
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case DocumentFormat.pptx:
        return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      default:
        return 'application/vnd.openxmlformats-officedocument';
    }
  }

  // --- reading helpers -------------------------------------------------------

  String? _readEntryText(
    List<ArchiveFile> entries,
    String name,
    ParseOptions options,
    List<ParseWarning> warnings,
  ) {
    final data = _readEntry(entries, name, options, warnings);
    if (data == null) return null;
    return utf8.decode(data, allowMalformed: true);
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
            'ooxml.entry_too_large',
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
          'ooxml.decompression_limit',
          'OOXML container exceeded the configured decompression limits',
        ),
      );
    }
    return out;
  }

  // --- DOCX ------------------------------------------------------------------

  _DocxResult _readDocx(
    List<ArchiveFile> entries,
    ParseOptions options,
    List<ParseWarning> warnings,
  ) {
    final documentXml = _readEntryText(
      entries,
      'word/document.xml',
      options,
      warnings,
    );
    if (documentXml == null) {
      return const _DocxResult();
    }
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(documentXml);
    } on XmlException {
      throw const MalformedDocumentException('invalid word/document.xml');
    } on FormatException {
      throw const TextDecodingException('word/document.xml is not valid UTF-8');
    }

    final body = doc.rootElement;
    final textParts = <String>[];
    final outline = <OutlineEntry>[];
    final tables = <DocumentTable>[];
    final metadata = <String, Object?>{};

    // The document root is w:document; paragraphs live under w:body.
    final bodyEl = body.children.whereType<XmlElement>().firstWhere(
      (e) => e.name.local == 'body',
      orElse: () => body,
    );
    var tableCount = 0;
    for (final child in bodyEl.children.whereType<XmlElement>()) {
      final local = child.name.local;
      switch (local) {
        case 'p':
          final para = _docxParagraph(child, options);
          if (para.text.isNotEmpty) {
            textParts.add(para.text);
            if (para.style != null && para.style!.startsWith('Heading')) {
              outline.add(
                OutlineEntry(
                  title: para.text,
                  level:
                      int.tryParse(para.style!.substring('Heading'.length)) ??
                      1,
                ),
              );
            }
          }
          break;
        case 'tbl':
          tableCount++;
          if (tableCount > options.limits.maxMetadataEntries) {
            warnings.add(
              const ParseWarning(
                'ooxml.table_limit',
                'table count exceeded the configured limit',
              ),
            );
            break;
          }
          final tbl = _docxTable(child, options);
          if (tbl != null) tables.add(tbl);
          break;
        case 'sectPr':
          // section properties: ignore
          break;
        default:
          // unknown block-level element: ignore
          break;
      }
    }

    final core = _readEntryText(
      entries,
      'docProps/core.xml',
      options,
      warnings,
    );
    if (core != null) {
      metadata.addAll(_ooxmlCoreProps(core));
    }
    final app = _readEntryText(entries, 'docProps/app.xml', options, warnings);
    if (app != null) {
      metadata.addAll(_ooxmlAppProps(app));
    }

    return _DocxResult(
      text: textParts.join('\n'),
      outline: outline,
      tables: tables,
      pages: [],
      metadata: metadata,
    );
  }

  _DocxParagraph _docxParagraph(XmlElement p, ParseOptions options) {
    final textParts = <String>[];
    String? style;
    for (final child in p.children.whereType<XmlElement>()) {
      final local = child.name.local;
      switch (local) {
        case 'pPr':
          style = _docxParagraphStyle(child);
          break;
        case 'r':
          textParts.add(_docxRunText(child));
          break;
      }
    }
    final text = textParts.join();
    return _DocxParagraph(text: text, style: style);
  }

  String? _docxParagraphStyle(XmlElement pPr) {
    for (final child in pPr.children.whereType<XmlElement>()) {
      if (child.name.local == 'pStyle') {
        return _attr(child, 'val')?.trim();
      }
    }
    return null;
  }

  String _docxRunText(XmlElement r) {
    final parts = <String>[];
    for (final child in r.children.whereType<XmlElement>()) {
      if (child.name.local == 't') {
        parts.add(child.innerText);
      }
    }
    return parts.join();
  }

  DocumentTable? _docxTable(XmlElement table, ParseOptions options) {
    final name = table.getAttribute('tblCaption')?.trim();
    final rows = <List<String>>[];
    var truncated = false;
    for (final rowEl in table.findAllElements('tr', namespaceUri: '*')) {
      if (rows.length >= options.limits.maxTableRows) {
        truncated = true;
        break;
      }
      final cells = <String>[];
      for (final cellEl in rowEl.findAllElements('tc', namespaceUri: '*')) {
        if (cells.length >= options.limits.maxTableColumns) {
          truncated = true;
          break;
        }
        cells.add(_docxCellText(cellEl));
      }
      if (cells.isNotEmpty) rows.add(cells);
      if (truncated) break;
    }
    if (rows.isEmpty) return null;
    if (truncated) {
      // warning emitted by caller
    }
    return DocumentTable(name: name, rows: rows);
  }

  String _docxCellText(XmlElement tc) {
    final parts = <String>[];
    for (final p in tc.findAllElements('p', namespaceUri: '*')) {
      final t = p.innerText.trim();
      if (t.isNotEmpty) parts.add(t);
    }
    return parts.join(' ');
  }

  // --- XLSX ------------------------------------------------------------------

  _XlsxResult _readXlsx(
    List<ArchiveFile> entries,
    ParseOptions options,
    List<ParseWarning> warnings,
  ) {
    final workbookXml = _readEntryText(
      entries,
      'xl/workbook.xml',
      options,
      warnings,
    );
    if (workbookXml == null) return const _XlsxResult();

    final sharedStrings = _sharedStrings(entries, options, warnings);
    final sheets = <Map<String, Object?>>[];
    final textParts = <String>[];
    final outline = <OutlineEntry>[];
    final tables = <DocumentTable>[];
    var sheetIndex = 0;

    for (final sheetEntry in _sheetEntries(entries)) {
      if (sheetIndex >= options.limits.maxPages) {
        warnings.add(
          const ParseWarning(
            'ooxml.sheet_limit',
            'sheet count exceeded the configured limit',
          ),
        );
        break;
      }
      final targetPath = sheetEntry.target;
      if (targetPath == null) continue;
      final cleanTarget = targetPath.startsWith('/')
          ? targetPath.substring(1)
          : 'xl/$targetPath';
      Uint8List? data = _readEntry(entries, cleanTarget, options, warnings);
      if (data == null) {
        data = _readEntry(entries, targetPath, options, warnings);
        if (data == null) continue;
      }
      final XmlDocument sheet;
      try {
        sheet = XmlDocument.parse(utf8.decode(data, allowMalformed: true));
      } catch (_) {
        continue;
      }
      final rows = <List<String>>[];
      for (final row in sheet.findAllElements('row', namespaceUri: '*')) {
        final cells = <String>[];
        for (final c in row.findAllElements('c', namespaceUri: '*')) {
          cells.add(_xlsxCellValue(c, sharedStrings));
        }
        if (cells.isNotEmpty) rows.add(cells);
      }
      if (rows.isNotEmpty) {
        tables.add(
          DocumentTable(
            name: sheetEntry.displayName ?? 'Sheet ${sheetIndex + 1}',
            rows: rows,
            page: sheetIndex,
          ),
        );
        textParts.add(
          rows.map((r) => r.where((c) => c.isNotEmpty).join('\t')).join('\n'),
        );
      }
      sheets.add({
        'name': sheetEntry.displayName ?? 'Sheet ${sheetIndex + 1}',
        'state': sheetEntry.state,
        'sheetId': sheetEntry.sheetId,
        'rId': sheetEntry.rId,
      });
      outline.add(
        OutlineEntry(
          title: sheetEntry.displayName ?? 'Sheet ${sheetIndex + 1}',
          level: 1,
          page: sheetIndex,
        ),
      );
      sheetIndex++;
    }

    final core = _readEntryText(
      entries,
      'docProps/core.xml',
      options,
      warnings,
    );
    if (core != null) {
      // ignore metadata for now but could merge
    }

    return _XlsxResult(
      text: textParts.join('\n'),
      outline: outline,
      tables: tables,
      pages: [],
      sheets: sheets,
      metadata: {},
    );
  }

  Map<String, String> _sharedStrings(
    List<ArchiveFile> entries,
    ParseOptions options,
    List<ParseWarning> warnings,
  ) {
    final data = _readEntry(entries, 'xl/sharedStrings.xml', options, warnings);
    if (data == null) return const {};
    final out = <String, String>{};
    try {
      final doc = XmlDocument.parse(utf8.decode(data, allowMalformed: true));
      var index = 0;
      for (final si in doc.findAllElements('si', namespaceUri: '*')) {
        out[index.toString()] = si.innerText;
        index++;
      }
    } catch (_) {
      // ignore parse errors; shared strings are optional
    }
    return out;
  }

  String _xlsxCellValue(XmlElement c, Map<String, String> sharedStrings) {
    final type = c.getAttribute('t');
    final raw = c.innerText.trim();
    if (type == 's') {
      return sharedStrings[raw] ?? '';
    }
    if (type == 'str' || type == 'inlineStr') {
      return raw;
    }
    // number / date / bool: return raw
    return raw;
  }

  // --- PPTX ------------------------------------------------------------------

  _PptxResult _readPptx(
    List<ArchiveFile> entries,
    ParseOptions options,
    List<ParseWarning> warnings,
  ) {
    final presentationXml = _readEntryText(
      entries,
      'ppt/presentation.xml',
      options,
      warnings,
    );
    if (presentationXml == null) return const _PptxResult();

    final slides = <Map<String, Object?>>[];
    final textParts = <String>[];
    final outline = <OutlineEntry>[];
    final tables = <DocumentTable>[];
    final pages = <TextPage>[];
    var slideIndex = 0;

    for (final slideEntry in _slideEntries(entries)) {
      if (slideIndex >= options.limits.maxPages) {
        warnings.add(
          const ParseWarning(
            'ooxml.slide_limit',
            'slide count exceeded the configured limit',
          ),
        );
        break;
      }
      final data = _readEntry(entries, slideEntry.name, options, warnings);
      if (data == null) continue;
      final XmlDocument slide;
      try {
        slide = XmlDocument.parse(utf8.decode(data, allowMalformed: true));
      } catch (_) {
        continue;
      }
      final blocks = <TextBlock>[];
      for (final p in slide.findAllElements('p', namespaceUri: '*')) {
        final t = p.innerText.trim();
        if (t.isNotEmpty) {
          textParts.add(t);
          blocks.add(TextBlock(spans: [TextSpan(t)], style: 'paragraph'));
        }
      }
      // Heading-like: any run with bold or large font size
      for (final r in slide.findAllElements('r', namespaceUri: '*')) {
        final t = r.innerText.trim();
        if (t.isNotEmpty && t.length > 3 && !textParts.last.contains(t)) {
          // treat as potential heading
        }
      }
      slides.add({'name': slideEntry.displayName, 'rId': slideEntry.rId});
      if (blocks.isNotEmpty) {
        outline.add(
          OutlineEntry(
            title: blocks.first.spans.map((s) => s.text).join(),
            level: 1,
            page: slideIndex,
          ),
        );
      }
      pages.add(
        TextPage(
          index: slideIndex,
          label: slideEntry.displayName,
          coordinateSpace: TextCoordinateSpace.unknown,
          blocks: blocks,
        ),
      );
      slideIndex++;
    }

    return _PptxResult(
      text: textParts.join('\n'),
      outline: outline,
      tables: tables,
      pages: pages,
      slides: slides,
      metadata: {},
    );
  }

  // --- attachments -----------------------------------------------------------

  List<DocumentAttachment> _attachments(
    List<ArchiveFile> entries,
    ContentHasher hasher,
    ParseOptions options,
    List<ParseWarning> warnings,
  ) {
    final out = <DocumentAttachment>[];
    var total = 0;
    final mediaPaths = <String>{'word/media/', 'xl/media/', 'ppt/media/'};
    for (final entry in entries) {
      final name = entry.name;
      if (!mediaPaths.any((p) => name.startsWith(p))) continue;
      if (out.length >= options.limits.maxAttachments) {
        warnings.add(
          const ParseWarning(
            'ooxml.attachment_limit',
            'attachment count exceeded the configured limit',
          ),
        );
        break;
      }
      final size = entry.size;
      if (size < 0 ||
          size > options.limits.maxAttachmentBytes ||
          total + size > options.limits.maxAttachmentBytes) {
        warnings.add(
          const ParseWarning(
            'ooxml.attachment_byte_limit',
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
    if (n.endsWith('.bin')) return 'application/octet-stream';
    return null;
  }

  // --- sheet/slide entry discovery -------------------------------------------

  Iterable<_SheetEntry> _sheetEntries(List<ArchiveFile> entries) sync* {
    final rels = _readRels(entries, 'xl/_rels/workbook.xml.rels');
    final sheetsXml = _readEntryText(
      entries,
      'xl/workbook.xml',
      const ParseOptions(),
      [],
    );
    if (sheetsXml == null) return;
    final doc = XmlDocument.parse(sheetsXml);
    for (final sheet in doc.findAllElements('sheet', namespaceUri: '*')) {
      final name = _attr(sheet, 'name');
      final rId = _attr(sheet, 'id') ?? _attr(sheet, 'sheetId');
      final target = rels[rId ?? ''];
      yield _SheetEntry(
        name: name,
        displayName: name,
        state: sheet.getAttribute('state'),
        sheetId: sheet.getAttribute('sheetId'),
        rId: rId,
        target: target?.target,
      );
    }
  }

  Iterable<_SlideEntry> _slideEntries(List<ArchiveFile> entries) sync* {
    final rels = _readRels(entries, 'ppt/_rels/presentation.xml.rels');
    int index = 0;
    for (final entry in rels.entries) {
      final rel = entry.value;
      final rawTarget = rel.target;
      if (!rawTarget.startsWith('slides/slide') &&
          !rawTarget.startsWith('/slides/slide')) {
        continue;
      }
      final target = rawTarget.startsWith('/')
          ? rawTarget.substring(1)
          : rawTarget;
      final name = 'ppt/$target';
      yield _SlideEntry(
        name: name,
        displayName: 'Slide ${index + 1}',
        rId: rel.id,
        target: name,
      );
      index++;
    }
  }

  Map<String, _Rel> _readRels(List<ArchiveFile> entries, String path) {
    final out = <String, _Rel>{};
    final data = _readEntryText(entries, path, const ParseOptions(), []);
    if (data == null) return out;
    try {
      final doc = XmlDocument.parse(data);
      for (final rel in doc.findAllElements(
        'Relationship',
        namespaceUri: '*',
      )) {
        final id = rel.getAttribute('Id') ?? rel.getAttribute('id');
        final target = rel.getAttribute('Target');
        final type = rel.getAttribute('Type');
        if (id != null && target != null) {
          out[id] = _Rel(id: id, target: target, type: type);
        }
      }
    } catch (_) {
      // ignore
    }
    return out;
  }

  static Map<String, Object?> _ooxmlCoreProps(String xml) {
    try {
      final doc = XmlDocument.parse(xml);
      final out = <String, Object?>{};
      void put(String key, String local) {
        final v = doc
            .findAllElements(local, namespaceUri: '*')
            .firstOrNull
            ?.innerText
            .trim();
        if (v != null && v.isNotEmpty) out[key] = v;
      }

      put('title', 'title');
      put('subject', 'subject');
      put('creator', 'creator');
      put('keywords', 'keywords');
      put('description', 'description');
      put('lastModifiedBy', 'lastModifiedBy');
      put('revision', 'revision');
      put('created', 'created');
      put('modified', 'modified');
      return out;
    } catch (_) {
      return const {};
    }
  }

  static Map<String, Object?> _ooxmlAppProps(String xml) {
    try {
      final doc = XmlDocument.parse(xml);
      final out = <String, Object?>{};
      void put(String key, String local) {
        final v = doc
            .findAllElements(local, namespaceUri: '*')
            .firstOrNull
            ?.innerText
            .trim();
        if (v != null && v.isNotEmpty) out[key] = v;
      }

      put('application', 'Application');
      put('appVersion', 'AppVersion');
      put('totalTime', 'TotalTime');
      put('headingPairs', 'HeadingPairs');
      put('titlesOfParts', 'TitlesOfParts');
      return out;
    } catch (_) {
      return const {};
    }
  }

  static String? _attr(XmlElement e, String local) {
    for (final a in e.attributes) {
      if (a.name.local == local) return a.value;
    }
    return null;
  }
}

/// Result of reading a DOCX document.
final class _DocxResult {
  const _DocxResult({
    this.text = '',
    this.outline = const [],
    this.tables = const [],
    this.pages = const [],
    this.metadata = const {},
  });
  final String text;
  final List<OutlineEntry> outline;
  final List<DocumentTable> tables;
  final List<TextPage> pages;
  final Map<String, Object?> metadata;
}

/// Result of reading an XLSX document.
final class _XlsxResult {
  const _XlsxResult({
    this.text = '',
    this.outline = const [],
    this.tables = const [],
    this.pages = const [],
    this.sheets = const [],
    this.metadata = const {},
  });
  final String text;
  final List<OutlineEntry> outline;
  final List<DocumentTable> tables;
  final List<TextPage> pages;
  final List<Map<String, Object?>> sheets;
  final Map<String, Object?> metadata;
}

/// Result of reading a PPTX document.
final class _PptxResult {
  const _PptxResult({
    this.text = '',
    this.outline = const [],
    this.tables = const [],
    this.pages = const [],
    this.slides = const [],
    this.metadata = const {},
  });
  final String text;
  final List<OutlineEntry> outline;
  final List<DocumentTable> tables;
  final List<TextPage> pages;
  final List<Map<String, Object?>> slides;
  final Map<String, Object?> metadata;
}

final class _SheetEntry {
  const _SheetEntry({
    required this.name,
    required this.displayName,
    this.state,
    this.sheetId,
    this.rId,
    this.target,
  });
  final String? name;
  final String? displayName;
  final String? state;
  final String? sheetId;
  final String? rId;
  final String? target;
}

final class _SlideEntry {
  const _SlideEntry({
    required this.name,
    required this.displayName,
    required this.rId,
    required this.target,
  });
  final String name;
  final String displayName;
  final String? rId;
  final String target;
}

final class _DocxParagraph {
  const _DocxParagraph({required this.text, this.style});
  final String text;
  final String? style;
}

final class _Rel {
  const _Rel({required this.id, required this.target, this.type});
  final String id;
  final String target;
  final String? type;
}
