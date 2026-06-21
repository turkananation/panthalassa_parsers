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
export 'src/core/document_parser.dart' show DocumentParser;
export 'src/core/parse_exception.dart';
export 'src/core/parse_result.dart';
export 'src/core/parser_registry.dart' show ParserRegistry;
export 'src/render/document_ir.dart';
export 'src/render/document_renderer.dart';
export 'src/render/visual_document.dart';
export 'src/render/visual_primitives.dart';
export 'src/render/visual_renderer.dart';
