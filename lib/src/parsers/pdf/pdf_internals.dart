import 'dart:convert';
import 'dart:typed_data';

import '../../core/parse_exception.dart';
import 'pdf_crypt.dart';
import 'pdf_filters.dart';

/// Minimal PDF object model and a robust, dependency-light reader sufficient for
/// text extraction from real-world PDFs, including modern ones.
///
/// Strategy: rather than depend on a well-formed classic cross-reference table
/// (frequently damaged in real files), the reader brute-force indexes every
/// top-level `N G obj … endobj`, then (a) recovers the trailer `/Root` from a
/// cross-reference stream when no `trailer` keyword is present, and (b) expands
/// compressed object streams (`/ObjStm`) so objects packed inside them are
/// indexed. It then resolves references and walks the page tree. Remaining gaps
/// (tracked as tickets): encryption, CID fonts lacking `/ToUnicode`, and
/// image-only stream filters (DCT/JPX/CCITT/JBIG2).

sealed class PdfObject {
  const PdfObject();
}

final class PdfNull extends PdfObject {
  const PdfNull();
}

final class PdfBool extends PdfObject {
  const PdfBool(this.value);
  final bool value;
}

final class PdfNumber extends PdfObject {
  const PdfNumber(this.value);
  final num value;
}

final class PdfString extends PdfObject {
  const PdfString(this.bytes);
  final Uint8List bytes;
  String get latin1Value => latin1.decode(bytes, allowInvalid: true);
}

final class PdfName extends PdfObject {
  const PdfName(this.name);
  final String name;
}

final class PdfArray extends PdfObject {
  const PdfArray(this.items);
  final List<PdfObject> items;
}

final class PdfDict extends PdfObject {
  const PdfDict(this.entries);
  final Map<String, PdfObject> entries;
  PdfObject? operator [](String key) => entries[key];
}

final class PdfRef extends PdfObject {
  const PdfRef(this.number, this.generation);
  final int number;
  final int generation;
}

final class PdfStream extends PdfObject {
  const PdfStream(this.dict, this.raw);
  final PdfDict dict;
  final Uint8List raw;
}

/// Parses a single PDF object value from a string slice using recursive descent.
/// Operates on a Latin-1 view of the bytes so that string offsets equal byte
/// offsets (Latin-1 is a total bijection over 0–255).
class _ValueParser {
  _ValueParser(this.src, this.pos);
  final String src;
  int pos;

  static const _ws = {' ', '\t', '\r', '\n', '\x00', '\f'};
  static const _delim = {'(', ')', '<', '>', '[', ']', '{', '}', '/', '%'};

  void _skipWs() {
    while (pos < src.length) {
      final c = src[pos];
      if (_ws.contains(c)) {
        pos++;
      } else if (c == '%') {
        while (pos < src.length && src[pos] != '\n' && src[pos] != '\r') {
          pos++;
        }
      } else {
        break;
      }
    }
  }

  PdfObject parseValue() {
    _skipWs();
    if (pos >= src.length) return const PdfNull();
    final c = src[pos];
    switch (c) {
      case '/':
        return _parseName();
      case '(':
        return _parseLiteralString();
      case '[':
        return _parseArray();
      case '<':
        if (pos + 1 < src.length && src[pos + 1] == '<') return _parseDict();
        return _parseHexString();
      default:
        if (c == '+' || c == '-' || c == '.' || _isDigit(c)) {
          return _parseNumberOrRef();
        }
        return _parseKeyword();
    }
  }

  PdfName _parseName() {
    pos++; // '/'
    final b = StringBuffer();
    while (pos < src.length) {
      final c = src[pos];
      if (_ws.contains(c) || _delim.contains(c)) break;
      if (c == '#' && pos + 2 < src.length) {
        final hex = src.substring(pos + 1, pos + 3);
        final code = int.tryParse(hex, radix: 16);
        if (code != null) {
          b.writeCharCode(code);
          pos += 3;
          continue;
        }
      }
      b.write(c);
      pos++;
    }
    return PdfName(b.toString());
  }

