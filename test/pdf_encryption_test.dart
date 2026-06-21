import 'dart:typed_data';

import 'dart:io';

import 'package:panthalassa_parsers/panthalassa_parsers.dart';
import 'package:test/test.dart';

/// Ground-truth fixtures generated with qpdf 11 (empty user password). Each
/// validates the full key-derivation + per-object decryption path end to end,
/// including decryption of the /Info metadata strings.
void main() {
  final registry = ParserRegistry.standard();

  Uint8List read(String name) => File('test/fixtures/$name').readAsBytesSync();

  void expectDecrypts(String fixture, String scheme) {
    final r = registry.parse(read(fixture));
    expect(r.format, DocumentFormat.pdf, reason: fixture);
    expect(r.metadata['encrypted'], true, reason: fixture);
    expect(r.metadata['encryption'], scheme, reason: fixture);
    expect(r.text, contains('Encrypted Vault Document 4609'), reason: fixture);
    // /Info strings are encrypted too, and must decrypt.
    expect(r.metadata['title'], 'Panthalassa Encrypted', reason: fixture);
    expect(r.metadata['author'], 'Turkana Nation', reason: fixture);
  }

  test(
    'RC4-40 (R2) decrypts',
    () => expectDecrypts('enc_rc4_40.pdf', 'RC4-40 (R2)'),
  );
  test(
    'RC4-128 (R3) decrypts',
    () => expectDecrypts('enc_rc4_128.pdf', 'RC4-128 (R3)'),
  );
  test(
    'AES-128 (R4) decrypts',
    () => expectDecrypts('enc_aes_128.pdf', 'AES-128 (R4)'),
  );
  test(
    'AES-256 (R6) decrypts',
    () => expectDecrypts('enc_aes_256.pdf', 'AES-256 (R6)'),
  );

  test('permission flags are surfaced from the encrypted document', () {
    final r = registry.parse(read('enc_aes_256.pdf'));
    final perms = r.metadata['permissions'] as Map?;
    expect(perms, isNotNull);
    // qpdf was run with all permissions allowed.
    expect(perms!['print'], true);
    expect(perms['copy'], true);
  });
}
