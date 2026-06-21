import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../../core/parse_exception.dart';
import 'pdf_internals.dart';

/// PDF Standard Security Handler — decrypts strings and streams.
///
/// Supports the schemes a vault is realistically asked to read: RC4 (V1/V2,
/// R2/R3), AESV2 (128-bit, R4), and AESV3 (256-bit, R5/R6), each with an empty
/// user password (the common "encrypted but openable" case). The empty password
/// is validated against `/U`; if it does not open the document a
/// [UnsupportedFeatureException] is thrown rather than returning garbled text.
class PdfSecurityHandler {
  PdfSecurityHandler._(this._fileKey, this._stm, this._str, this._keyLen);

  final Uint8List _fileKey;
  final _Method _stm;
  final _Method _str;
  final int _keyLen;

  /// Human-readable scheme label for metadata.
  final String label = '';

  static const List<int> _pad = [
    0x28,
    0xBF,
    0x4E,
    0x5E,
    0x4E,
    0x75,
    0x8A,
    0x41,
    0x64,
    0x00,
    0x4E,
    0x56,
    0xFF,
    0xFA,
    0x01,
    0x08,
    0x2E,
    0x2E,
    0x00,
    0xB6,
    0xD0,
    0x68,
    0x3E,
    0x80,
    0x2F,
    0x0C,
    0xA9,
    0xFE,
    0x64,
    0x53,
    0x69,
    0x7A,
  ];

  /// Builds a handler from the `/Encrypt` dictionary and the document `/ID`.
  /// Returns `null` if encryption is the `Identity` no-op.
  static ({PdfSecurityHandler? handler, String label}) build(
    PdfDict enc,
    Uint8List? id,
    PdfObject? Function(PdfObject?) res,
  ) {
    final filter = res(enc['Filter']);
    if (filter is! PdfName || filter.name != 'Standard') {
      throw const UnsupportedFeatureException(
        'unsupported PDF security handler (only Standard is implemented)',
      );
    }
    final v = _int(res(enc['V'])) ?? 0;
    final r = _int(res(enc['R'])) ?? 0;
    final length = _int(res(enc['Length'])) ?? 40;
    final o = _bytes(res(enc['O']));
    final u = _bytes(res(enc['U']));
    final p = _int(res(enc['P'])) ?? 0;
    final encMeta = _boolOf(res(enc['EncryptMetadata'])) ?? true;

    _Method stm, str;
    if (v >= 4) {
      final cf = res(enc['CF']);
      _Method methodFor(PdfObject? name) {
        if (name is! PdfName || name.name == 'Identity') {
          return _Method.identity;
        }
        final fd = cf is PdfDict ? res(cf[name.name]) : null;
        final cfm = fd is PdfDict ? res(fd['CFM']) : null;
        if (cfm is PdfName) {
          return switch (cfm.name) {
            'V2' => _Method.rc4,
            'AESV2' => _Method.aesV2,
            'AESV3' => _Method.aesV3,
            _ => _Method.identity,
          };
        }
        return _Method.identity;
      }

      stm = methodFor(res(enc['StmF']));
      str = methodFor(res(enc['StrF']));
    } else {
      stm = _Method.rc4;
      str = _Method.rc4;
    }

    final keyLen = v >= 5 ? 32 : (r == 2 ? 5 : length ~/ 8);

    final Uint8List fileKey;
    final String label;
    if (v >= 5) {
      fileKey = _keyV5(u, _bytes(res(enc['UE'])), r);
      label = 'AES-256 (R$r)';
    } else {
      fileKey = _keyV2(o, p, id ?? Uint8List(0), r, keyLen, encMeta);
      // Validate the empty user password against /U; fail closed on mismatch.
      if (!_validateUserV2(fileKey, id ?? Uint8List(0), u, r, keyLen)) {
        throw const UnsupportedFeatureException(
          'password-protected PDF: a non-empty user password is required',
        );
      }
      final method = stm == _Method.aesV2 ? 'AES-128' : 'RC4-${keyLen * 8}';
      label = '$method (R$r)';
    }

    return (
      handler: PdfSecurityHandler._(fileKey, stm, str, keyLen),
      label: label,
    );
  }

