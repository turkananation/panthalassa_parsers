/// Pure-Dart, zero-FFI document parsers for the Panthalassa Vault.
///
/// Detects and parses healthcare (FHIR JSON/XML, HL7 v2, CDA), structured
/// JSON/XML (W3C Verifiable Credentials, NIEM, ISO 20022, generic), EDI
/// (EDIFACT, X12), positional (USMTF, STEP), binary (DICOM, NITF, STANAG), and
/// composite (PDF incl. PDF/A-3 embedded files, ODF) formats into
/// content-addressed, isolate-safe [ParseResult]s.
///
/// ```dart
/// final registry = ParserRegistry.standard();
/// final result = await registry.parseInIsolate(bytes);
/// print('${result.format.label}: ${result.documentId}');
/// ```
library;

export 'src/core/content_hasher.dart' show ContentHasher, PqBytesContentHasher;
export 'src/core/document_capability.dart';
export 'src/core/document_format.dart';
export 'src/core/document_parser.dart';
export 'src/core/parse_exception.dart';
export 'src/core/parse_result.dart';
export 'src/core/parser_registry.dart';
export 'src/core/format_detector.dart';
export 'src/core/byte_reader.dart';

export 'src/parsers/cda_parser.dart';
export 'src/parsers/dicom_parser.dart';
export 'src/parsers/edifact_parser.dart';
export 'src/parsers/fhir_json_parser.dart';
export 'src/parsers/hl7v2_parser.dart';
export 'src/parsers/iso20022_parser.dart';
export 'src/parsers/json_support.dart';
export 'src/parsers/nitf_parser.dart';
export 'src/parsers/x12_parser.dart';
export 'src/parsers/usmtf_parser.dart';
export 'src/parsers/step_parser.dart';
export 'src/parsers/pdf_parser.dart';
export 'src/parsers/odf_parser.dart';
export 'src/parsers/json_structured_parser.dart';
export 'src/parsers/verifiable_credential_parser.dart';
export 'src/parsers/xml_structured_parser.dart';
export 'src/parsers/xml_support.dart';
export 'src/parsers/xml_fhir_parser.dart';
export 'src/parsers/stanag/stanag_parser.dart';
export 'src/parsers/stanag/stanag_xml.dart';
export 'src/parsers/stanag/stanag_4607_gmti.dart';
export 'src/parsers/stanag/stanag_4609_motion_imagery.dart';
export 'src/parsers/stanag/stanag_5516_link16.dart';
export 'src/parsers/stanag/stanag_7023_npif.dart';
export 'src/parsers/pdf/pdf_crypt.dart';
export 'src/parsers/pdf/pdf_encodings.dart';
export 'src/parsers/pdf/pdf_filters.dart';
export 'src/parsers/pdf/pdf_internals.dart';
export 'src/parsers/pdf/pdf_text.dart';
export 'src/parsers/pdf/pdf_visual.dart';

export 'src/render/document_ir.dart';
export 'src/render/document_renderer.dart';
export 'src/render/visual_document.dart';
export 'src/render/visual_primitives.dart';
export 'src/render/visual_renderer.dart';
