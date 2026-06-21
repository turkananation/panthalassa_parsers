import 'dart:convert';
import 'dart:typed_data';

import 'parse_exception.dart';

/// A bounds-checked, endian-aware cursor over a byte buffer.
///
/// Every read validates that the requested span lies within the buffer and
/// throws [TruncatedDocumentException] otherwise, so binary parsers can never
/// read past the end of a malformed or truncated file. This replaces the
/// unchecked indexing in the original spec's binary parsers.
final class ByteReader {
  ByteReader(this.bytes, {this.endian = Endian.big})
      : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData _view;
  Endian endian;
  int _pos = 0;

  int get position => _pos;
  int get length => bytes.length;
  int get remaining => bytes.length - _pos;
  bool get isAtEnd => _pos >= bytes.length;

  // `endian` is a mutable field: DICOM transfer syntaxes and some NITF/STANAG
  // fields require switching byte order mid-stream.

  void _require(int count) {
    if (_pos + count > bytes.length) {
      throw TruncatedDocumentException(
        'needed $count byte(s) but only $remaining remain',
        offset: _pos,
      );
    }
  }

  void seek(int absolute) {
    if (absolute < 0 || absolute > bytes.length) {
      throw MalformedDocumentException('seek out of range: $absolute');
    }
    _pos = absolute;
  }

  void skip(int count) {
    _require(count);
    _pos += count;
  }

  int readUint8() {
    _require(1);
    return bytes[_pos++];
  }

  int readUint16() {
    _require(2);
    final v = _view.getUint16(_pos, endian);
    _pos += 2;
    return v;
  }

  int readUint32() {
    _require(4);
    final v = _view.getUint32(_pos, endian);
    _pos += 4;
    return v;
  }

  int readInt32() {
    _require(4);
    final v = _view.getInt32(_pos, endian);
    _pos += 4;
    return v;
  }

  Uint8List readBytes(int count) {
    _require(count);
    final out = Uint8List.sublistView(bytes, _pos, _pos + count);
    _pos += count;
    return out;
  }

  /// Reads [count] bytes as fixed-width ASCII, trimming trailing spaces and
  /// NULs (the padding convention in NITF and DICOM string VRs).
  String readAsciiFixed(int count) {
    final raw = readBytes(count);
    return ascii.decode(raw, allowInvalid: true).replaceAll(
          RegExp(r'[\x00 ]+$'),
          '',
        );
  }

  int peekUint8() {
    _require(1);
    return bytes[_pos];
  }
}
