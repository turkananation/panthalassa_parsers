/// Base type for every failure surfaced by this package.
///
/// Sealed so call sites can exhaustively switch on the failure mode and so that
/// no untyped [Exception] ever escapes a parser. Parsers must translate every
/// internal error (including those from third-party packages) into one of these.
sealed class ParseException implements Exception {
  const ParseException(this.message, {this.offset});

  /// Human-readable description. Never contains document payload bytes.
  final String message;

  /// Byte offset at which the failure was detected, when known.
  final int? offset;

  @override
  String toString() {
    final at = offset == null ? '' : ' at offset $offset';
    return '$runtimeType: $message$at';
  }
}

/// No registered parser recognised the input, or detection was ambiguous.
final class UnsupportedFormatException extends ParseException {
  const UnsupportedFormatException(super.message);
}

/// The format was recognised but the byte stream violates its grammar.
final class MalformedDocumentException extends ParseException {
  const MalformedDocumentException(super.message, {super.offset});
}

/// The byte stream ended before a required structure could be read.
final class TruncatedDocumentException extends ParseException {
  const TruncatedDocumentException(super.message, {super.offset});
}

/// Text could not be decoded under the format's required encoding.
///
/// Raised instead of silently substituting replacement characters, so callers
/// never persist a corrupted transcription.
final class TextDecodingException extends ParseException {
  const TextDecodingException(super.message, {super.offset});
}

/// The format was parsed but a feature required to complete the request is not
/// yet implemented (e.g. an encrypted PDF, or a compressed object stream).
final class UnsupportedFeatureException extends ParseException {
  const UnsupportedFeatureException(super.message, {super.offset});
}
