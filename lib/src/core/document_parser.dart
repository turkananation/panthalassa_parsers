import 'dart:typed_data';

import 'content_hasher.dart';
import 'document_format.dart';
import 'parse_options.dart';
import 'parse_result.dart';
import 'structured_artifacts.dart';

/// Current parser implementation version stamped onto every result.
///
/// Keep in lockstep with `pubspec.yaml`; vault migrations can use it to explain
/// output-shape changes that were not covered by [ParseResult] schema bumps.
const String parserImplementationVersion = '0.5.1';

/// Contract every format parser implements.
///
/// Implementations must be stateless and side-effect free so a single instance
/// can be shared and safely invoked from any isolate. [canParse] must be cheap
/// (inspect only a small prefix / a few fixed offsets) because the detector
/// calls it across every registered parser.
abstract interface class DocumentParser {
  /// The format this parser produces.
  DocumentFormat get format;

  /// Fast, allocation-light recognition check. Must not throw; return `false`
  /// on any uncertainty rather than risking a false positive.
  bool canParse(Uint8List bytes);

  /// Parses [bytes], computing the content id with [hasher].
  ///
  /// Throws a [ParseException] subtype on failure. Must never throw an untyped
  /// error; wrap third-party failures.
  ParseResult parse(Uint8List bytes, {required ContentHasher hasher});
}

/// Optional capability for parsers that understand [ParseOptions] and hints.
///
/// Kept separate from [DocumentParser] so third-party implementations that only
/// support the original contract continue to work unchanged.
abstract interface class OptionAwareDocumentParser {
  ParseResult parseWithOptions(
    Uint8List bytes, {
    required ContentHasher hasher,
    ParseOptions options = const ParseOptions(),
    DocumentHints? hints,
  });
}

/// Optional capability for parsers whose formats cannot be identified from
/// content alone and need caller-supplied hints (filename or MIME type).
///
/// Implementations must stay cheap and non-throwing, exactly like
/// [DocumentParser.canParse]. The detector checks for this interface before
/// falling back to content-only recognition, so ambiguous formats such as
/// Markdown and CSV never claim arbitrary plain text.
abstract interface class HintAwareDocumentParser {
  bool canParseWithHints(Uint8List bytes, DocumentHints hints);
}

/// Resolves hint-aware recognition for [parser].
///
/// Instance members always win over the [DocumentParserMetadata] extension in
/// Dart; this helper performs the runtime check explicitly so implementing
/// [HintAwareDocumentParser] actually changes detector behaviour.
bool parserMatches(
  DocumentParser parser,
  Uint8List bytes,
  DocumentHints hints,
) {
  if (hints.filename == null && hints.mimeType == null) {
    return parser.canParse(bytes);
  }
  if (parser is HintAwareDocumentParser) {
    // Explicit cast: extension-member resolution is static, and a promoted
    // `DocumentParser` can still bind to the [DocumentParserMetadata] default
    // unless the interface type is named directly.
    return (parser as HintAwareDocumentParser).canParseWithHints(bytes, hints);
  }
  return parser.canParse(bytes);
}

/// Metadata and hint-aware detection defaults for every parser.
extension DocumentParserMetadata on DocumentParser {
  /// Version of this parser implementation.
  String get parserVersion => parserImplementationVersion;

  /// Hint-aware recognition. The default delegates to [canParse]; parsers whose
  /// formats are inherently ambiguous implement [HintAwareDocumentParser].
  bool canParseWithHints(Uint8List bytes, DocumentHints hints) =>
      canParse(bytes);
}
