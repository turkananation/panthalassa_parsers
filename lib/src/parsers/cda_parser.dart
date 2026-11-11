import 'dart:convert';
import 'dart:typed_data';

import 'package:swissarmyknife/swissarmyknife.dart';
import 'package:xml/xml.dart';

import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_options.dart';
import '../core/parse_result.dart';
import '../core/structured_artifacts.dart';
import 'xml_support.dart';

/// Parser for HL7 v3 CDA (Clinical Document Architecture) R2 documents,
/// recognised by the `ClinicalDocument` root in the HL7 v3 namespace
/// (`urn:hl7-org:v3`).
///
/// Extraction covers document header metadata (id, type, confidentiality,
/// language, authors, custodian, patient, encounter), the structured-body
/// section tree (titles, narrative text, nested sections, tables), and
/// inline `observationMedia` attachments. Narrative text is read from the
/// human-readable `<text>` elements; structured `<entry>` content is not
/// interpreted as clinical assertions.
final class CdaParser implements DocumentParser, OptionAwareDocumentParser {
  const CdaParser();

  static const _v3Namespace = 'urn:hl7-org:v3';
  static const _maxSections = 10000;
  static const _maxTables = 512;

  @override
  DocumentFormat get format => DocumentFormat.cda;

  String get parserVersion => parserImplementationVersion;