  PdfString _parseLiteralString() {
    pos++; // '('
    final out = <int>[];
    var depth = 1;
    while (pos < src.length) {
      final c = src[pos++];
      if (c == '\\') {
        if (pos >= src.length) break;
        final e = src[pos++];
        switch (e) {
          case 'n':
            out.add(0x0A);
          case 'r':
            out.add(0x0D);
          case 't':
            out.add(0x09);
          case 'b':
            out.add(0x08);
          case 'f':
            out.add(0x0C);
          case '(':
            out.add(0x28);
          case ')':
            out.add(0x29);
          case '\\':
            out.add(0x5C);
          case '\n':
            break; // line continuation
          case '\r':
            if (pos < src.length && src[pos] == '\n') pos++;
          default:
            if (_isOctal(e)) {
              var oct = e;
              for (
                var k = 0;
                k < 2 && pos < src.length && _isOctal(src[pos]);
                k++
              ) {
                oct += src[pos++];
              }
              out.add(int.parse(oct, radix: 8) & 0xFF);
            } else {
              out.add(e.codeUnitAt(0));
            }
        }
      } else if (c == '(') {
        depth++;
        out.add(0x28);
      } else if (c == ')') {
        depth--;
        if (depth == 0) break;
        out.add(0x29);
      } else {
        out.add(c.codeUnitAt(0));
      }
    }
    return PdfString(Uint8List.fromList(out));
  }

  PdfString _parseHexString() {
    pos++; // '<'
    var value = 0;
    var nibbles = 0;
    final out = BytesBuilder();
    while (pos < src.length && src[pos] != '>') {
      final c = src[pos++];
      final int digit;
      if (c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39) {
        digit = c.codeUnitAt(0) - 0x30;
      } else if (c.codeUnitAt(0) >= 0x41 && c.codeUnitAt(0) <= 0x46) {
        digit = c.codeUnitAt(0) - 0x41 + 10;
      } else if (c.codeUnitAt(0) >= 0x61 && c.codeUnitAt(0) <= 0x66) {
        digit = c.codeUnitAt(0) - 0x61 + 10;
      } else {
        // Whitespace is legal inside a hex string; anything else is malformed.
        if (_ws.contains(c)) continue;
        throw MalformedDocumentException(
          'invalid hexadecimal digit in PDF string',
          offset: pos - 1,
        );
      }
      value = (value << 4) | digit;
      if (++nibbles == 2) {
        out.addByte(value);
        value = 0;
        nibbles = 0;
      }
    }
    if (pos < src.length) pos++; // '>'
    if (nibbles == 1) out.addByte(value << 4);
    return PdfString(out.toBytes());
  }

  PdfArray _parseArray() {
    pos++; // '['
    final items = <PdfObject>[];
    while (true) {
      _skipWs();
      if (pos >= src.length || src[pos] == ']') {
        if (pos < src.length) pos++;
        break;
      }
      items.add(parseValue());
    }
    return PdfArray(items);
  }

  PdfDict _parseDict() {
    pos += 2; // '<<'
    final entries = <String, PdfObject>{};
    while (true) {
      _skipWs();
      if (pos + 1 < src.length && src[pos] == '>' && src[pos + 1] == '>') {
        pos += 2;
        break;
      }
      if (pos >= src.length) break;
      if (src[pos] != '/') {
        pos++; // resync on malformed dict
        continue;
      }
      final key = _parseName().name;
      final value = parseValue();
      entries[key] = value;
    }
    return PdfDict(entries);
  }

  PdfObject _parseNumberOrRef() {
    final start = pos;
    final first = _readNumberToken();
    if (first is PdfNumber && first.value is int) {
      final save = pos;
      _skipWs();
      final maybeGen = _peekIntToken();
      if (maybeGen != null) {
        _skipWs();
        if (_peekKeyword('R')) {
          return PdfRef(first.value as int, maybeGen);
        }
      }
      pos = save;
    }
    if (first != null) return first;
    pos = start;
    return _parseKeyword();
  }

  PdfNumber? _readNumberToken() {
    final b = StringBuffer();
    var real = false;
    if (pos < src.length && (src[pos] == '+' || src[pos] == '-')) {
      b.write(src[pos++]);
    }
    while (pos < src.length) {
      final c = src[pos];
      if (_isDigit(c)) {
        b.write(c);
        pos++;
      } else if (c == '.') {
        real = true;
        b.write(c);
        pos++;
      } else {
        break;
      }
    }
    final s = b.toString();
    if (s.isEmpty || s == '+' || s == '-' || s == '.') return null;
    return real
        ? PdfNumber(double.tryParse(s) ?? 0)
        : PdfNumber(int.tryParse(s) ?? 0);
  }

