import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../core/parse_exception.dart';

/// PDF stream filter decoders and predictors.
///
/// Pure Dart, no `dart:io`. Covers the filters that appear in text-bearing and
/// structural PDF streams: FlateDecode, LZWDecode, ASCII85Decode,
/// ASCIIHexDecode, RunLengthDecode, plus the PNG/TIFF predictors used by
/// cross-reference and object streams. Image-only filters (DCTDecode,
/// JPXDecode, CCITTFaxDecode, JBIG2Decode) are passed through untouched.

/// Inflates a FlateDecode stream (zlib wrapper; falls back to raw deflate).
Uint8List inflate(Uint8List data) {
  try {
    return Uint8List.fromList(
      const ZLibDecoder().decodeBytes(data, verify: false),
    );
  } catch (_) {
    try {
      return Uint8List.fromList(Inflate(data).getBytes());
    } catch (e) {
      throw MalformedDocumentException('FlateDecode failed: $e');
    }
  }
}

/// Applies a filter chain to [data]. [parms] is aligned with [filters]; a null
/// entry means no DecodeParms for that filter.
Uint8List decodeStream(
  Uint8List data,
  List<String> filters,
  List<Map<String, int>?> parms,
) {
  var out = data;
  for (var i = 0; i < filters.length; i++) {
    final p = i < parms.length ? parms[i] : null;
    switch (filters[i]) {
      case 'FlateDecode' || 'Fl':
        out = _predict(inflate(out), p);
      case 'LZWDecode' || 'LZW':
        out = _predict(lzwDecode(out, earlyChange: p?['EarlyChange'] ?? 1), p);
      case 'ASCIIHexDecode' || 'AHx':
        out = asciiHexDecode(out);
      case 'ASCII85Decode' || 'A85':
        out = ascii85Decode(out);
      case 'RunLengthDecode' || 'RL':
        out = runLengthDecode(out);
      default:
        break; // image/unsupported filter: leave bytes as-is
    }
  }
  return out;
}

Uint8List _predict(Uint8List data, Map<String, int>? p) {
  final predictor = p?['Predictor'] ?? 1;
  if (predictor < 2) return data;
  return applyPredictor(
    data,
    predictor,
    p?['Colors'] ?? 1,
    p?['BitsPerComponent'] ?? 8,
    p?['Columns'] ?? 1,
  );
}

