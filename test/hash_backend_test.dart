import 'dart:typed_data';

import 'package:panthalassa_parsers/panthalassa_parsers.dart';
// ignore: implementation_imports
import 'package:panthalassa_parsers/src/core/sha2_backend_web.dart' as web;
import 'package:test/test.dart';

void main() {
  const hasher = PqBytesContentHasher();
  final samples = <Uint8List>[
    Uint8List(0),
    Uint8List.fromList('abc'.codeUnits),
    Uint8List.fromList(List<int>.generate(4096, (i) => i & 0xff)),
  ];

  test('web SHA-2 backend matches the native pqforge digests', () {
    for (final bytes in samples) {
      final digest = hasher.digestFor(bytes);
      expect(_hex(web.sha256Digest(bytes)), digest.sha256);
      expect(_hex(web.sha384Digest(bytes)), digest.sha384);
      expect(_hex(web.sha512Digest(bytes)), digest.sha512);
    }
  });
}

String _hex(Uint8List bytes) {
  final out = StringBuffer();
  for (final b in bytes) {
    out.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}
