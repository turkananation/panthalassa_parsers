import 'dart:typed_data';

import 'package:swissarmyknife/swissarmyknife.dart';

import '../parsers/cda_parser.dart';
import '../parsers/csv_parser.dart';
import '../parsers/dicom_json_parser.dart';
import '../parsers/dicom_parser.dart';
import '../parsers/edifact_parser.dart';
import '../parsers/eml_parser.dart';
import '../parsers/epub_parser.dart';
import '../parsers/html_parser.dart';
import '../parsers/image_metadata_parser.dart';
import '../parsers/markdown_parser.dart';
import '../parsers/fhir_json_parser.dart';
import '../parsers/hl7v2_parser.dart';
import '../parsers/iso20022_parser.dart';
import '../parsers/json_structured_parser.dart';
import '../parsers/nitf_parser.dart';
import '../parsers/odf_parser.dart';
import '../parsers/ooxml_parser.dart';
import '../parsers/pdf_parser.dart';
import '../parsers/stanag/stanag_parser.dart';
import '../parsers/step_parser.dart';
import '../parsers/usmtf_parser.dart';
import '../parsers/verifiable_credential_parser.dart';
import '../parsers/x12_parser.dart';
import '../parsers/xml_fhir_parser.dart';
import '../parsers/xml_structured_parser.dart';
import 'content_hasher.dart';
import 'document_format.dart';
import 'document_parser.dart';
import 'format_detector.dart';
import 'isolate_runner_web.dart' if (dart.library.io) 'isolate_runner_io.dart';
import 'parse_exception.dart';
import 'parse_options.dart';
import 'parse_result.dart';
import 'structured_artifacts.dart';

/// The package entry point: detects a document's format and parses it.
///
/// ```dart
/// final registry = ParserRegistry.standard();
/// final result = registry.parse(bytes);          // sync, for small inputs
/// final big = await registry.parseInIsolate(bytes); // offloads CPU work
/// ```
///
/// All parsers are stateless and `const`, so one registry can be shared across
/// requests/isolates. Parsing failures are always [ParseException] subtypes,
/// even when a third-party parser bug escapes as a raw error.
final class ParserRegistry {
  ParserRegistry(this._parsers, {ContentHasher? hasher})
    : _hasher = hasher ?? const PqBytesContentHasher(),
      _detector = FormatDetector(_parsers);

  /// Registers every built-in parser in detection-priority order
  /// (strong binary magic first, permissive text heuristics last).
  factory ParserRegistry.standard({ContentHasher? hasher}) =>
      ParserRegistry(const [
        DicomParser(),
        DicomJsonParser(),
        ImageMetadataParser(),
        PdfParser(),
        NitfParser(),
        StanagParser(),
        EpubParser(),
        OdfParser(),
        OoxmlParser(DocumentFormat.docx),
        OoxmlParser(DocumentFormat.xlsx),
        OoxmlParser(DocumentFormat.pptx),
        Hl7V2Parser(),
        X12Parser(),
        EdifactParser(),
        EmlParser(),
        HtmlParser(),
        StepParser(),
        VerifiableCredentialParser(),
        FhirJsonParser(),
        Iso20022Parser(),
        CdaParser(),
        XmlFhirParser(),
        JsonStructuredParser(),
        XmlStructuredParser(),
        UsmtfParser(),
        MarkdownParser(),
        CsvParser(),
      ], hasher: hasher);

  final List<DocumentParser> _parsers;
  final FormatDetector _detector;
  final ContentHasher _hasher;

  /// Detects the format without fully parsing.
  DocumentFormat detect(Uint8List bytes, {DocumentHints? hints}) =>
      _detector.detectWithHints(bytes, hints ?? const DocumentHints());

  /// Detects with confidence and evidence, for ambiguity handling.
  DetectionResult detectDetailed(Uint8List bytes, {DocumentHints? hints}) =>
      _detector.detectDetailed(bytes, hints: hints);

  /// The registered parsers, in detection-priority order.
  List<DocumentParser> get parsers => List.unmodifiable(_parsers);

  /// Detects and parses [bytes].
  ///
  /// Throws [UnsupportedFormatException] if no parser recognises the input, or
  /// another [ParseException] subtype if parsing fails.
  ParseResult parse(
    Uint8List bytes, {
    ParseOptions options = const ParseOptions(),
    DocumentHints? hints,
  }) {
    final h = hints ?? const DocumentHints();
    for (final parser in _parsers) {
      if (!parserMatches(parser, bytes, h)) continue;
      return _finish(parser, bytes, options, h);
    }
    throw const UnsupportedFormatException(
      'no registered parser recognised the input',
    );
  }

