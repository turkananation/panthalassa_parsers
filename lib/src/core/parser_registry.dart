import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../parsers/cda_parser.dart';
import '../parsers/dicom_parser.dart';
import '../parsers/edifact_parser.dart';
import '../parsers/fhir_json_parser.dart';
import '../parsers/hl7v2_parser.dart';
import '../parsers/iso20022_parser.dart';
import '../parsers/json_structured_parser.dart';
import '../parsers/nitf_parser.dart';
import '../parsers/odf_parser.dart';
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
import 'parse_exception.dart';
import 'parse_result.dart';

/// The package entry point: detects a document's format and parses it.
///
/// ```dart
/// final registry = ParserRegistry.standard();
/// final result = registry.parse(bytes);          // sync, for small inputs
/// final big = await registry.parseInIsolate(bytes); // offloads CPU work
/// ```
final class ParserRegistry {
  ParserRegistry(this._parsers, {ContentHasher? hasher})
      : _hasher = hasher ?? const PqBytesContentHasher(),
        _detector = FormatDetector(_parsers);

  /// Registers every built-in parser in detection-priority order
  /// (strong binary magic first, permissive text heuristics last).
  factory ParserRegistry.standard({ContentHasher? hasher}) => ParserRegistry(
        const [
          DicomParser(),
          PdfParser(),
          NitfParser(),
          StanagParser(),
          OdfParser(),
          Hl7V2Parser(),
          X12Parser(),
          EdifactParser(),
          StepParser(),
          VerifiableCredentialParser(),
          FhirJsonParser(),
          Iso20022Parser(),
          CdaParser(),
          XmlFhirParser(),
          JsonStructuredParser(),
          XmlStructuredParser(),
          UsmtfParser(),
        ],
        hasher: hasher,
      );

  final List<DocumentParser> _parsers;
  final FormatDetector _detector;
  final ContentHasher _hasher;

  /// Detects the format without fully parsing.
  DocumentFormat detect(Uint8List bytes) => _detector.detect(bytes);

  /// Detects and parses [bytes].
  ///
  /// Throws [UnsupportedFormatException] if no parser recognises the input, or
  /// another [ParseException] subtype if parsing fails.
  ParseResult parse(Uint8List bytes) {
    for (final parser in _parsers) {
      if (parser.canParse(bytes)) {
        return parser.parse(bytes, hasher: _hasher);
      }
    }
    throw const UnsupportedFormatException(
      'no registered parser recognised the input',
    );
  }

  /// Parses on a background isolate. Use for inputs large enough that parsing
  /// would breach the caller's frame budget (DICOM studies, large PDFs).
  ///
  /// Note: the default [PqBytesContentHasher] is `const` and isolate-safe. A
  /// custom [ContentHasher] holding non-transferable state will fail to send;
  /// keep injected hashers pure.
  Future<ParseResult> parseInIsolate(Uint8List bytes) {
    final parsers = _parsers;
    final hasher = _hasher;
    return Isolate.run(() {
      for (final parser in parsers) {
        if (parser.canParse(bytes)) {
          return parser.parse(bytes, hasher: hasher);
        }
      }
      throw const UnsupportedFormatException(
        'no registered parser recognised the input',
      );
    });
  }
}
