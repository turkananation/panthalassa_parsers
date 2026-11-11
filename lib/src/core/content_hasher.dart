import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'sha2_backend_web.dart' if (dart.library.io) 'sha2_backend_pqforge.dart';

/// A triple content digest: SHA-256 (the vault's canonical document id), plus
/// SHA-384 and SHA-512 for long-lived integrity evidence and cross-system
/// interop.
///
/// All values are lowercase hexadecimal strings with no prefix. The SHA-256
/// value is kept identical to the historical `documentId`, so existing vault
/// rows, AAD bindings, and dedup indexes continue to resolve.
@immutable
final class ContentDigest {
  const ContentDigest({
    required this.sha256,
    required this.sha384,
    required this.sha512,
  });

  /// Lowercase hex SHA-256 (64 characters).
  final String sha256;

  /// Lowercase hex SHA-384 (96 characters).
  final String sha384;

  /// Lowercase hex SHA-512 (128 characters).
  final String sha512;

  /// The canonical identity used by the vault: SHA-256 hex.
  String get canonical => sha256;

  bool get isValid =>
      sha256.length == 64 && sha384.length == 96 && sha512.length == 128;

  Map<String, Object?> toJson() => {
    'sha256': sha256,
    'sha384': sha384,
    'sha512': sha512,
  };

  @override
  bool operator ==(Object other) =>
      other is ContentDigest &&
      other.sha256 == sha256 &&
      other.sha384 == sha384 &&
      other.sha512 == sha512;

  @override
  int get hashCode => Object.hash(sha256, sha384, sha512);

  @override
  String toString() => sha256.length <= 12
      ? 'ContentDigest(sha256: $sha256)'
      : 'ContentDigest(sha256: ${sha256.substring(0, 12)}…)';
}

/// Produces stable, content-addressed digests for a document.
///
/// Deliberately abstract: `bytes.hashCode` is forbidden in this package because
/// Dart's `Object.hashCode` is unstable across isolates/runs and collides,
/// which breaks both the unique index and the AAD binding downstream.
abstract class ContentHasher {
  const ContentHasher();

  /// Returns SHA-256, SHA-384, and SHA-512 digests for [bytes].
  ContentDigest digestFor(Uint8List bytes);

  /// Returns the canonical lowercase hex SHA-256 identifier for [bytes].
  ///
  /// Retained for source compatibility; new code that needs both digests should
  /// call [digestFor] once and use [ContentDigest.sha256].
  String idFor(Uint8List bytes) => digestFor(bytes).sha256;
}

/// Default content hasher: lowercase hex SHA-256, SHA-384, and SHA-512.
///
/// On native platforms this calls the vault's `PqBytes` primitives. On web/WASM
/// it calls the same PointyCastle digest implementations that `PqBytes` wraps,
/// because pqforge's public barrel currently imports `dart:isolate` through
/// `zeroize`. Both paths produce byte-identical digests, so a document id minted
/// here stays compatible with the sealing pipeline, the audit chain, and any AAD
/// binding.
final class PqBytesContentHasher extends ContentHasher {
  const PqBytesContentHasher();

  @override
  ContentDigest digestFor(Uint8List bytes) => ContentDigest(
    sha256: _hex(sha256Digest(bytes)),
    sha384: _hex(sha384Digest(bytes)),
    sha512: _hex(sha512Digest(bytes)),
  );

  static String _hex(Uint8List digest) {
    final sb = StringBuffer();
    for (final b in digest) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