  int? _peekIntToken() {
    final save = pos;
    final n = _readNumberToken();
    if (n != null && n.value is int) return n.value as int;
    pos = save;
    return null;
  }

  bool _peekKeyword(String kw) {
    final save = pos;
    final w = _readWord();
    if (w == kw) return true;
    pos = save;
    return false;
  }

  PdfObject _parseKeyword() {
    final w = _readWord();
    switch (w) {
      case 'true':
        return const PdfBool(true);
      case 'false':
        return const PdfBool(false);
      case 'null':
        return const PdfNull();
      default:
        return const PdfNull(); // unknown token: treat as null, keep parsing
    }
  }

  String _readWord() {
    final b = StringBuffer();
    while (pos < src.length) {
      final c = src[pos];
      if (_ws.contains(c) || _delim.contains(c)) break;
      b.write(c);
      pos++;
    }
    return b.toString();
  }

  static bool _isDigit(String c) =>
      c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;
  static bool _isOctal(String c) =>
      c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x37;
}

/// A parsed PDF document backed by a brute-force object index.
class PdfDocument {
  PdfDocument._(
    this.version,
    this._objects,
    this.trailer, {
    this.encryptionLabel,
    this.maxDecompressedEntryBytes = 64 * 1024 * 1024,
  });

  final String version;
  final Map<int, PdfObject> _objects;
  final PdfDict? trailer;

  /// Human-readable label of the encryption scheme if the document was
  /// encrypted (and successfully decrypted), else `null`.
  final String? encryptionLabel;

  /// Per-stream decompression ceiling, applied before an untrusted `/Length`
  /// or filter chain can force unbounded allocation.
  final int maxDecompressedEntryBytes;

  static final _objRe = RegExp(r'(\d+)\s+(\d+)\s+obj');
  static final _startXrefRe = RegExp(r'startxref\s+(\d+)');

