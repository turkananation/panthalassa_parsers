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
import 'cda_parser.dart';
import 'dicom_parser.dart';
import 'dicom_sr.dart';
import 'pdf_parser.dart';

/// Parser for DICOM JSON Model documents (PS3.18 Annex F).
///
/// DICOM JSON encodes a dataset as an object keyed by eight-hex-digit tags,
/// each with `vr` plus `Value`, `InlineBinary`, or `BulkDataURI`. Detection
/// requires at least one such tag object, so ordinary JSON is never claimed.
/// Extraction mirrors the binary DICOM parser: dictionary metadata, nested
/// sequences, SR content trees, and encapsulated documents. `BulkDataURI`
/// payloads are reported but never fetched.
final class DicomJsonParser
    implements DocumentParser, OptionAwareDocumentParser {
  const DicomJsonParser();

  static final _tagKey = RegExp(r'"[0-9A-Fa-f]{8}"\s*:\s*\{');

  @override
  DocumentFormat get format => DocumentFormat.dicom;

  String get parserVersion => parserImplementationVersion;

  @override
  bool canParse(Uint8List bytes) {
    if (bytes.isEmpty) return false;
    final prefix = _peekText(bytes, 16384).trimLeft();
    if (prefix.isEmpty || !prefix.startsWith('{')) return false;
    if (!prefix.contains('"vr"')) return false;
    if (!prefix.contains('"Value"') &&
        !prefix.contains('"InlineBinary"') &&
        !prefix.contains('"BulkDataURI"')) {
      return false;
    }
    return _tagKey.hasMatch(prefix);
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
    final warnings = <ParseWarning>[];
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } on FormatException {
      throw const MalformedDocumentException('invalid DICOM JSON');
    }
    if (decoded is! Map<String, Object?>) {
      throw const MalformedDocumentException(
        'DICOM JSON root must be an object',
      );
    }

    final metadata = <String, Object?>{};
    final attributes = <Map<String, Object?>>[];
    final encapsulated = <_EncapsulatedJson>[];
    var nodes = 0;
    var truncated = false;

    List<Map<String, Object?>> decodeObject(
      Map<String, Object?> object,
      int depth,
    ) {
      final attributesOut = <Map<String, Object?>>[];
      for (final entry in object.entries) {
        if (nodes >= options.limits.maxJsonNodes) {
          truncated = true;
          break;
        }
        nodes++;
        final tag = int.tryParse(entry.key, radix: 16);
        if (tag == null || entry.key.length != 8) continue;
        final element = entry.value;
        if (element is! Map<String, Object?>) continue;
        final vr = element['vr'] is String ? element['vr']! as String : 'UN';
        final value = element['Value'];
        final inline = element['InlineBinary'];
        final bulkUri = element['BulkDataURI'];
        final items = <Map<String, Object?>>[];
        Object? rendered;

        if (vr == 'SQ' && value is List && depth < 16) {
          for (final item in value) {
            if (item is! Map<String, Object?>) continue;
            final itemAttributes = decodeObject(item, depth + 1);
            items.add({'attributes': itemAttributes});
          }
          rendered = null;
        } else {
          if (value is List) {
            rendered = _renderValues(value, vr, options);
          }
          if (inline is String && tag == 0x00400011) {
            encapsulated.add(
              _EncapsulatedJson(
                title: _firstString(
                  (object['00400010'] as Map<String, Object?>?)?['Value'],
                ),
                mediaType: _firstString(
                  (object['00400012'] as Map<String, Object?>?)?['Value'],
                ),
                base64: inline,
              ),
            );
          }
          if (bulkUri is String && bulkUri.isNotBlank) {
            rendered = '<bulk data: $bulkUri>';
          }
        }

        final dict = DicomParser.tagDictionary[tag];
        if (dict != null && !metadata.containsKey(dict.key)) {
          metadata[dict.key] = items.isNotEmpty ? items.length : rendered;
        }
        final attribute = <String, Object?>{
          'tag': dicomTagHex(tag),
          if (dict != null) 'keyword': dict.key,
          'vr': vr,
          if (items.isNotEmpty) 'items': items,
          if (items.isEmpty) 'value': rendered,
        };
        attributesOut.add(attribute);
      }
      return attributesOut;
    }

    // decodeObject returns the attribute list; the local placeholder above is
    // not used.
    attributes.addAll(decodeObject(decoded, 0));
    if (truncated) {
      warnings.add(
        ParseWarning(
          'dicom.json_node_limit',
          'DICOM JSON exceeded ${options.limits.maxJsonNodes} nodes',
        ),
      );
    }

    final charset =
        _firstString(metadata['specificCharacterSet']) ?? 'ISO_IR 6';
    metadata['characterSet'] = charset;
    metadata['dicomJson'] = true;

    final sr = extractDicomStructuredReport(attributes, options, warnings);
    if (sr != null) {
      metadata['hasStructuredReport'] = true;
      metadata['structuredReport'] = sr.tree;
    }

    final attachments = _encapsulatedAttachments(
      encapsulated,
      hasher,
      options,
      warnings,
    );
    if (attachments.isNotEmpty) {
      metadata['attachmentCount'] = attachments.length;
    }

    return ParseResult(
      documentId: digest.sha256,
      digest: digest,
      format: format,
      byteLength: bytes.length,
      metadata: {...metadata, 'attributes': attributes},
      text: sr?.text,
      warnings: warnings,
      structuredText: options.includeStructuredText && sr != null
          ? StructuredText([TextPage(index: 0, blocks: sr.blocks)])
          : null,
      outline: options.includeOutline ? sr?.outline ?? const [] : const [],
      tables: options.includeTables ? sr?.tables ?? const [] : const [],
      attachments: attachments,
      parserVersion: parserVersion,
    );
  }

  static Object? _renderValues(
    List<Object?> values,
    String vr,
    ParseOptions options,
  ) {
    final rendered = <Object?>[];
    for (final value in values) {
      if (value is Map) {
        // PersonName object: join the alphabetic/ideographic components.
        final parts = <String>[];
        for (final key in const ['Alphabetic', 'Ideographic', 'Phonetic']) {
          final part = value[key];
          if (part is String && part.isNotEmpty) parts.add(part);
        }
        rendered.add(parts.join('='));
      } else {
        rendered.add(value);
      }
      if (rendered.length >= options.limits.maxSegments) break;
    }
    if (rendered.length == 1) return rendered.first;
    return rendered;
  }

  static List<DocumentAttachment> _encapsulatedAttachments(
    List<_EncapsulatedJson> encapsulated,
    ContentHasher hasher,
    ParseOptions options,
    List<ParseWarning> warnings,
  ) {
    if (!options.includeAttachments) return const [];
    final attachments = <DocumentAttachment>[];
    var total = 0;
    for (final document in encapsulated) {
      if (attachments.length >= options.limits.maxAttachments) break;
      final Uint8List bytes;
      try {
        bytes = base64Decode(document.base64);
      } on FormatException {
        warnings.add(
          const ParseWarning(
            'dicom.json_invalid_base64',
            'InlineBinary is not valid base64',
          ),
        );
        continue;
      }
      if (bytes.length > options.limits.maxAttachmentBytes ||
          total + bytes.length > options.limits.maxAttachmentBytes) {
        warnings.add(
          ParseWarning(
            'dicom.json_attachment_limit',
            'encapsulated document exceeded the '
                '${options.limits.maxAttachmentBytes} byte budget',
          ),
        );
        continue;
      }
      total += bytes.length;
      final mime = document.mediaType ?? _sniffMime(bytes);
      ParseResult? child;
      String? text;
      if (options.parseAttachments) {
        try {
          if (mime == 'application/pdf' || _startsWith(bytes, '%PDF')) {
            child = const PdfParser().parseWithOptions(
              bytes,
              hasher: hasher,
              options: options,
            );
          } else if (mime.contains('xml') || _looksLikeXml(bytes)) {
            child = const CdaParser().parseWithOptions(
              bytes,
              hasher: hasher,
              options: options,
            );
          }
        } on ParseException catch (error) {
          warnings.add(
            ParseWarning(
              'dicom.json_encapsulated_parse_failed',
              'encapsulated document could not be parsed: ${error.message}',
            ),
          );
        }
      }
      if (child != null) {
        text = child.text;
      } else if (mime.startsWith('text/') || mime.contains('xml')) {
        text = utf8
            .decode(bytes, allowMalformed: true)
            .truncate(options.limits.maxTextCharacters);
      }
      attachments.add(
        DocumentAttachment(
          name: document.title ?? 'encapsulated-document',
          mediaType: mime,
          size: bytes.length,
          digest: hasher.digestFor(bytes),
          bytes: options.includeAttachmentBytes ? bytes : null,
          text: text,
          child: child,
          relationship: 'encapsulatedDocument',
        ),
      );
    }
    return attachments;
  }

  static String _sniffMime(Uint8List bytes) {
    if (_startsWith(bytes, '%PDF')) return 'application/pdf';
    if (_looksLikeXml(bytes)) return 'application/xml';
    return 'application/octet-stream';
  }

  static bool _startsWith(Uint8List bytes, String prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix.codeUnitAt(i)) return false;
    }
    return true;
  }

  static bool _looksLikeXml(Uint8List bytes) {
    var i = 0;
    while (i < bytes.length && i < 64) {
      final c = bytes[i];
      if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) {
        i++;
        continue;
      }
      return c == 0x3C;
    }
    return false;
  }

  static String? _firstString(Object? value) {
    if (value is String && value.isNotBlank) return value;
    if (value is List) {
      for (final item in value) {
        if (item is String && item.isNotBlank) return item;
      }
    }
    return null;
  }

  static String _peekText(Uint8List bytes, int max) {
    final end = bytes.length <= max ? bytes.length : max;
    return utf8.decode(
      Uint8List.sublistView(bytes, 0, end),
      allowMalformed: true,
    );
  }
}

final class _EncapsulatedJson {
  const _EncapsulatedJson({this.title, this.mediaType, required this.base64});

  final String? title;
  final String? mediaType;
  final String base64;
}
