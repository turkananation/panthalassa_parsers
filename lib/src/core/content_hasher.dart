import 'dart:typed_data';

import 'package:pqforge/pqforge.dart';

/// Produces a stable, content-addressed identifier for a document.
///
/// Deliberately abstract: `bytes.hashCode` is forbidden in this package because
/// Dart's `Object.hashCode` is unstable across isolates and runs and collides,
/// which breaks both the unique index and the AAD binding downstream.
abstract interface class ContentHasher {
  /// Returns a deterministic identifier for [bytes].
  String idFor(Uint8List bytes);
}

/// Default content hasher: lowercase hex SHA-256 computed via the vault's
/// `PqBytes.sha256`.
///
/// Using `PqBytes.sha256` (rather than a second SHA-256 implementation) keeps a
/// single hash path across the entire Panthalassa stack, so a document id minted
/// here is byte-identical to one minted in the sealing pipeline, the audit
/// chain, or any AAD binding.
final class PqBytesContentHasher implements ContentHasher {
  const PqBytesContentHasher();

  @override
  String idFor(Uint8List bytes) => _hex(PqBytes.sha256(bytes));

  static String _hex(Uint8List digest) {
    final sb = StringBuffer();
    for (final b in digest) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