  factory PdfDocument.parse(
    Uint8List bytes, {
    int maxDecompressedEntryBytes = 64 * 1024 * 1024,
  }) {
    final raw = latin1.decode(bytes, allowInvalid: true);

    final headerMatch = RegExp(r'%PDF-(\d+\.\d+)').firstMatch(raw);
    if (headerMatch == null) {
      throw const MalformedDocumentException('missing %PDF- header');
    }
    final version = headerMatch.group(1)!;

    final objects = <int, PdfObject>{};
    final generations = <int, int>{};
    // Linear scan. `coveredUntil` skips fake `N G obj` tokens embedded in
    // stream payloads; object bodies are parsed from bounded slices so a
    // hostile file cannot force quadratic re-scans of the whole buffer.
    var coveredUntil = 0;
    for (final m in _objRe.allMatches(raw)) {
      if (m.start < coveredUntil) continue;
      final number = int.parse(m.group(1)!);
      generations[number] = int.parse(m.group(2)!);
      final bodyStart = m.end;
      final roughEnd = raw.indexOf('endobj', bodyStart);
      if (roughEnd == -1) break; // truncated tail: nothing further is usable

      // A stream keyword must appear in the object header area, not deep in a
      // later object's payload. 64 KiB is far beyond any legal dictionary.
      final probeEnd = roughEnd < bodyStart + 65536
          ? roughEnd
          : bodyStart + 65536;
      final streamRel = raw.substring(bodyStart, probeEnd).indexOf('stream');
      if (streamRel != -1) {
        final streamIdx = bodyStart + streamRel;
        final dictText = raw.substring(bodyStart, streamIdx);
        PdfDict dict;
        try {
          final dictObj = _ValueParser(dictText, 0).parseValue();
          dict = dictObj is PdfDict ? dictObj : const PdfDict({});
        } catch (_) {
          dict = const PdfDict({});
        }

        // Data begins after 'stream' + EOL (CRLF or LF).
        var dataStart = streamIdx + 'stream'.length;
        if (dataStart < raw.length && raw[dataStart] == '\r') dataStart++;
        if (dataStart < raw.length && raw[dataStart] == '\n') dataStart++;

        // Prefer the declared /Length: literal `endstream` inside content is
        // otherwise indistinguishable from the real terminator.
        int? declared;
        final lengthObj = dict['Length'];
        if (lengthObj is PdfNumber) {
          declared = lengthObj.value.toInt();
        } else if (lengthObj is PdfRef) {
          final resolved = objects[lengthObj.number];
          if (resolved is PdfNumber) declared = resolved.value.toInt();
        }
        int dataEnd;
        if (declared != null &&
            declared >= 0 &&
            dataStart + declared <= raw.length) {
          final candidate = dataStart + declared;
          // Accept only when the terminator follows, allowing whitespace.
          var probe = candidate;
          while (probe < raw.length &&
              const {
                ' ',
                '\t',
                '\r',
                '\n',
                '\x00',
                '\f',
              }.contains(raw[probe])) {
            probe++;
          }
          if (raw.startsWith('endstream', probe)) {
            dataEnd = candidate;
          } else {
            dataEnd = _findEndstream(raw, dataStart);
          }
        } else {
          dataEnd = _findEndstream(raw, dataStart);
        }
        if (dataEnd < dataStart) dataEnd = dataStart;

        var sliceEnd = dataEnd;
        // Trim a single trailing EOL that precedes 'endstream'.
        if (sliceEnd > dataStart && raw[sliceEnd - 1] == '\n') sliceEnd--;
        if (sliceEnd > dataStart && raw[sliceEnd - 1] == '\r') sliceEnd--;
        final streamBytes = Uint8List.sublistView(bytes, dataStart, sliceEnd);
        objects[number] = PdfStream(dict, streamBytes); // later defs override

        final afterStream = raw.indexOf('endobj', dataEnd);
        coveredUntil = afterStream == -1 ? raw.length : afterStream + 6;
      } else {
        final objText = raw.substring(bodyStart, roughEnd);
        try {
          objects[number] = _ValueParser(objText, 0).parseValue();
        } catch (_) {
          // Skip a malformed object; a usable document may still have others.
        }
        coveredUntil = roughEnd + 6;
      }
    }

    // Prefer the trailer reached from the final `startxref`. Incremental
    // updates append newer xref sections, so the last trailer in file order is
    // not necessarily the authoritative one.
    var trailer = _readLatestTrailer(raw);

    // PDF 1.5+ files have no `trailer` keyword — the trailer dictionary is the
    // cross-reference stream's own dictionary. Recover `/Root` from it.
    if (trailer == null || trailer['Root'] == null) {
      trailer ??= _readLatestTrailer(raw) ?? _lastTrailerInFile(raw);
      for (final o in objects.values) {
        if (o is PdfStream &&
            _nameEquals(o.dict['Type'], 'XRef') &&
            o.dict['Root'] != null) {
          trailer = o.dict;
          break;
        }
      }
    }

    // Decrypt strings and streams before expanding object streams: an ObjStm's
    // own stream is decrypted here, after which its packed objects are plaintext
    // and need no further decryption.
    String? encryptionLabel;
    final encryptRef = trailer?['Encrypt'];
    if (encryptRef != null) {
      final encNum = encryptRef is PdfRef ? encryptRef.number : -1;
      final encDict = _resolveIn(encryptRef, objects);
      if (encDict is PdfDict) {
        final id = _firstIdBytes(trailer?['ID'], objects);
        final built = PdfSecurityHandler.build(
          encDict,
          id,
          (o) => _resolveIn(o, objects),
        );
        encryptionLabel = built.label;
        final handler = built.handler;
        if (handler != null) {
          for (final entry in objects.entries.toList(growable: false)) {
            if (entry.key == encNum) continue; // never decrypt the Encrypt dict
            objects[entry.key] = handler.decryptObject(
              entry.value,
              entry.key,
              generations[entry.key] ?? 0,
            );
          }
        }
      }
    }

    // Expand compressed object streams: their contained objects are not
    // top-level `obj` definitions, so the brute-force scan above misses them.
    for (final o in objects.values.toList(growable: false)) {
      if (o is PdfStream && _nameEquals(o.dict['Type'], 'ObjStm')) {
        _expandObjectStream(o, objects, maxDecompressedEntryBytes);
      }
    }

    return PdfDocument._(
      version,
      objects,
      trailer,
      encryptionLabel: encryptionLabel,
      maxDecompressedEntryBytes: maxDecompressedEntryBytes,
    );
  }