  @override
  bool canParse(Uint8List bytes) {
    final prefix = XmlSupport.peek(bytes, 4096);
    if (prefix == null || !XmlSupport.looksXml(prefix)) return false;
    if (XmlSupport.firstElementName(prefix) != 'ClinicalDocument') return false;
    return prefix.contains(_v3Namespace);
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
    final doc = XmlSupport.parse(bytes);
    final root = doc.rootElement;
    final warnings = <ParseWarning>[];
    final metadata = <String, Object?>{};

    final title = _childText(root, 'title');
    if (title.isNotBlank) metadata['title'] = title;

    final id = _child(root, 'id');
    if (id != null) {
      metadata['documentId'] = _idString(id);
      final rootAttr = id.getAttribute('root');
      final extension = id.getAttribute('extension');
      if (rootAttr != null) metadata['documentIdRoot'] = rootAttr;
      if (extension != null) metadata['documentIdExtension'] = extension;
    }
    final setId = _child(root, 'setId');
    if (setId != null) metadata['setId'] = _idString(setId);
    final version = _childText(root, 'versionNumber');
    if (version.isNotBlank) metadata['versionNumber'] = version;

    final code = _child(root, 'code');
    if (code != null) {
      metadata['documentTypeCode'] = code.getAttribute('code');
      metadata['documentType'] = code.getAttribute('displayName');
      metadata['documentTypeSystem'] = code.getAttribute('codeSystem');
    }
    final effectiveTime = _child(root, 'effectiveTime');
    if (effectiveTime != null) {
      metadata['effectiveTime'] = _timeValue(effectiveTime);
    }
    final confidentiality = _child(root, 'confidentialityCode');
    if (confidentiality != null) {
      metadata['confidentialityCode'] = confidentiality.getAttribute('code');
      metadata['confidentiality'] = confidentiality.getAttribute('displayName');
    }
    final language = _childText(root, 'languageCode');
    if (language.isNotBlank) metadata['language'] = language;
    final realm = _childText(root, 'realmCode');
    if (realm.isNotBlank) metadata['realmCode'] = realm;

    final templateIds = <String>[];
    for (final template in root.findElements('templateId')) {
      final value = template.getAttribute('root');
      if (value != null && value.isNotEmpty) templateIds.add(value);
      if (templateIds.length >= 256) break;
    }
    if (templateIds.isNotEmpty) metadata['templateIds'] = templateIds;

    _readRecordTarget(root, metadata);
    _readAuthors(root, metadata);
    _readCustodian(root, metadata);
    _readDocumentation(root, metadata);
    _readEncounter(root, metadata);

    final outline = <OutlineEntry>[];
    final pages = <TextPage>[];
    final tables = <DocumentTable>[];
    final textBuffer = StringBuffer();
    var textTruncated = false;

    void appendText(String value) {
      if (value.isBlank || textTruncated) return;
      final remaining = options.limits.maxTextCharacters - textBuffer.length;
      if (remaining <= 0) {
        textTruncated = true;
        return;
      }
      final block = '$value\n';
      if (block.length > remaining) {
        textBuffer.write(block.substring(0, remaining));
        textTruncated = true;
      } else {
        textBuffer.write(block);
      }
    }

    if (title.isNotBlank) {
      outline.add(OutlineEntry(title: title, level: 1));
      appendText(title);
    }

    var sectionIndex = 0;
    var pageIndex = 0;
    var tableCount = 0;
    void walkSections(XmlElement parent, int depth) {
      for (final child in parent.childElements) {
        if (child.name.local == 'component') {
          walkSections(child, depth);
          continue;
        }
        if (child.name.local != 'section') continue;
        if (sectionIndex >= _maxSections) {
          warnings.add(
            const ParseWarning(
              'cda.section_limit',
              'section count exceeded $_maxSections',
            ),
          );
          return;
        }
        sectionIndex++;
        final sectionTitle = _childText(child, 'title');
        final level = (title.isNotBlank ? depth + 2 : depth + 1).clamp(1, 6);
        if (sectionTitle.isNotBlank) {
          outline.add(OutlineEntry(title: sectionTitle, level: level));
          appendText(sectionTitle);
        }

        final narrative = <String>[];
        for (final textElement in child.childElements) {
          if (textElement.name.local != 'text') continue;
          narrative.addAll(_narrativeLines(textElement));
          if (narrative.length >= options.limits.maxSegments) break;
          if (tableCount < _maxTables && options.includeTables) {
            for (final table
                in textElement.descendants.whereType<XmlElement>()) {
              if (table.name.local != 'table') continue;
              if (tableCount >= _maxTables) break;
              final parsed = _parseTable(table);
              if (parsed != null && parsed.isNotEmpty) {
                tables.add(
                  DocumentTable(
                    name: sectionTitle.isBlank ? null : sectionTitle,
                    rows: parsed,
                    page: pageIndex,
                  ),
                );
                tableCount++;
              }
            }
          }
        }
        for (final line in narrative) {
          appendText(line);
        }
        if (narrative.isNotEmpty || sectionTitle.isNotBlank) {
          pages.add(
            TextPage(
              index: pageIndex,
              label: sectionTitle.isBlank ? null : sectionTitle,
              blocks: [
                if (sectionTitle.isNotBlank)
                  TextBlock(
                    spans: [TextSpan(sectionTitle)],
                    style: 'heading',
                    level: level,
                  ),
                for (final line in narrative.take(20000))
                  TextBlock(spans: [TextSpan(line)], style: 'paragraph'),
              ],
            ),
          );
          pageIndex++;
        }

        // Nested sections live under <component><section>.
        for (final component in child.childElements) {
          if (component.name.local == 'component') {
            walkSections(component, depth + 1);
          }
        }
      }
    }

    final body = root.findAllElements('structuredBody').firstOrNull;
    if (body != null) {
      walkSections(body, 0);
    } else {
      warnings.add(
        const ParseWarning(
          'cda.narrative_only',
          'document has no structuredBody; only header metadata was extracted',
        ),
      );
    }

    if (textTruncated) {
      warnings.add(
        ParseWarning(
          'cda.text_truncated',
          'text exceeded ${options.limits.maxTextCharacters} characters',
        ),
      );
    }

    metadata['sectionCount'] = sectionIndex;
    if (outline.isNotEmpty) {
      metadata['sectionTitles'] = [for (final entry in outline) entry.title];
    }

    final attachments = <DocumentAttachment>[];
    if (options.includeAttachments) {
      attachments.addAll(_observationMedia(root, hasher, options, warnings));
    }
    if (attachments.isNotEmpty) {
      metadata['attachmentCount'] = attachments.length;
    }

    return ParseResult(
      documentId: digest.sha256,
      digest: digest,
      format: format,
      byteLength: bytes.length,
      metadata: metadata,
      text: textBuffer.toString().trimRight().isBlank
          ? null
          : textBuffer.toString().trimRight(),
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

  // --- header metadata ------------------------------------------------------

  static void _readRecordTarget(
    XmlElement root,
    Map<String, Object?> metadata,
  ) {
    final role = root.findAllElements('patientRole').firstOrNull;
    if (role == null) return;
    final patient = role.findElements('patient').firstOrNull;
    final names = <String>[];
    if (patient != null) {
      for (final name in patient.findElements('name')) {
        final value = name.innerText.trim();
        if (value.isNotEmpty) names.add(value);
      }
      if (names.isNotEmpty) metadata['patientNames'] = names;
      final gender = patient
          .findElements('administrativeGenderCode')
          .firstOrNull;
      final genderCode = gender?.getAttribute('code');
      if (genderCode != null) metadata['patientGender'] = genderCode;
      final birth = patient.findElements('birthTime').firstOrNull;
      if (birth != null) metadata['patientBirthTime'] = _timeValue(birth);
    }
    final ids = <String>[];
    for (final id in role.findElements('id')) {
      final value = _idString(id);
      if (value.isNotBlank) ids.add(value);
    }
    if (ids.isNotEmpty) {
      metadata['patientIds'] = ids;
      metadata['patientId'] = ids.first;
    }
    final addresses = <String>[];
    for (final address in role.findElements('addr')) {
      final value = address.innerText.trim();
      if (value.isNotEmpty) addresses.add(value);
    }
    if (addresses.isNotEmpty) metadata['patientAddresses'] = addresses;
    final telecoms = <String>[];
    for (final telecom in role.findElements('telecom')) {
      final value = telecom.getAttribute('value');
      if (value != null && value.isNotEmpty) telecoms.add(value);
    }
    if (telecoms.isNotEmpty) metadata['patientTelecoms'] = telecoms;
  }

  static void _readAuthors(XmlElement root, Map<String, Object?> metadata) {
    final authors = <Map<String, Object?>>[];
    for (final author in root.findAllElements('author')) {
      if (authors.length >= 100) break;
      final time = author.findAllElements('time').firstOrNull;
      final person = author.findAllElements('assignedPerson').firstOrNull;
      final authoringDevice = author
          .findAllElements('authoringDevice')
          .firstOrNull;
      final entry = <String, Object?>{
        if (time != null) 'time': _timeValue(time),
        if (person != null) 'name': person.innerText.trim(),
        if (authoringDevice != null) 'device': authoringDevice.innerText.trim(),
      };
      if (entry.isNotEmpty) authors.add(entry);
    }
    if (authors.isNotEmpty) metadata['authors'] = authors;
  }

  static void _readCustodian(XmlElement root, Map<String, Object?> metadata) {
    final organization = root
        .findAllElements('representedCustodianOrganization')
        .firstOrNull;
    if (organization != null) {
      final name = organization.findAllElements('name').firstOrNull;
      if (name != null && name.innerText.trim().isNotEmpty) {
        metadata['custodian'] = name.innerText.trim();
      }
    }
  }

  static void _readDocumentation(
    XmlElement root,
    Map<String, Object?> metadata,
  ) {
    final serviceEvent = root.findAllElements('serviceEvent').firstOrNull;
    if (serviceEvent == null) return;
    final code = serviceEvent.findAllElements('code').firstOrNull;
    if (code != null) {
      metadata['serviceEventCode'] = code.getAttribute('code');
      metadata['serviceEvent'] = code.getAttribute('displayName');
    }
    final effective = serviceEvent.findAllElements('effectiveTime').firstOrNull;
    if (effective != null) {
      metadata['serviceEventTime'] = _timeValue(effective);
    }
  }

  static void _readEncounter(XmlElement root, Map<String, Object?> metadata) {
    final encounter = root.findAllElements('encompassingEncounter').firstOrNull;
    if (encounter == null) return;
    final code = encounter.findAllElements('code').firstOrNull;
    if (code != null) {
      metadata['encounterCode'] = code.getAttribute('code');
      metadata['encounterType'] = code.getAttribute('displayName');
    }
    final effective = encounter.findAllElements('effectiveTime').firstOrNull;
    if (effective != null) {
      metadata['encounterTime'] = _timeValue(effective);
    }
    final location = encounter.findAllElements('name').firstOrNull;
    if (location != null && location.innerText.trim().isNotEmpty) {
      metadata['encounterLocation'] = location.innerText.trim();
    }
  }

  // --- narrative / tables ---------------------------------------------------

  static List<String> _narrativeLines(XmlElement text) {
    final buffer = StringBuffer();
    var last = 0;

    void write(String raw) {
      if (raw.isEmpty) return;
      final value = raw.replaceAll(RegExp(r'\s+'), ' ');
      if (value.isEmpty) return;
      if (last != 0 && _isWord(last) && _isWord(value.codeUnitAt(0))) {
        buffer.write(' ');
      }
      buffer.write(value);
      last = value.codeUnitAt(value.length - 1);
    }

    void newline() {
      if (last == 0 || last == 0x0A) return;
      buffer.write('\n');
      last = 0x0A;
    }

    void walk(XmlNode node) {
      if (node is XmlText || node is XmlCDATA) {
        write(node.value ?? '');
        return;
      }
      if (node is! XmlElement) return;
      final local = node.name.local.toLowerCase();
      if (local == 'reference' ||
          local == 'footnote' ||
          local == 'renderMultiMedia') {
        return;
      }
      final block =
          local == 'paragraph' ||
          local == 'item' ||
          local == 'caption' ||
          local == 'tr' ||
          local == 'td' ||
          local == 'th' ||
          local == 'br' ||
          local == 'list';
      if (block) newline();
      for (final child in node.children) {
        walk(child);
      }
      if (block) newline();
    }

    walk(text);
    final lines = <String>[];
    for (final line in buffer.toString().split('\n')) {
      final value = line.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (value.isNotEmpty) lines.add(value);
    }
    return lines;
  }

  static List<List<String>>? _parseTable(XmlElement table) {
    final rows = <List<String>>[];
    for (final row in table.descendants.whereType<XmlElement>()) {
      if (row.name.local.toLowerCase() != 'tr') continue;
      final cells = <String>[];
      for (final cell in row.children.whereType<XmlElement>()) {
        final local = cell.name.local.toLowerCase();
        if (local == 'td' || local == 'th') {
          cells.add(cell.innerText.replaceAll(RegExp(r'\s+'), ' ').trim());
        }
      }
      if (cells.isNotEmpty) rows.add(cells);
    }
    return rows.isEmpty ? null : rows;
  }

  // --- attachments ----------------------------------------------------------

  static Iterable<DocumentAttachment> _observationMedia(
    XmlElement root,
    ContentHasher hasher,
    ParseOptions options,
    List<ParseWarning> warnings,
  ) sync* {
    var total = 0;
    for (final media in root.findAllElements('observationMedia')) {
      final value = media.findElements('value').firstOrNull;
      if (value == null) continue;
      final mediaType = value.getAttribute('mediaType');
      final text = value.innerText.trim();
      if (text.isEmpty) continue;
      final Uint8List bytes;
      try {
        bytes = base64Decode(text);
      } on FormatException {
        warnings.add(
          const ParseWarning(
            'cda.attachment_invalid_base64',
            'observationMedia value is not valid base64',
          ),
        );
        continue;
      }
      if (bytes.length > options.limits.maxAttachmentBytes ||
          total + bytes.length > options.limits.maxAttachmentBytes) {
        warnings.add(
          ParseWarning(
            'cda.attachment_limit',
            'observationMedia exceeded the ${options.limits.maxAttachmentBytes} byte budget',
          ),
        );
        continue;
      }
      total += bytes.length;
      yield DocumentAttachment(
        name: media.getAttribute('ID'),
        mediaType: mediaType,
        size: bytes.length,
        digest: hasher.digestFor(bytes),
        bytes: options.includeAttachmentBytes ? bytes : null,
        relationship: 'observationMedia',
      );
      if (total >= options.limits.maxAttachmentBytes) break;
    }
  }

  // --- helpers --------------------------------------------------------------

  static XmlElement? _child(XmlElement parent, String local) {
    for (final child in parent.childElements) {
      if (child.name.local == local) return child;
    }
    return null;
  }

  static String _childText(XmlElement parent, String local) =>
      _child(parent, local)?.innerText.trim() ?? '';

  static String _idString(XmlElement id) {
    final root = id.getAttribute('root');
    final extension = id.getAttribute('extension');
    if (root != null && extension != null) return '$root|$extension';
    return root ?? extension ?? id.innerText.trim();
  }

  static String? _timeValue(XmlElement time) {
    final value = time.getAttribute('value');
    if (value != null && value.isNotEmpty) return value;
    final low = time.getAttribute('low');
    final high = time.getAttribute('high');
    if (low != null && high != null) return '$low..$high';
    return low ?? high ?? time.innerText.trim().nullIfBlank;
  }

  static bool _isWord(int code) =>
      (code >= 0x30 && code <= 0x39) ||
      (code >= 0x41 && code <= 0x5A) ||
      (code >= 0x61 && code <= 0x7A) ||
      code > 0x7F;
}

extension on String {
  String? get nullIfBlank => isBlank ? null : this;
}
