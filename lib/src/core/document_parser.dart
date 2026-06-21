import 'dart:typed_data';

import 'content_hasher.dart';
import 'document_format.dart';
import 'parse_result.dart';

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