/// ASCIIHexDecode: pairs of hex digits up to the `>` terminator.
Uint8List asciiHexDecode(Uint8List data) {
  final hex = StringBuffer();
  for (final c in data) {
    if (c == 0x3E) break; // '>'
    if ((c >= 0x30 && c <= 0x39) ||
        (c >= 0x41 && c <= 0x46) ||
        (c >= 0x61 && c <= 0x66)) {
      hex.writeCharCode(c);
    }
  }
  var h = hex.toString();
  if (h.length.isOdd) h += '0';
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// ASCII85Decode: base-85, 5 chars → 4 bytes, `z` → 4 zero bytes, `~>` EOD.
Uint8List ascii85Decode(Uint8List data) {
  final out = BytesBuilder();
  var tuple = 0;
  var count = 0;
  var i = 0;
  if (data.length >= 2 && data[0] == 0x3C && data[1] == 0x7E) i = 2; // '<~'
  while (i < data.length) {
    final c = data[i++];
    if (c == 0x7E) break; // '~' → '~>' EOD
    if (c == 0x20 ||
        c == 0x0A ||
        c == 0x0D ||
        c == 0x09 ||
        c == 0x00 ||
        c == 0x0C) {
      continue;
    }
    if (c == 0x7A && count == 0) {
      out
        ..addByte(0)
        ..addByte(0)
        ..addByte(0)
        ..addByte(0); // 'z'
      continue;
    }
    if (c < 0x21 || c > 0x75) continue;
    tuple = tuple * 85 + (c - 0x21);
    if (++count == 5) {
      out
        ..addByte((tuple >> 24) & 0xFF)
        ..addByte((tuple >> 16) & 0xFF)
        ..addByte((tuple >> 8) & 0xFF)
        ..addByte(tuple & 0xFF);
      tuple = 0;
      count = 0;
    }
  }
  if (count > 0) {
    for (var k = count; k < 5; k++) {
      tuple = tuple * 85 + 84; // pad with 'u'
    }
    final all = [
      (tuple >> 24) & 0xFF,
      (tuple >> 16) & 0xFF,
      (tuple >> 8) & 0xFF,
      tuple & 0xFF,
    ];
    for (var k = 0; k < count - 1; k++) {
      out.addByte(all[k]);
    }
  }
  return out.toBytes();
}

/// RunLengthDecode per PDF 7.4.5.
Uint8List runLengthDecode(Uint8List data) {
  final out = BytesBuilder();
  var i = 0;
  while (i < data.length) {
    final len = data[i++];
    if (len == 128) break; // EOD
    if (len < 128) {
      final n = len + 1;
      for (var k = 0; k < n && i < data.length; k++) {
        out.addByte(data[i++]);
      }
    } else {
      final n = 257 - len;
      if (i < data.length) {
        final b = data[i++];
        for (var k = 0; k < n; k++) {
          out.addByte(b);
        }
      }
    }
  }
  return out.toBytes();
}

/// Variable-width (9–12 bit) LZWDecode with PDF EarlyChange semantics.
Uint8List lzwDecode(Uint8List data, {int earlyChange = 1}) {
  const clearCode = 256;
  const eodCode = 257;
  final out = BytesBuilder();

  late List<List<int>> table;
  void reset() {
    table = [
      for (var i = 0; i < 256; i++) [i],
      <int>[],
      <int>[],
    ];
  }

  reset();
  var codeWidth = 9;
  var bitBuffer = 0;
  var bitCount = 0;
  var pos = 0;
  List<int>? prev;

  int? nextCode() {
    while (bitCount < codeWidth) {
      if (pos >= data.length) return null;
      bitBuffer = (bitBuffer << 8) | data[pos++];
      bitCount += 8;
    }
    bitCount -= codeWidth;
    return (bitBuffer >> bitCount) & ((1 << codeWidth) - 1);
  }

  while (true) {
    final code = nextCode();
    if (code == null || code == eodCode) break;
    if (code == clearCode) {
      reset();
      codeWidth = 9;
      prev = null;
      continue;
    }
    final List<int> entry;
    if (code < table.length) {
      entry = table[code];
    } else if (code == table.length && prev != null) {
      entry = [...prev, prev.first];
    } else {
      break; // corrupt stream
    }
    out.add(entry);
    if (prev != null) {
      table.add([...prev, entry.first]);
    }
    prev = entry;
    if (table.length + earlyChange >= (1 << codeWidth) && codeWidth < 12) {
      codeWidth++;
    }
  }
  return out.toBytes();
}

/// Reverses a PNG (predictor ≥ 10) or TIFF (predictor 2) predictor.
Uint8List applyPredictor(
  Uint8List data,
  int predictor,
  int colors,
  int bitsPerComponent,
  int columns,
) {
  if (predictor < 2) return data;
  final bytesPerPixel = ((colors * bitsPerComponent + 7) ~/ 8).clamp(
    1,
    1 << 24,
  );
  final rowBytes = (colors * bitsPerComponent * columns + 7) ~/ 8;
  if (rowBytes <= 0) return data;

  if (predictor == 2) {
    if (bitsPerComponent != 8) {
      return data; // sub-byte TIFF prediction unsupported
    }
    final out = Uint8List.fromList(data);
    final rows = out.length ~/ rowBytes;
    for (var r = 0; r < rows; r++) {
      final base = r * rowBytes;
      for (var j = bytesPerPixel; j < rowBytes; j++) {
        out[base + j] = (out[base + j] + out[base + j - bytesPerPixel]) & 0xFF;
      }
    }
    return out;
  }

  // PNG predictors: each row is prefixed by a filter-type byte.
  final out = BytesBuilder();
  final prev = Uint8List(rowBytes);
  var pos = 0;
  while (pos + 1 + rowBytes <= data.length) {
    final filterType = data[pos++];
    final row = Uint8List.fromList(
      Uint8List.sublistView(data, pos, pos + rowBytes),
    );
    pos += rowBytes;
    for (var j = 0; j < rowBytes; j++) {
      final a = j >= bytesPerPixel ? row[j - bytesPerPixel] : 0;
      final b = prev[j];
      final c = j >= bytesPerPixel ? prev[j - bytesPerPixel] : 0;
      final int x;
      switch (filterType) {
        case 1:
          x = row[j] + a;
        case 2:
          x = row[j] + b;
        case 3:
          x = row[j] + ((a + b) >> 1);
        case 4:
          x = row[j] + _paeth(a, b, c);
        default:
          x = row[j];
      }
      row[j] = x & 0xFF;
    }
    out.add(row);
    for (var j = 0; j < rowBytes; j++) {
      prev[j] = row[j];
    }
  }
  return out.toBytes();
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}