  /// Decrypts every encrypted string and stream within [obj], using its object
  /// number/generation. Cross-reference streams are never encrypted and are
  /// returned untouched.
  PdfObject decryptObject(PdfObject obj, int num, int gen) {
    if (obj is PdfString) return PdfString(_decrypt(obj.bytes, num, gen, _str));
    if (obj is PdfArray) {
      return PdfArray([for (final e in obj.items) decryptObject(e, num, gen)]);
    }
    if (obj is PdfDict) {
      return PdfDict({
        for (final e in obj.entries.entries)
          e.key: decryptObject(e.value, num, gen),
      });
    }
    if (obj is PdfStream) {
      final dict = PdfDict({
        for (final e in obj.dict.entries.entries)
          e.key: decryptObject(e.value, num, gen),
      });
      final type = obj.dict['Type'];
      if (type is PdfName && type.name == 'XRef') {
        return PdfStream(dict, obj.raw);
      }
      return PdfStream(dict, _decrypt(obj.raw, num, gen, _stm));
    }
    return obj;
  }

  Uint8List _decrypt(Uint8List data, int num, int gen, _Method method) {
    switch (method) {
      case _Method.identity:
        return data;
      case _Method.aesV3:
        return _aesObject(_fileKey, data);
      case _Method.aesV2:
        return _aesObject(_objectKey(num, gen, aes: true), data);
      case _Method.rc4:
        return _rc4(_objectKey(num, gen, aes: false), data);
    }
  }

  Uint8List _objectKey(int num, int gen, {required bool aes}) {
    final b = BytesBuilder()
      ..add(_fileKey)
      ..add([num & 0xFF, (num >> 8) & 0xFF, (num >> 16) & 0xFF])
      ..add([gen & 0xFF, (gen >> 8) & 0xFF]);
    if (aes) b.add(const [0x73, 0x41, 0x6C, 0x54]); // "sAlT"
    final hash = MD5Digest().process(b.toBytes());
    final n = (_keyLen + 5).clamp(0, 16);
    return Uint8List.sublistView(hash, 0, n);
  }

  // --- key derivation --------------------------------------------------------

  static Uint8List _keyV2(
    Uint8List o,
    int p,
    Uint8List id,
    int r,
    int keyLen,
    bool encMeta,
  ) {
    final input = BytesBuilder()
      ..add(Uint8List.fromList(_pad)) // empty password padded == the pad
      ..add(_fixed(o, 32))
      ..add(_int32le(p))
      ..add(id);
    if (r >= 4 && !encMeta) input.add(const [0xFF, 0xFF, 0xFF, 0xFF]);
    var hash = MD5Digest().process(input.toBytes());
    if (r >= 3) {
      for (var i = 0; i < 50; i++) {
        hash = MD5Digest().process(Uint8List.sublistView(hash, 0, keyLen));
      }
    }
    return Uint8List.sublistView(hash, 0, keyLen);
  }

  static bool _validateUserV2(
    Uint8List key,
    Uint8List id,
    Uint8List u,
    int r,
    int keyLen,
  ) {
    if (r == 2) {
      final uPrime = _rc4Static(key, Uint8List.fromList(_pad));
      return _eq(uPrime, _fixed(u, 32), 32);
    }
    // R3+: Algorithm 5.
    var data = MD5Digest().process(
      (BytesBuilder()
            ..add(Uint8List.fromList(_pad))
            ..add(id))
          .toBytes(),
    );
    data = _rc4Static(key, data);
    for (var i = 1; i <= 19; i++) {
      final k = Uint8List.fromList(key.map((b) => b ^ i).toList());
      data = _rc4Static(k, data);
    }
    return _eq(data, Uint8List.sublistView(u, 0, 16), 16);
  }

  static Uint8List _keyV5(Uint8List u, Uint8List ue, int r) {
    final valSalt = Uint8List.sublistView(u, 32, 40);
    final keySalt = Uint8List.sublistView(u, 40, 48);
    const pw = <int>[];
    // Validate empty user password against the stored hash.
    final check = _hashV5(Uint8List.fromList(pw), valSalt, Uint8List(0), r);
    if (!_eq(check, Uint8List.sublistView(u, 0, 32), 32)) {
      throw const UnsupportedFeatureException(
        'password-protected PDF: a non-empty user password is required',
      );
    }
    final intermediate = _hashV5(
      Uint8List.fromList(pw),
      keySalt,
      Uint8List(0),
      r,
    );
    return _aesCbc(intermediate, Uint8List(16), ue, forEncryption: false);
  }