  /// Parses on a background isolate. Use for inputs large enough that parsing
  /// would breach the caller's frame budget (DICOM studies, large PDFs).
  ///
  /// On web, where isolates are unavailable, the work runs on the current
  /// event-loop thread and the returned future still completes asynchronously.
  ///
  /// Note: the default [PqBytesContentHasher] is `const` and isolate-safe. A
  /// custom [ContentHasher] holding non-transferable state will fail to send;
  /// keep injected hashers pure.
  Future<ParseResult> parseInIsolate(
    Uint8List bytes, {
    ParseOptions options = const ParseOptions(),
    DocumentHints? hints,
  }) {
    final parserList = _parsers;
    final hasher = _hasher;
    final h = hints ?? const DocumentHints();
    return runOnIsolate(() {
      for (final parser in parserList) {
        if (!parserMatches(parser, bytes, h)) continue;
        return _parseAndDecorate(parser, bytes, hasher, options, h);
      }
      throw const UnsupportedFormatException(
        'no registered parser recognised the input',
      );
    });
  }

  /// Parses several inputs with bounded isolate concurrency.
  ///
  /// This is the batch-ingest entry point: it avoids unbounded isolate spawn
  /// storms while still parallelising CPU-bound documents. Order is preserved.
  Future<List<ParseResult>> parseBatch(
    Iterable<Uint8List> inputs, {
    int concurrency = 2,
    ParseOptions options = const ParseOptions(),
    DocumentHints? hints,
  }) {
    final queue = TaskQueue(concurrency: concurrency);
    final futures = [
      for (final input in inputs)
        queue
            .add(
              () => parseInIsolate(input, options: options, hints: hints),
              name: 'parse',
            )
            .future,
    ];
    return Future.wait(futures);
  }

  ParseResult _finish(
    DocumentParser parser,
    Uint8List bytes,
    ParseOptions options,
    DocumentHints hints,
  ) {
    final result = _parseAndDecorate(parser, bytes, _hasher, options, hints);
    return result;
  }

  static ParseResult _parseAndDecorate(
    DocumentParser parser,
    Uint8List bytes,
    ContentHasher hasher,
    ParseOptions options,
    DocumentHints hints,
  ) {
    try {
      final raw = parser is OptionAwareDocumentParser
          ? (parser as OptionAwareDocumentParser).parseWithOptions(
              bytes,
              hasher: hasher,
              options: options,
              hints: hints,
            )
          : parser.parse(bytes, hasher: hasher);
      return _decorate(raw, bytes, hasher, parser, options);
    } on ParseException {
      rethrow;
    } catch (_) {
      // Never leak payload bytes or raw third-party errors across the boundary.
      throw MalformedDocumentException(
        '${parser.format.name} parser failed unexpectedly',
      );
    }
  }

  static ParseResult _decorate(
    ParseResult raw,
    Uint8List bytes,
    ContentHasher hasher,
    DocumentParser parser,
    ParseOptions options,
  ) {
    final digest = raw.digest ?? hasher.digestFor(bytes);
    var text = raw.text;
    final warnings = [...raw.warnings];
    final maxText = options.limits.maxTextCharacters;
    if (text != null && text.length > maxText) {
      text = text.substring(0, maxText);
      warnings.add(
        ParseWarning(
          'parse.text_truncated',
          'text exceeded $maxText characters and was truncated',
        ),
      );
    }
    return ParseResult(
      documentId: digest.sha256,
      digest: digest,
      format: raw.format,
      byteLength: raw.byteLength,
      metadata: _boundedMetadata(
        raw.metadata,
        options.limits.maxMetadataEntries,
        warnings,
      ),
      text: text,
      warnings: warnings,
      structuredText: raw.structuredText,
      outline: raw.outline,
      tables: raw.tables,
      attachments: raw.attachments,
      signatures: raw.signatures,
      securityLabel: raw.securityLabel,
      parserVersion: raw.parserVersion == 'unknown'
          ? parser.parserVersion
          : raw.parserVersion,
    );
  }

  /// Recursively caps metadata to a node budget and coerces non-JSON values.
  ///
  /// This prevents a hostile document from forcing unbounded retained metadata
  /// even when individual parser fields are reasonable.
  static Map<String, Object?> _boundedMetadata(
    Map<String, Object?> source,
    int budget,
    List<ParseWarning> warnings,
  ) {
    var remaining = budget;
    var truncated = false;
    Object? walk(Object? value) {
      if (remaining <= 0) {
        truncated = true;
        return null;
      }
      remaining--;
      if (value == null || value is String || value is num || value is bool) {
        return value;
      }
      if (value is Uint8List) {
        return '<${value.length} bytes>';
      }
      if (value is Map) {
        final out = <String, Object?>{};
        for (final entry in value.entries) {
          if (remaining <= 0) {
            truncated = true;
            break;
          }
          out['${entry.key}'] = walk(entry.value);
        }
        return out;
      }
      if (value is Iterable) {
        final out = <Object?>[];
        for (final element in value) {
          if (remaining <= 0) {
            truncated = true;
            break;
          }
          out.add(walk(element));
        }
        return out;
      }
      return value.toString();
    }

    final out = <String, Object?>{};
    for (final entry in source.entries) {
      if (remaining <= 0) {
        truncated = true;
        break;
      }
      out[entry.key] = walk(entry.value);
    }
    if (truncated) {
      warnings.add(
        const ParseWarning(
          'parse.metadata_truncated',
          'metadata exceeded its node budget and was truncated',
        ),
      );
    }
    return out;
  }
}
