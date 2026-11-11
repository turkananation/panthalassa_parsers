import 'dart:convert';
import 'dart:typed_data';

import 'package:swissarmyknife/swissarmyknife.dart';

/// ZIP local-file-header magic (`PK\x03\x04`).
const List<int> zipLocalFileHeaderMagic = [0x50, 0x4B, 0x03, 0x04];

/// ZIP end-of-central-directory magic (`PK\x05\x06`).
const List<int> zipEndOfCentralDirectoryMagic = [0x50, 0x4B, 0x05, 0x06];

/// True when [bytes] starts with a ZIP local-file header.
///
/// This is intentionally a prefix check: callers combine it with member-name
/// inspection before claiming a container format.
bool hasZipMagic(Uint8List bytes) =>
    bytes.length >= zipLocalFileHeaderMagic.length &&
    bytes.indexOfSublist(zipLocalFileHeaderMagic) == 0;

/// Returns the archive's central-directory entry names, lower-cased, or `null`
/// when the directory cannot be located safely.
///
/// Central-directory names are stored verbatim (uncompressed), so this is the
/// reliable way to recognise OOXML/EPUB/ODF containers whose local headers may
/// be reordered, compressed, or absent from the first few hundred bytes.
/// [maxCentralDirectoryBytes] bounds the work done during detection.
String? zipEntryNames(
  Uint8List bytes, {
  int maxCentralDirectoryBytes = 8 * 1024 * 1024,
}) {
  if (!hasZipMagic(bytes) || bytes.length < 22) return null;

  final searchStart = bytes.length > 65557 ? bytes.length - 65557 : 0;
  int? eocd;
  for (var i = bytes.length - 4; i >= searchStart; i--) {
    if (bytes[i] == 0x50 &&
        bytes[i + 1] == 0x4B &&
        bytes[i + 2] == 0x05 &&
        bytes[i + 3] == 0x06) {
      eocd = i;
      break;
    }
  }
  if (eocd == null || eocd + 22 > bytes.length) return null;

  final centralSize = _uint32le(bytes, eocd + 12);
  final centralOffset = _uint32le(bytes, eocd + 16);
  if (centralSize == 0 ||
      centralSize > maxCentralDirectoryBytes ||
      centralOffset >= bytes.length ||
      centralOffset + centralSize > bytes.length) {
    return null;
  }

  return latin1
      .decode(
        Uint8List.sublistView(
          bytes,
          centralOffset,
          centralOffset + centralSize,
        ),
        allowInvalid: true,
      )
      .toLowerCase();
}

int _uint32le(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);