  /// SHA-256 (R5) or the iterative Algorithm 2.B (R6) hash.
  static Uint8List _hashV5(
    Uint8List pw,
    Uint8List salt,
    Uint8List udata,
    int r,
  ) {
    var k = SHA256Digest().process(_concat([pw, salt, udata]));
    if (r < 6) return k;
    var round = 0;
    while (true) {
      final k1 = _repeat(_concat([pw, k, udata]), 64);
      final e = _aesCbc(
        Uint8List.sublistView(k, 0, 16),
        Uint8List.sublistView(k, 16, 32),
        k1,
        forEncryption: true,
      );
      var sum = 0;
      for (var i = 0; i < 16; i++) {
        sum += e[i];
      }
      k = switch (sum % 3) {
        0 => SHA256Digest().process(e),
        1 => SHA384Digest().process(e),
        _ => SHA512Digest().process(e),
      };
      round++;
      if (round >= 64 && e[e.length - 1] <= round - 32) break;
    }
    return Uint8List.sublistView(k, 0, 32);
  }

  // --- primitives ------------------------------------------------------------

  static Uint8List _aesObject(Uint8List key, Uint8List data) {
    if (data.length < 16) return Uint8List(0);
    final iv = Uint8List.sublistView(data, 0, 16);
    final ct = Uint8List.sublistView(data, 16);
    final dec = _aesCbc(key, iv, ct, forEncryption: false);
    return _stripPkcs7(dec);
  }

  static Uint8List _aesCbc(
    Uint8List key,
    Uint8List iv,
    Uint8List data, {
    required bool forEncryption,
  }) {
    final cipher = CBCBlockCipher(AESEngine())
      ..init(forEncryption, ParametersWithIV(KeyParameter(key), iv));
    final aligned = data.length - (data.length % cipher.blockSize);
    final out = Uint8List(aligned);
    var off = 0;
    while (off + cipher.blockSize <= aligned) {
      cipher.processBlock(data, off, out, off);
      off += cipher.blockSize;
    }
    return out;
  }

  Uint8List _rc4(Uint8List key, Uint8List data) => _rc4Static(key, data);

  static Uint8List _rc4Static(Uint8List key, Uint8List data) {
    final engine = RC4Engine()..init(false, KeyParameter(key));
    final out = Uint8List(data.length);
    engine.processBytes(data, 0, data.length, out, 0);
    return out;
  }

  static Uint8List _stripPkcs7(Uint8List d) {
    if (d.isEmpty) return d;
    final pad = d.last;
    if (pad < 1 || pad > 16 || pad > d.length) return d;
    return Uint8List.sublistView(d, 0, d.length - pad);
  }

  // --- helpers ---------------------------------------------------------------

  static int? _int(PdfObject? o) => o is PdfNumber ? o.value.toInt() : null;
  static bool? _boolOf(PdfObject? o) => o is PdfBool ? o.value : null;
  static Uint8List _bytes(PdfObject? o) =>
      o is PdfString ? o.bytes : Uint8List(0);

  static Uint8List _fixed(Uint8List src, int len) {
    final out = Uint8List(len);
    out.setRange(0, src.length < len ? src.length : len, src);
    return out;
  }

  static Uint8List _int32le(int v) =>
      Uint8List(4)..buffer.asByteData().setInt32(0, v, Endian.little);

  static Uint8List _concat(List<List<int>> parts) {
    final b = BytesBuilder();
    for (final p in parts) {
      b.add(p);
    }
    return b.toBytes();
  }

  static Uint8List _repeat(Uint8List src, int times) {
    final b = BytesBuilder();
    for (var i = 0; i < times; i++) {
      b.add(src);
    }
    return b.toBytes();
  }

  static bool _eq(Uint8List a, Uint8List b, int n) {
    if (a.length < n || b.length < n) return false;
    for (var i = 0; i < n; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

enum _Method { rc4, aesV2, aesV3, identity }