  /// Finds the first `endstream` token that is followed by a delimiter/EOL.
  ///
  /// Used only when `/Length` is absent or inconsistent. A literal `endstream`
  /// inside a content stream is normally preceded/followed by arbitrary text,
  /// so the delimiter check avoids most false positives without scanning twice.
  static int _findEndstream(String raw, int from) {
    var search = from;
    while (true) {
      final idx = raw.indexOf('endstream', search);
      if (idx == -1) return raw.length;
      var probe = idx + 'endstream'.length;
      while (probe < raw.length &&
          const {' ', '\t', '\r', '\n', '\x00', '\f'}.contains(raw[probe])) {
        probe++;
      }
      // The real terminator is followed only by whitespace before `endobj`.
      // A literal `endstream` inside content is followed by more content.
      if (probe >= raw.length || raw.startsWith('endobj', probe)) {
        return idx;
      }
      search = idx + 'endstream'.length;
    }
  }

  /// Reads the newest trailer dictionary by following the final `startxref`.
  static PdfDict? _readLatestTrailer(String raw) {
    final sx = raw.lastIndexOf('startxref');
    if (sx == -1) return _lastTrailerInFile(raw);
    final m = _startXrefRe.firstMatch(raw.substring(sx));
    if (m == null) return _lastTrailerInFile(raw);
    final offset = int.tryParse(m.group(1)!);
    if (offset == null || offset < 0 || offset >= raw.length) {
      return _lastTrailerInFile(raw);
    }

    PdfDict? newest;
    var current = offset;
    final seen = <int>{};
    for (var hop = 0; hop < 32; hop++) {
      if (!seen.add(current)) break;
      final dict = _readTrailerAt(raw, current);
      if (dict == null) break;
      if (newest == null) {
        newest = dict;
      } else {
        // Newest keys win; older sections fill only gaps (e.g. /Root /Info).
        final merged = Map<String, PdfObject>.from(dict.entries);
        for (final entry in newest.entries.entries) {
          merged[entry.key] = entry.value;
        }
        newest = PdfDict(merged);
      }
      final prev = dict['Prev'];
      if (prev is! PdfNumber) break;
      final next = prev.value.toInt();
      if (next <= 0 || next >= raw.length) break;
      current = next;
    }
    return newest ?? _lastTrailerInFile(raw);
  }

  /// Parses a trailer at [offset], which may be a classic `xref` table or a
  /// cross-reference stream object.
  static PdfDict? _readTrailerAt(String raw, int offset) {
    var pos = offset;
    while (pos < raw.length &&
        const {' ', '\t', '\r', '\n', '\x00', '\f'}.contains(raw[pos])) {
      pos++;
    }
    if (raw.startsWith('xref', pos)) {
      final t = raw.indexOf('trailer', pos);
      if (t == -1) return null;
      try {
        final value = _ValueParser(raw, t + 'trailer'.length).parseValue();
        return value is PdfDict ? value : null;
      } catch (_) {
        return null;
      }
    }
    // XRef stream (or any object at the offset): parse its dictionary only.
    final limit = pos + 65536 < raw.length ? pos + 65536 : raw.length;
    final slice = raw.substring(pos, limit);
    final obj = _objRe.firstMatch(slice);
    if (obj == null) return null;
    try {
      final value = _ValueParser(slice, obj.end).parseValue();
      if (value is PdfDict) return value;
      if (value is PdfStream) return value.dict;
    } catch (_) {
      return null;
    }
    return null;
  }

  static PdfDict? _lastTrailerInFile(String raw) {
    final idx = raw.lastIndexOf('trailer');
    if (idx == -1) return null;
    try {
      final value = _ValueParser(raw, idx + 'trailer'.length).parseValue();
      return value is PdfDict ? value : null;
    } catch (_) {
      return null;
    }
  }

  static PdfObject? _resolveIn(PdfObject? o, Map<int, PdfObject> objects) {
    var c = o;
    var g = 0;
    while (c is PdfRef && g++ < 64) {
      c = objects[c.number];
    }
    return c;
  }

  static Uint8List? _firstIdBytes(
    PdfObject? idObj,
    Map<int, PdfObject> objects,
  ) {
    final id = _resolveIn(idObj, objects);
    if (id is PdfArray && id.items.isNotEmpty) {
      final first = _resolveIn(id.items.first, objects);
      if (first is PdfString) return first.bytes;
    }
    return null;
  }

