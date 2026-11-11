import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/digests/sha384.dart';
import 'package:pointycastle/digests/sha512.dart';

/// Web/WASM SHA-2 backend.
///
/// `pqforge`'s `PqBytes` wraps these exact PointyCastle digest primitives, but
/// importing its public barrel also pulls in `dart:isolate` through `zeroize`,
/// which is unavailable on web/WASM. Calling the primitives directly keeps the
/// content-address bytes identical while allowing the library to compile for
/// every supported platform.
Uint8List sha256Digest(Uint8List bytes) => SHA256Digest().process(bytes);

Uint8List sha384Digest(Uint8List bytes) => SHA384Digest().process(bytes);

Uint8List sha512Digest(Uint8List bytes) => SHA512Digest().process(bytes);
