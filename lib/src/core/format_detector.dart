import 'dart:typed_data';

import 'document_format.dart';
import 'document_parser.dart';

/// Resolves a [DocumentFormat] from raw bytes.
///
/// Order is load-bearing: parsers with strong binary magic numbers are
/// consulted before text heuristics, so that, for example, a PDF whose body
/// happens to contain XML, or a DICOM file with ASCII in its dataset, is never
/// misclassified by a permissive text sniffer. The registry constructs the
/// detector with parsers already in that priority order.
final class FormatDetector {
  const FormatDetector(this._ordered);

  final List<DocumentParser> _ordered;

  /// Returns the format of the first parser that recognises [bytes], or
  /// [DocumentFormat.unknown] if none do.
  DocumentFormat detect(Uint8List bytes) {
    for (final parser in _ordered) {
      if (parser.canParse(bytes)) return parser.format;
    }
    return DocumentFormat.unknown;
  }
}