  /// Decodes an `/ObjStm` and adds its packed objects to [objects] (a top-level
  /// definition of the same number, being newer, takes precedence).
  static void _expandObjectStream(
    PdfStream objStm,
    Map<int, PdfObject> objects,
    int maxBytes,
  ) {
    PdfObject? res(PdfObject? o) {
      var c = o;
      var g = 0;
      while (c is PdfRef && g++ < 64) {
        c = objects[c.number];
      }
      return c;
    }

    final nObj = res(objStm.dict['N']);
    final firstObj = res(objStm.dict['First']);
    if (nObj is! PdfNumber || firstObj is! PdfNumber) return;
    final n = nObj.value.toInt();
    final first = firstObj.value.toInt();

    final Uint8List decoded;
    try {
      decoded = _decodeStreamWith(objStm, objects, maxBytes);
    } catch (_) {
      return; // an undecodable ObjStm simply yields no extra objects
    }
    final src = latin1.decode(decoded, allowInvalid: true);
    if (first < 0 || first > src.length || n <= 0) return;

    final ints = RegExp(r'\d+')
        .allMatches(src.substring(0, first))
        .map((m) => int.parse(m.group(0)!))
        .toList();
    if (ints.length < n * 2) return;

    for (var i = 0; i < n; i++) {
      final objNum = ints[i * 2];
      final start = first + ints[i * 2 + 1];
      final end = i + 1 < n ? first + ints[(i + 1) * 2 + 1] : src.length;
      if (start < 0 || end < start || end > src.length) continue;
      final value = _ValueParser(src.substring(start, end), 0).parseValue();
      objects.putIfAbsent(objNum, () => value);
    }
  }

  /// All indexed objects, for metadata scanners (signatures, embedded files).
  Iterable<PdfObject> get objects => _objects.values;

  /// Maps a destination reference/dictionary to a zero-based page index.
  int? pageIndexOf(PdfObject? ref, List<PdfDict> pages) {
    final resolved = resolve(ref);
    if (resolved == null) return null;
    for (var i = 0; i < pages.length; i++) {
      if (identical(pages[i], resolved)) return i;
    }
    return null;
  }

  /// Resolves an indirect reference to its object; returns non-refs unchanged.
  PdfObject? resolve(PdfObject? obj) {
    var current = obj;
    var guard = 0;
    while (current is PdfRef && guard++ < 64) {
      current = _objects[current.number];
    }
    return current;
  }

  bool get isEncrypted {
    if (trailer?['Encrypt'] != null) return true;
    // Brute-force trailer recovery can miss /Encrypt; scan for an encryption
    // dictionary, which carries /Filter /Standard together with /V or /R.
    for (final o in _objects.values) {
      if (o is PdfDict) {
        final f = o['Filter'];
        final isStandard = f is PdfName && f.name == 'Standard';
        final hasVersion = o['V'] is PdfNumber || o['R'] is PdfNumber;
        if (isStandard && hasVersion) return true;
      }
    }
    return false;
  }

  /// Returns the document catalog (`/Root`), located via trailer or by scan.
  PdfDict? get catalog {
    final root = resolve(trailer?['Root']);
    if (root is PdfDict) return root;
    for (final o in _objects.values) {
      if (o is PdfDict && _nameEquals(o['Type'], 'Catalog')) return o;
    }
    return null;
  }

  PdfDict? get info {
    final i = resolve(trailer?['Info']);
    if (i is PdfDict) return i;
    return null;
  }

  /// Collects all `/Page` leaf dictionaries, propagating inherited `/Resources`.
  List<PdfDict> pages() {
    final cat = catalog;
    final result = <PdfDict>[];
    if (cat == null) {
      // Fallback: any object typed /Page.
      for (final o in _objects.values) {
        if (o is PdfDict && _nameEquals(o['Type'], 'Page')) result.add(o);
      }
      return result;
    }
    final pagesRoot = resolve(cat['Pages']);
    if (pagesRoot is PdfDict) {
      _walkPageTree(pagesRoot, null, null, null, result, 0);
    }
    if (result.isEmpty) {
      for (final o in _objects.values) {
        if (o is PdfDict && _nameEquals(o['Type'], 'Page')) result.add(o);
      }
    }
    return result;
  }

