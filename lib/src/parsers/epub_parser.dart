import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:swissarmyknife/swissarmyknife.dart';
import 'package:xml/xml.dart';

import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_exception.dart';
import '../core/parse_options.dart';
import '../core/parse_result.dart';
import '../core/structured_artifacts.dart';
import '../core/zip_container.dart';
import 'html_parser.dart';

/// Parser for EPUB 2/3 publications (OCF + OPF + XHTML spine).
///
/// Recognition requires a ZIP container that contains
/// `META-INF/container.xml`, so generic ZIP archives are never misreported.
/// Extraction follows the OCF container to the OPF package document, reads
/// Dublin Core metadata, resolves the spine order, extracts chapter text and
/// headings from XHTML, and surfaces manifest media as attachments. DRM,
/// encryption, and scripted content are reported but never decrypted or
/// executed. Encryption and rights-management payloads are not bypassed.
final class EpubParser
    implements
        DocumentParser,
        OptionAwareDocumentParser,
        HintAwareDocumentParser {
  const EpubParser();

  @override
  DocumentFormat get format => DocumentFormat.epub;

  String get parserVersion => parserImplementationVersion;

  @override
  bool canParse(Uint8List bytes) {
    final names = zipEntryNames(bytes);
    if (names == null) return false;
    return names.contains('meta-inf/container.xml') &&
        names.contains('mimetype');
  }

  @override
  bool canParseWithHints(Uint8List bytes, DocumentHints hints) {
    if (canParse(bytes)) return true;
    if (hints.extension != 'epub') return false;
    final names = zipEntryNames(bytes);
    return names != null && names.contains('meta-inf/container.xml');
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
      throw const MalformedDocumentException('corrupt EPUB (ZIP) container');
    }

    final warnings = <ParseWarning>[];
    final entries = _boundedEntries(archive, options, warnings);
    final byName = <String, ArchiveFile>{
      for (final file in entries) file.name: file,
    };

    if (byName.containsKey('META-INF/encryption.xml')) {
      warnings.add(
        const ParseWarning(
          'epub.encrypted_resources',
          'EPUB contains META-INF/encryption.xml; encrypted resources are '
              'not decrypted',
        ),
      );
    }
    if (byName.containsKey('META-INF/rights.xml')) {
      warnings.add(
        const ParseWarning(
          'epub.drm',
          'EPUB contains META-INF/rights.xml; rights management is not '
              'bypassed',
        ),
      );
    }

    final containerXml = _readEntryText(
      byName['META-INF/container.xml'],
      options,
      warnings,
      'META-INF/container.xml',
    );
    if (containerXml == null) {
      throw const MalformedDocumentException(
        'EPUB META-INF/container.xml is missing or unreadable',
      );
    }
    final opfPath = _findPackagePath(containerXml);
    if (opfPath == null) {
      throw const MalformedDocumentException(
        'EPUB container does not declare a package document',
      );
    }
    final opfBytes = _readEntry(byName[opfPath], options, warnings, opfPath);
    if (opfBytes == null) {
      throw const MalformedDocumentException(
        'EPUB package document is missing or unreadable',
      );
    }

    final XmlDocument opf;
    try {
      opf = XmlDocument.parse(utf8.decode(opfBytes, allowMalformed: true));
    } on XmlException {
      throw const MalformedDocumentException('invalid EPUB package document');
    }

    final metadata = <String, Object?>{};
    final manifest = <String, _ManifestItem>{};
    final spine = <String>[];
    final packageVersion = _attr(opf.rootElement, 'version');
    if (packageVersion != null) metadata['epubVersion'] = packageVersion;

    final metadataElement = _firstElement(opf, 'metadata');
    if (metadataElement != null) {
      _readDublinCore(metadataElement, metadata);
    }

    for (final item in _elements(opf, 'item')) {
      final id = _attr(item, 'id');
      final href = _attr(item, 'href');
      if (id == null || href == null || href.isEmpty) continue;
      manifest[id] = _ManifestItem(
        id: id,
        href: href,
        path: _resolvePath(opfPath, href),
        mediaType: _attr(item, 'media-type'),
        properties: _attr(item, 'properties') ?? '',
      );
    }
    for (final itemRef in _elements(opf, 'itemref')) {
      final idref = _attr(itemRef, 'idref');
      if (idref == null) continue;
      final linear = _attr(itemRef, 'linear');
      if (linear != null && linear.toLowerCase() == 'no') continue;
      if (manifest.containsKey(idref)) spine.add(idref);
    }

    metadata['packagePath'] = opfPath;
    metadata['spineCount'] = spine.length;
    metadata['manifestCount'] = manifest.length;
    metadata['encrypted'] = byName.containsKey('META-INF/encryption.xml');

    final chapterText = StringBuffer();
    final chapterOutline = <OutlineEntry>[];
    final pages = <TextPage>[];
    final tables = <DocumentTable>[];
    var textTruncated = false;
    var chapterIndex = 0;

    for (final idref in spine) {
      if (chapterIndex >= options.limits.maxPages) {
        warnings.add(
          ParseWarning(
            'epub.page_limit',
            'chapter count exceeded ${options.limits.maxPages}',
          ),
        );
        break;
      }
      final item = manifest[idref];
      if (item == null) continue;
      final chapterBytes = _readEntry(
        byName[item.path],
        options,
        warnings,
        item.path,
      );
      if (chapterBytes == null) {
        warnings.add(
          ParseWarning(
            'epub.chapter_missing',
            'spine item ${item.path} is missing from the container',
          ),
        );
        continue;
      }
      final chapter = _extractChapter(
        chapterBytes,
        item.path,
        chapterIndex,
        options,
        hasher,
        warnings,
      );
      final chapterTitle = chapter.title ?? item.path.split('/').last;
      if (chapter.text.isNotBlank) {
        if (!textTruncated) {
          final block = '${chapter.text}\n\n';
          final remaining =
              options.limits.maxTextCharacters - chapterText.length;
          if (block.length > remaining) {
            if (remaining > 0) {
              chapterText.write(block.substring(0, remaining));
            }
            textTruncated = true;
          } else {
            chapterText.write(block);
          }
        }
      }
      chapterOutline.addAll(chapter.headings);
      if (chapter.headings.isEmpty && chapter.text.isNotBlank) {
        chapterOutline.add(OutlineEntry(title: chapterTitle, level: 1));
      }
      for (final table in chapter.tables) {
        tables.add(
          DocumentTable(
            name: table.name,
            caption: table.caption,
            rows: table.rows,
            page: chapterIndex,
          ),
        );
      }
      final blocks = <TextBlock>[
        TextBlock(spans: [TextSpan(chapterTitle)], style: 'heading', level: 1),
        for (final heading in chapter.headings)
          TextBlock(
            spans: [TextSpan(heading.title)],
            style: 'heading',
            level: heading.level,
          ),
        for (final line in chapter.text.split('\n'))
          if (line.trim().isNotEmpty)
            TextBlock(spans: [TextSpan(line.trim())], style: 'paragraph'),
      ];
      pages.add(
        TextPage(index: chapterIndex, label: chapterTitle, blocks: blocks),
      );
      chapterIndex++;
    }

    if (textTruncated) {
      warnings.add(
        ParseWarning(
          'epub.text_truncated',
          'text exceeded ${options.limits.maxTextCharacters} characters',
        ),
      );
    }

    // Prefer the publication's navigation document/NCX for the outline; fall
    // back to headings harvested from the spine.
    final toc = _readToc(byName, manifest, options, warnings);
    final outline = toc.isNotEmpty ? toc : chapterOutline;
    if (toc.isNotEmpty) metadata['tocSource'] = 'navigation';

    final attachments = _attachments(
      byName,
      manifest,
      spine,
      hasher,
      options,
      warnings,
    );
    if (attachments.isNotEmpty) {
      metadata['attachmentCount'] = attachments.length;
    }

    // Cover image.
    final coverId = _coverId(metadataElement);
    String? coverPath;
    if (coverId != null && manifest.containsKey(coverId)) {
      coverPath = manifest[coverId]!.path;
    } else {
      for (final item in manifest.values) {
        if (item.properties.split(' ').contains('cover-image')) {
          coverPath = item.path;
          break;
        }
      }
    }
    if (coverPath != null) metadata['coverImage'] = coverPath;

    final scripted = manifest.values.any(
      (item) =>
          item.mediaType == 'application/javascript' ||
          item.properties.split(' ').contains('scripted'),
    );
    if (scripted) {
      warnings.add(
        const ParseWarning(
          'epub.scripted_content',
          'EPUB declares scripted content; scripts are not executed',
        ),
      );
    }

    return ParseResult(
      documentId: digest.sha256,
      digest: digest,
      format: format,
      byteLength: bytes.length,
      metadata: metadata,
      text: chapterText.toString().trimRight().isBlank
          ? null
          : chapterText.toString().trimRight(),
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

  // --- container / OPF ------------------------------------------------------

  static String? _findPackagePath(String containerXml) {
    try {
      final container = XmlDocument.parse(containerXml);
      for (final rootfile in _elements(container, 'rootfile')) {
        final path = _attr(rootfile, 'full-path');
        if (path != null && path.isNotEmpty) return _cleanPath(path);
      }
    } on XmlException {
      return null;
    }
    return null;
  }

  static void _readDublinCore(
    XmlElement metadataElement,
    Map<String, Object?> metadata,
  ) {
    final titles = <String>[];
    final creators = <String>[];
    final languages = <String>[];
    final identifiers = <String>[];
    final subjects = <String>[];
    final dates = <String>[];

    for (final element in metadataElement.descendants.whereType<XmlElement>()) {
      final local = element.name.local.toLowerCase();
      final value = element.innerText.trim();
      switch (local) {
        case 'title':
          if (value.isNotEmpty) titles.add(value);
        case 'creator':
          if (value.isNotEmpty) creators.add(value);
        case 'language':
          if (value.isNotEmpty) languages.add(value);
        case 'identifier':
          if (value.isNotEmpty) identifiers.add(value);
        case 'subject':
          if (value.isNotEmpty) subjects.add(value);
        case 'date':
          if (value.isNotEmpty) dates.add(value);
        case 'publisher':
          if (value.isNotEmpty) metadata['publisher'] = value;
        case 'description':
          if (value.isNotEmpty) metadata['description'] = value.truncate(65536);
        case 'rights':
          if (value.isNotEmpty) metadata['rights'] = value;
        case 'meta':
          final name = _attr(element, 'name');
          final content = _attr(element, 'content') ?? value;
          if (name != null && name.isNotEmpty && content.isNotEmpty) {
            metadata['meta.$name'] = content;
          }
      }
    }

    if (titles.isNotEmpty) {
      metadata['title'] = titles.first;
      if (titles.length > 1) metadata['titles'] = titles;
    }
    if (creators.isNotEmpty) {
      metadata['creators'] = creators;
      metadata['creator'] = creators.first;
    }
    if (languages.isNotEmpty) {
      metadata['languages'] = languages;
      metadata['language'] = languages.first;
    }
    if (identifiers.isNotEmpty) {
      metadata['identifiers'] = identifiers;
      metadata['identifier'] = identifiers.first;
    }
    if (subjects.isNotEmpty) metadata['subjects'] = subjects;
    if (dates.isNotEmpty) metadata['dates'] = dates;
  }

  static String? _coverId(XmlElement? metadataElement) {
    if (metadataElement == null) return null;
    for (final element in metadataElement.descendants.whereType<XmlElement>()) {
      if (element.name.local.toLowerCase() != 'meta') continue;
      if ((_attr(element, 'name') ?? '').toLowerCase() == 'cover') {
        return _attr(element, 'content');
      }
    }
    return null;
  }

  static List<OutlineEntry> _readToc(
    Map<String, ArchiveFile> byName,
    Map<String, _ManifestItem> manifest,
    ParseOptions options,
    List<ParseWarning> warnings,
  ) {
    // EPUB 2 NCX.
    for (final item in manifest.values) {
      if (item.mediaType == 'application/x-dtbncx+xml' ||
          item.path.toLowerCase().endsWith('.ncx')) {
        final bytes = _readEntry(
          byName[item.path],
          options,
          warnings,
          item.path,
        );
        if (bytes == null) continue;
        final entries = _parseNcx(utf8.decode(bytes, allowMalformed: true));
        if (entries.isNotEmpty) return entries;
      }
    }
    // EPUB 3 navigation document.
    for (final item in manifest.values) {
      if (!item.properties.split(' ').contains('nav')) continue;
      final bytes = _readEntry(byName[item.path], options, warnings, item.path);
      if (bytes == null) continue;
      final entries = _parseNav(utf8.decode(bytes, allowMalformed: true));
      if (entries.isNotEmpty) return entries;
    }
    return const [];
  }

  static List<OutlineEntry> _parseNcx(String source) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(source);
    } on XmlException {
      return const [];
    }
    final navMap = _firstElement(doc, 'navMap');
    if (navMap == null) return const [];
    final entries = <OutlineEntry>[];
    void walk(XmlElement parent, int level) {
      if (level > 8 || entries.length >= 4096) return;
      for (final child in parent.children.whereType<XmlElement>()) {
        if (child.name.local.toLowerCase() != 'navpoint') continue;
        final label = _firstElement(child, 'navLabel');
        final text = label == null
            ? ''
            : _firstElement(label, 'text')?.innerText.trim() ?? '';
        if (text.isNotEmpty) {
          entries.add(OutlineEntry(title: text, level: level));
        }
        walk(child, level + 1);
      }
    }

    walk(navMap, 1);
    return entries;
  }

  static List<OutlineEntry> _parseNav(String source) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(source);
    } on XmlException {
      return const [];
    }

    XmlElement? toc;
    for (final nav in _elements(doc, 'nav')) {
      final type = _attr(nav, 'type');
      if (type == 'toc') {
        toc = nav;
        break;
      }
      toc ??= nav;
    }
    if (toc == null) return const [];

    final entries = <OutlineEntry>[];
    void walk(XmlElement list, int level) {
      if (level > 8 || entries.length >= 4096) return;
      for (final li in list.children.whereType<XmlElement>()) {
        if (li.name.local.toLowerCase() != 'li') continue;
        XmlElement? link;
        for (final child in li.children.whereType<XmlElement>()) {
          if (child.name.local.toLowerCase() == 'a') {
            link = child;
            break;
          }
        }
        final text = link?.innerText.trim() ?? '';
        if (text.isNotEmpty) {
          entries.add(OutlineEntry(title: text, level: level));
        }
        for (final nested in li.children.whereType<XmlElement>()) {
          if (nested.name.local.toLowerCase() == 'ol') {
            walk(nested, level + 1);
          }
        }
      }
    }

    for (final list in toc.descendants.whereType<XmlElement>()) {
      if (list.name.local.toLowerCase() == 'ol') {
        walk(list, 1);
        if (entries.isNotEmpty) break;
      }
    }
    return entries;
  }

  // --- chapters -------------------------------------------------------------

  static _Chapter _extractChapter(
    Uint8List chapterBytes,
    String path,
    int pageIndex,
    ParseOptions options,
    ContentHasher hasher,
    List<ParseWarning> warnings,
  ) {
    final source = utf8.decode(chapterBytes, allowMalformed: true);
    XmlDocument doc;
    try {
      doc = XmlDocument.parse(source);
    } on XmlException {
      return _extractChapterWithHtml(
        chapterBytes,
        path,
        pageIndex,
        options,
        hasher,
        warnings,
      );
    }

    final body = _firstElement(doc, 'body') ?? doc.rootElement;
    final result = _Chapter();
    final titleElement = _firstElement(doc, 'title');
    if (titleElement != null) {
      final title = _normalizeText(titleElement.innerText);
      if (title.isNotBlank) result.title = title;
    }

    final buffer = _TextBuilder();
    final stack = <(XmlNode, bool)>[(body, false)];
    var steps = 0;
    while (stack.isNotEmpty && steps < 200000) {
      steps++;
      final (node, closing) = stack.removeLast();
      if (closing) {
        buffer.newline();
        continue;
      }
      if (node is XmlText) {
        buffer.text(node.value);
        continue;
      }
      if (node is! XmlElement) continue;

      final local = node.name.local.toLowerCase();
      if (local == 'head' ||
          local == 'script' ||
          local == 'style' ||
          local == 'noscript') {
        continue;
      }
      if (local == 'br') {
        buffer.newline();
        continue;
      }
      if (local == 'img') {
        final src = _attr(node, 'src');
        if (src != null && src.isNotBlank) {
          result.images.add(src);
        }
        final alt = _attr(node, 'alt');
        if (alt != null && alt.isNotBlank) buffer.text(alt);
        continue;
      }
      if (local == 'a') {
        final href = _attr(node, 'href');
        if (href != null && href.isNotBlank) {
          result.links.add({'href': href, 'text': node.innerText.trim()});
        }
      }
      if (local == 'table') {
        final table = _extractTable(node, pageIndex);
        if (table != null) {
          result.tables.add(table);
          for (final row in table.rows) {
            buffer.text(row.join(' | '));
            buffer.newline();
          }
        }
        continue;
      }
      if (local.length == 2 &&
          local.startsWith('h') &&
          local.codeUnitAt(1) >= 0x31 &&
          local.codeUnitAt(1) <= 0x36) {
        final level = local.codeUnitAt(1) - 0x30;
        final title = _normalizeText(node.innerText);
        if (title.isNotBlank) {
          result.headings.add(OutlineEntry(title: title, level: level));
          buffer.text(title);
          buffer.newline();
        }
        continue;
      }

      final isBlock = _blockElements.contains(local);
      if (isBlock) buffer.newline();
      stack.add((node, true));
      final children = node.children;
      for (var i = children.length - 1; i >= 0; i--) {
        stack.add((children[i], false));
      }
    }

    result.text = _normalizeBlockText(buffer.toString());
    return result;
  }

  static _Chapter _extractChapterWithHtml(
    Uint8List chapterBytes,
    String path,
    int pageIndex,
    ParseOptions options,
    ContentHasher hasher,
    List<ParseWarning> warnings,
  ) {
    warnings.add(
      ParseWarning(
        'epub.chapter_fallback',
        '$path is not well-formed XHTML; parsed with the tolerant HTML reader',
      ),
    );
    try {
      final parsed = const HtmlParser().parseWithOptions(
        chapterBytes,
        hasher: hasher,
        options: options,
      );
      return _Chapter(
        text: parsed.text ?? '',
        headings: parsed.outline,
        tables: parsed.tables,
        title: parsed.metadata['title'] as String?,
      );
    } on ParseException catch (error) {
      warnings.add(
        ParseWarning(
          'epub.chapter_parse_failed',
          '$path could not be parsed: ${error.message}',
        ),
      );
      return _Chapter();
    }
  }

  // --- attachments ----------------------------------------------------------

  static List<DocumentAttachment> _attachments(
    Map<String, ArchiveFile> byName,
    Map<String, _ManifestItem> manifest,
    List<String> spine,
    ContentHasher hasher,
    ParseOptions options,
    List<ParseWarning> warnings,
  ) {
    if (!options.includeAttachments) return const [];
    final spinePaths = {for (final id in spine) manifest[id]?.path};
    final attachments = <DocumentAttachment>[];
    var totalBytes = 0;
    var skipped = false;

    for (final item in manifest.values) {
      final mediaType = item.mediaType ?? '';
      final isMedia =
          mediaType.startsWith('image/') ||
          mediaType.startsWith('audio/') ||
          mediaType.startsWith('video/') ||
          mediaType.startsWith('font/') ||
          mediaType == 'application/pdf' ||
          mediaType == 'application/font-sfnt' ||
          mediaType == 'application/vnd.ms-opentype';
      if (!isMedia) continue;
      if (spinePaths.contains(item.path)) continue;
      if (attachments.length >= options.limits.maxAttachments) {
        skipped = true;
        break;
      }
      final file = byName[item.path];
      final size = file?.size;
      if (size != null &&
          totalBytes + size > options.limits.maxAttachmentBytes) {
        skipped = true;
        continue;
      }
      Uint8List? bytes;
      if (file != null) {
        bytes = _readEntry(file, options, warnings, item.path);
      }
      if (bytes == null) {
        attachments.add(
          DocumentAttachment(
            name: item.href,
            mediaType: mediaType.isEmpty ? null : mediaType,
            size: size,
            relationship: 'manifest',
          ),
        );
        continue;
      }
      totalBytes += bytes.length;
      attachments.add(
        DocumentAttachment(
          name: item.href,
          mediaType: mediaType.isEmpty ? null : mediaType,
          size: bytes.length,
          digest: hasher.digestFor(bytes),
          bytes: options.includeAttachmentBytes ? bytes : null,
          relationship: 'manifest',
        ),
      );
    }
    if (skipped) {
      warnings.add(
        ParseWarning(
          'epub.attachment_limit',
          'attachment count or byte budget exceeded '
              '(${options.limits.maxAttachments} items, '
              '${options.limits.maxAttachmentBytes} bytes)',
        ),
      );
    }
    return attachments;
  }

  // --- helpers --------------------------------------------------------------

  static const Set<String> _blockElements = {
    'address',
    'article',
    'aside',
    'blockquote',
    'div',
    'dl',
    'dd',
    'dt',
    'figcaption',
    'figure',
    'footer',
    'header',
    'hr',
    'li',
    'main',
    'nav',
    'ol',
    'p',
    'pre',
    'section',
    'tbody',
    'thead',
    'tfoot',
    'tr',
    'ul',
  };

  static String _normalizeText(String raw) =>
      raw.replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _normalizeBlockText(String raw) {
    final lines = <String>[];
    for (final line in raw.split('\n')) {
      final trimmed = _normalizeText(line);
      if (trimmed.isNotEmpty) lines.add(trimmed);
    }
    return lines.join('\n');
  }

  static DocumentTable? _extractTable(XmlElement table, int pageIndex) {
    final rows = <List<String>>[];
    for (final row in table.descendants.whereType<XmlElement>()) {
      if (row.name.local.toLowerCase() != 'tr') continue;
      final cells = <String>[];
      for (final cell in row.children.whereType<XmlElement>()) {
        final local = cell.name.local.toLowerCase();
        if (local == 'td' || local == 'th') {
          cells.add(_normalizeText(cell.innerText));
        }
      }
      if (cells.isNotEmpty) rows.add(cells);
    }
    if (rows.isEmpty) return null;
    return DocumentTable(rows: rows, page: pageIndex);
  }

  static Iterable<XmlElement> _elements(XmlNode node, String local) =>
      node.descendants.whereType<XmlElement>().where(
        (element) => element.name.local.toLowerCase() == local.toLowerCase(),
      );

  static XmlElement? _firstElement(XmlNode node, String local) {
    for (final element in node.descendants.whereType<XmlElement>()) {
      if (element.name.local.toLowerCase() == local.toLowerCase()) {
        return element;
      }
    }
    return null;
  }

  static String? _attr(XmlElement element, String local) {
    for (final attribute in element.attributes) {
      if (attribute.name.local.toLowerCase() == local.toLowerCase()) {
        return attribute.value;
      }
    }
    return null;
  }

  static String _cleanPath(String path) {
    final segments = <String>[];
    for (final segment in path.replaceAll('\\', '/').split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (segments.isNotEmpty) segments.removeLast();
        continue;
      }
      segments.add(segment);
    }
    return segments.join('/');
  }

  static String _resolvePath(String baseFile, String href) {
    var clean = href.split('#').first.split('?').first;
    try {
      clean = Uri.decodeFull(clean);
    } on ArgumentError {
      // Keep the raw path when percent-decoding is malformed.
    }
    final base = baseFile.split('/')..removeLast();
    final segments = <String>[...base];
    for (final segment in clean.replaceAll('\\', '/').split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (segments.isNotEmpty) segments.removeLast();
        continue;
      }
      segments.add(segment);
    }
    return segments.join('/');
  }

  static String? _readEntryText(
    ArchiveFile? file,
    ParseOptions options,
    List<ParseWarning> warnings,
    String name,
  ) {
    final bytes = _readEntry(file, options, warnings, name);
    if (bytes == null) return null;
    return utf8.decode(bytes, allowMalformed: true);
  }

  static Uint8List? _readEntry(
    ArchiveFile? file,
    ParseOptions options,
    List<ParseWarning> warnings,
    String name,
  ) {
    if (file == null) return null;
    if (file.size > options.limits.maxDecompressedEntryBytes) {
      warnings.add(
        ParseWarning(
          'epub.entry_too_large',
          '$name exceeded the per-entry decompression limit',
        ),
      );
      return null;
    }
    try {
      return Uint8List.fromList(file.content as List<int>);
    } catch (_) {
      warnings.add(
        ParseWarning(
          'epub.entry_unreadable',
          '$name could not be decompressed',
        ),
      );
      return null;
    }
  }

  static List<ArchiveFile> _boundedEntries(
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
          'epub.decompression_limit',
          'EPUB container exceeded the configured decompression limits',
        ),
      );
    }
    return out;
  }
}

