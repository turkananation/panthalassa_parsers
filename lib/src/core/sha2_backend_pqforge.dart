import 'dart:typed_data';

import 'package:pqforge/pqforge.dart' show PqBytes;

/// Native SHA-2 backend: the vault's single `pqforge` hash path.
///
/// This file is only imported when `dart.library.io` is available. Keeping the
/// pqforge import behind a conditional import preserves web/WASM compatibility
/// while native builds continue to mint digests through `PqBytes`.
Uint8List sha256Digest(Uint8List bytes) => PqBytes.sha256(bytes);

Uint8List sha384Digest(Uint8List bytes) => PqBytes.sha384(bytes);

Uint8List sha512Digest(Uint8List bytes) => PqBytes.sha512(bytes);