  void _walkPageTree(
    PdfDict node,
    PdfDict? inheritedResources,
    PdfObject? inheritedMediaBox,
    PdfObject? inheritedCropBox,
    List<PdfDict> out,
    int depth,
  ) {
    if (depth > 64) return; // cycle guard
    final resources = resolve(node['Resources']);
    final effectiveResources = resources is PdfDict
        ? resources
        : inheritedResources;
    final effectiveMediaBox = node['MediaBox'] ?? inheritedMediaBox;
    final effectiveCropBox = node['CropBox'] ?? inheritedCropBox;

    if (_nameEquals(node['Type'], 'Page') ||
        (node['Contents'] != null && node['Kids'] == null)) {
      final page = Map<String, PdfObject>.from(node.entries);
      if (page['Resources'] == null && effectiveResources != null) {
        page['Resources'] = effectiveResources;
      }
      if (page['MediaBox'] == null && effectiveMediaBox != null) {
        page['MediaBox'] = effectiveMediaBox;
      }
      if (page['CropBox'] == null && effectiveCropBox != null) {
        page['CropBox'] = effectiveCropBox;
      }
      out.add(PdfDict(page));
      return;
    }
    final kids = resolve(node['Kids']);
    if (kids is PdfArray) {
      for (final kid in kids.items) {
        final k = resolve(kid);
        if (k is PdfDict) {
          _walkPageTree(
            k,
            effectiveResources,
            effectiveMediaBox,
            effectiveCropBox,
            out,
            depth + 1,
          );
        }
      }
    }
  }

  /// Concatenated, decoded content-stream bytes for [page].
  Uint8List pageContentBytes(PdfDict page) {
    final contents = resolve(page['Contents']);
    final streams = <PdfStream>[];
    if (contents is PdfStream) {
      streams.add(contents);
    } else if (contents is PdfArray) {
      for (final c in contents.items) {
        final s = resolve(c);
        if (s is PdfStream) streams.add(s);
      }
    }
    final builder = BytesBuilder();
    for (final s in streams) {
      builder.add(_decodeStream(s));
      builder.addByte(0x0A); // separate concatenated streams
    }
    return builder.toBytes();
  }

  /// Decodes a stream's filter chain. Public so the content/XObject text
  /// extractor can decode form XObjects and CMap streams.
  Uint8List decoded(PdfStream stream) =>
      _decodeStreamWith(stream, _objects, maxDecompressedEntryBytes);

  Uint8List _decodeStream(PdfStream stream) =>
      _decodeStreamWith(stream, _objects, maxDecompressedEntryBytes);

  /// Decodes a stream's full filter chain (resolving Filter/DecodeParms against
  /// [objects]). Static so object-stream expansion can reuse it before an
  /// instance exists.
  static Uint8List _decodeStreamWith(
    PdfStream stream,
    Map<int, PdfObject> objects,
    int maxBytes,
  ) {
    PdfObject? res(PdfObject? o) {
      var c = o;
      var g = 0;
      while (c is PdfRef && g++ < 64) {
        c = objects[c.number];
      }
      return c;
    }

    final names = _filterNames(res(stream.dict['Filter']));
    if (names.isEmpty) return stream.raw;
    final parmsObj = res(stream.dict['DecodeParms'] ?? stream.dict['DP']);
    final parms = _parmsList(parmsObj, names.length, res);
    try {
      return decodeStream(stream.raw, names, parms, maxOutputBytes: maxBytes);
    } on ParseException {
      rethrow;
    } catch (e) {
      throw MalformedDocumentException('stream decode failed: $e');
    }
  }

  static List<String> _filterNames(PdfObject? filterObj) {
    if (filterObj is PdfName) return [filterObj.name];
    if (filterObj is PdfArray) {
      return filterObj.items.whereType<PdfName>().map((n) => n.name).toList();
    }
    return const [];
  }

  static List<Map<String, int>?> _parmsList(
    PdfObject? parmsObj,
    int filterCount,
    PdfObject? Function(PdfObject?) res,
  ) {
    if (parmsObj is PdfArray) {
      return [
        for (var i = 0; i < filterCount; i++)
          i < parmsObj.items.length
              ? _parmsToMap(res(parmsObj.items[i]))
              : null,
      ];
    }
    final single = _parmsToMap(parmsObj);
    return [for (var i = 0; i < filterCount; i++) i == 0 ? single : null];
  }

  static Map<String, int>? _parmsToMap(PdfObject? p) {
    if (p is! PdfDict) return null;
    final m = <String, int>{};
    for (final key in const [
      'Predictor',
      'Colors',
      'BitsPerComponent',
      'Columns',
      'EarlyChange',
    ]) {
      final v = p[key];
      if (v is PdfNumber) m[key] = v.value.toInt();
    }
    return m.isEmpty ? null : m;
  }

  static bool _nameEquals(PdfObject? o, String name) =>
      o is PdfName && o.name == name;
}