final class _TextBuilder {
  final StringBuffer _buffer = StringBuffer();
  int _last = 0;

  void text(String raw) {
    if (raw.isEmpty) return;
    final text = raw.replaceAll(RegExp(r'[\t\r\n ]+'), ' ');
    if (text.isEmpty) return;
    final first = text.codeUnitAt(0);
    if (_last != 0 && _isWordCode(_last) && _isWordCode(first)) {
      _buffer.write(' ');
    }
    _buffer.write(text);
    _last = text.codeUnitAt(text.length - 1);
  }

  void newline() {
    if (_last == 0x0A) return;
    _buffer.write('\n');
    _last = 0x0A;
  }

  @override
  String toString() => _buffer.toString();
}

bool _isWordCode(int code) =>
    (code >= 0x30 && code <= 0x39) ||
    (code >= 0x41 && code <= 0x5A) ||
    (code >= 0x61 && code <= 0x7A) ||
    code > 0x7F;

final class _ManifestItem {
  const _ManifestItem({
    required this.id,
    required this.href,
    required this.path,
    required this.mediaType,
    required this.properties,
  });

  final String id;
  final String href;
  final String path;
  final String? mediaType;
  final String properties;
}

final class _Chapter {
  _Chapter({
    this.title,
    this.text = '',
    List<OutlineEntry>? headings,
    List<DocumentTable>? tables,
    List<Map<String, String>>? links,
    List<String>? images,
  }) : headings = headings ?? [],
       tables = tables ?? [],
       links = links ?? [],
       images = images ?? [];

  String? title;
  String text;
  final List<OutlineEntry> headings;
  final List<DocumentTable> tables;
  final List<Map<String, String>> links;
  final List<String> images;
}
