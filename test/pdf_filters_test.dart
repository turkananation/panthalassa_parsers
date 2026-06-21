import 'dart:convert';
import 'dart:typed_data';

import 'package:panthalassa_parsers/src/parsers/pdf/pdf_filters.dart';
import 'package:test/test.dart';

void main() {
  group('PDF stream filters', () {
    test('ASCIIHexDecode decodes pairs up to >', () {
      final out = asciiHexDecode(Uint8List.fromList(ascii.encode('48656C6C6F>')));
      expect(ascii.decode(out), 'Hello');
    });

    test('ASCIIHexDecode tolerates whitespace and pads an odd nibble', () {
      final out =
          asciiHexDecode(Uint8List.fromList(ascii.encode('48 65 6C 6C 6F 4>')));
      expect(ascii.decode(out), 'Hello@'); // trailing 4 -> 0x40
    });

    test('RunLengthDecode handles literal runs and repeat runs', () {
      // literal "ABCD" (len 3), repeat 'X' x5 (len 252 = 257-5), EOD (128).
      final data = Uint8List.fromList([3, 0x41, 0x42, 0x43, 0x44, 252, 0x58, 128]);
      expect(ascii.decode(runLengthDecode(data)), 'ABCDXXXXX');
    });

    test('ASCII85Decode round-trips a reference encoding', () {
      final input = Uint8List.fromList(utf8.encode('Panthalassa Vault 4609!'));
      expect(ascii85Decode(_ascii85Encode(input)), input);
    });

    test('ASCII85Decode expands the z zero-group shorthand', () {
      // 'z' -> four zero bytes, then '~>' EOD.
      final out = ascii85Decode(Uint8List.fromList([0x7A, 0x7E, 0x3E]));
      expect(out, Uint8List.fromList([0, 0, 0, 0]));
    });

    test('LZWDecode round-trips a reference encoding (9-bit width)', () {
      final input = Uint8List.fromList(
        utf8.encode('TOBEORNOTTOBEORTOBEORNOT-TOBEORNOTTOBE'),
      );
      expect(lzwDecode(_lzwEncode(input)), input);
    });
  });

  group('PDF predictors', () {
    test('PNG Up predictor reverses across rows', () {
      // rows [10,20,30] then [11,22,33]; Up filter (type 2) on each.
      final encoded = Uint8List.fromList([2, 10, 20, 30, 2, 1, 2, 3]);
      final decoded = applyPredictor(encoded, 12, 1, 8, 3);
      expect(decoded, Uint8List.fromList([10, 20, 30, 11, 22, 33]));
    });

    test('TIFF predictor 2 reverses horizontal differencing', () {
      // one row, 4 bytes, deltas [100,1,1,1] -> [100,101,102,103].
      final decoded = applyPredictor(Uint8List.fromList([100, 1, 1, 1]), 2, 1, 8, 4);
      expect(decoded, Uint8List.fromList([100, 101, 102, 103]));
    });
  });
}

// --- reference encoders (test-only) -----------------------------------------

Uint8List _ascii85Encode(Uint8List data) {
  final out = <int>[];
  var i = 0;
  while (i + 4 <= data.length) {
    var t = ((data[i] << 24) | (data[i + 1] << 16) | (data[i + 2] << 8) | data[i + 3]) &
        0xFFFFFFFF;
    if (t == 0) {
      out.add(0x7A);
    } else {
      final g = <int>[];
      for (var k = 0; k < 5; k++) {
        g.add(t % 85 + 33);
        t = t ~/ 85;
      }
      out.addAll(g.reversed);
    }
    i += 4;
  }
  final rem = data.length - i;
  if (rem > 0) {
    var t = 0;
    for (var k = 0; k < 4; k++) {
      t = (t << 8) | (k < rem ? data[i + k] : 0);
    }
    final g = <int>[];
    for (var k = 0; k < 5; k++) {
      g.add(t % 85 + 33);
      t = t ~/ 85;
    }
    out.addAll(g.reversed.take(rem + 1));
  }
  out..add(0x7E)..add(0x3E); // ~>
  return Uint8List.fromList(out);
}

Uint8List _lzwEncode(Uint8List data) {
  const clear = 256, eod = 257;
  final out = <int>[];
  var buf = 0, bits = 0, width = 9;
  void emit(int code) {
    buf = (buf << width) | code;
    bits += width;
    while (bits >= 8) {
      bits -= 8;
      out.add((buf >> bits) & 0xFF);
    }
  }

  final dict = <String, int>{for (var i = 0; i < 256; i++) String.fromCharCode(i): i};
  var next = 258;
  emit(clear);
  var w = '';
  for (final b in data) {
    final c = String.fromCharCode(b);
    final wc = w + c;
    if (dict.containsKey(wc)) {
      w = wc;
    } else {
      emit(dict[w]!);
      if (next < 4096) dict[wc] = next++;
      if (next + 1 > (1 << width) && width < 12) width++;
      w = c;
    }
  }
  if (w.isNotEmpty) emit(dict[w]!);
  emit(eod);
  if (bits > 0) out.add((buf << (8 - bits)) & 0xFF);
  return Uint8List.fromList(out);
}
