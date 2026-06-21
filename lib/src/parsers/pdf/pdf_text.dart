import 'dart:convert';
import 'dart:typed_data';

import 'pdf_encodings.dart';
import 'pdf_internals.dart';

/// A parsed `/ToUnicode` CMap: maps character codes to Unicode strings, and
/// records the code width (1 or 2 bytes) discovered from its codespace range.
class ToUnicodeCMap {
  ToUnicodeCMap(this.map, this.codeByteLength);
  final Map<int, String> map;
  final int codeByteLength;

  static ToUnicodeCMap parse(Uint8List streamBytes) {
    final src = latin1.decode(streamBytes, allowInvalid: true);
    final map = <int, String>{};
    var codeLen = 1;

    final cs = RegExp(
      r'begincodespacerange(.*?)endcodespacerange',
      dotAll: true,
    ).firstMatch(src);
    if (cs != null) {
      final hex = RegExp(r'<([0-9A-Fa-f]+)>').firstMatch(cs.group(1)!);
      if (hex != null) codeLen = (hex.group(1)!.length / 2).ceil().clamp(1, 2);
    }

    for (final block in RegExp(
      r'beginbfchar(.*?)endbfchar',
      dotAll: true,
    ).allMatches(src)) {
      for (final m in RegExp(
        r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>',
      ).allMatches(block.group(1)!)) {
        map[int.parse(m.group(1)!, radix: 16)] = _hexToString(m.group(2)!);
      }
    }

    for (final block in RegExp(
      r'beginbfrange(.*?)endbfrange',
      dotAll: true,
    ).allMatches(src)) {
      final body = block.group(1)!;
      for (final m in RegExp(
        r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>',
      ).allMatches(body)) {
        final lo = int.parse(m.group(1)!, radix: 16);
        final hi = int.parse(m.group(2)!, radix: 16);
        var dst = int.parse(m.group(3)!, radix: 16);
        for (var code = lo; code <= hi && code - lo < 65536; code++) {
          map[code] = String.fromCharCode(dst++);
        }
      }
      for (final m in RegExp(
        r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*\[(.*?)\]',
        dotAll: true,
      ).allMatches(body)) {
        final lo = int.parse(m.group(1)!, radix: 16);
        final dsts = RegExp(r'<([0-9A-Fa-f]+)>')
            .allMatches(m.group(3)!)
            .map((d) => _hexToString(d.group(1)!))
            .toList();
        for (var i = 0; i < dsts.length; i++) {
          map[lo + i] = dsts[i];
        }
      }
    }
    return ToUnicodeCMap(map, codeLen);
  }

  static String _hexToString(String hex) {
    var h = hex;
    if (h.length.isOdd) h += '0';
    final units = <int>[];
    for (var i = 0; i + 4 <= h.length; i += 4) {
      units.add(int.parse(h.substring(i, i + 4), radix: 16));
    }
    if (units.isEmpty && h.length >= 2) {
      units.add(int.parse(h.substring(0, 2), radix: 16));
    }
    return String.fromCharCodes(units);
  }
}

/// Resolved decoding strategy for one font: code width plus the maps used to
/// turn character codes into Unicode (ToUnicode first, then a simple-font
/// encoding, then a Latin-1 fallback for single-byte codes).
class FontInfo {
  FontInfo({required this.codeBytes, this.toUnicode, this.simpleMap});
  final int codeBytes;
  final ToUnicodeCMap? toUnicode;
  final Map<int, String>? simpleMap;

  String decode(Uint8List bytes) {
    final step = codeBytes;
    final b = StringBuffer();
    for (var i = 0; i + step <= bytes.length; i += step) {
      var code = 0;
      for (var k = 0; k < step; k++) {
        code = (code << 8) | bytes[i + k];
      }
      final tu = toUnicode?.map[code];
      if (tu != null) {
        b.write(tu);
        continue;
      }
      if (step == 1) {
        final sm = simpleMap?[code];
        if (sm != null) {
          b.write(sm);
        } else {
          b.writeCharCode(code); // last-resort Latin-1
        }
      }
      // A 2-byte code without ToUnicode is a glyph index (Identity-H) and is
      // not recoverable to Unicode; skip it rather than emit garbage.
    }
    return b.toString();
  }
}

/// Extracts text from a page's content, recursing into Form XObjects and
/// skipping inline images. Maps glyph codes to Unicode per-font.
class ContentTextExtractor {
  ContentTextExtractor(this._doc);
  final PdfDocument _doc;

  static String extractPage(PdfDocument doc, PdfDict page) {
    final e = ContentTextExtractor(doc);
    final resources = doc.resolve(page['Resources']);
    final out = StringBuffer();
    e._run(
      doc.pageContentBytes(page),
      resources is PdfDict ? resources : const PdfDict({}),
      out,
      0,
    );
    return out.toString().trimRight();
  }

  void _run(Uint8List content, PdfDict resources, StringBuffer out, int depth) {
    if (depth > 12) return; // XObject recursion guard
    final fonts = _buildFonts(resources);
    final src = latin1.decode(content, allowInvalid: true);
    final stack = <_Operand>[];
    FontInfo? current;
    var pos = 0;

    while (pos < src.length) {
      pos = _skipWs(src, pos);
      if (pos >= src.length) break;
      final c = src[pos];
      if (c == '(') {
        final r = _readLiteral(src, pos);
        stack.add(_Operand.string(r.bytes));
        pos = r.next;
      } else if (c == '<' && (pos + 1 >= src.length || src[pos + 1] != '<')) {
        final r = _readHex(src, pos);
        stack.add(_Operand.string(r.bytes));
        pos = r.next;
      } else if (c == '<') {
        pos = _skipDict(src, pos); // marked-content property list, etc.
      } else if (c == '[') {
        final r = _readArray(src, pos);
        stack.add(r.operand);
        pos = r.next;
      } else if (c == '/') {
        final r = _readName(src, pos);
        stack.add(_Operand.name(r.value));
        pos = r.next;
      } else if (_isNumStart(c)) {
        final r = _readNumber(src, pos);
        stack.add(_Operand.number(r.value));
        pos = r.next;
      } else if (c == ']' || c == '>' || c == '}' || c == '{' || c == ')') {
        pos++; // stray delimiter
      } else {
        final r = _readOperator(src, pos);
        pos = r.next;
        switch (r.op) {
          case 'Tf':
            if (stack.length >= 2 && stack[stack.length - 2].isName) {
              current = fonts[stack[stack.length - 2].name];
            }
          case 'Tj':
            if (stack.isNotEmpty && stack.last.isString) {
              out.write(_decode(current, stack.last.bytes!));
            }
          case 'TJ':
            if (stack.isNotEmpty && stack.last.isArray) {
              for (final el in stack.last.array!) {
                if (el.isString) {
                  out.write(_decode(current, el.bytes!));
                } else if (el.isNumber && el.number! < -150) {
                  out.write(' ');
                }
              }
            }
          case "'" || '"':
            out.write('\n');
            if (stack.isNotEmpty && stack.last.isString) {
              out.write(_decode(current, stack.last.bytes!));
            }
          case 'Td' || 'TD' || 'Tm' || 'T*' || 'ET':
            out.write('\n');
          case 'Do':
            if (stack.isNotEmpty && stack.last.isName) {
              _runXObject(stack.last.name!, resources, out, depth);
            }
          case 'BI':
            pos = _skipInlineImage(src, pos);
        }
        stack.clear();
      }
    }
  }

  String _decode(FontInfo? font, Uint8List bytes) => font != null
      ? font.decode(bytes)
      : latin1.decode(bytes, allowInvalid: true);

  void _runXObject(
    String name,
    PdfDict resources,
    StringBuffer out,
    int depth,
  ) {
    final xobjects = _doc.resolve(resources['XObject']);
    if (xobjects is! PdfDict) return;
    final xobj = _doc.resolve(xobjects[name]);
    if (xobj is! PdfStream) return;
    final subtype = xobj.dict['Subtype'];
    if (subtype is! PdfName || subtype.name != 'Form') return; // skip images
    final formRes = _doc.resolve(xobj.dict['Resources']);
    out.write('\n');
    try {
      _run(
        _doc.decoded(xobj),
        formRes is PdfDict ? formRes : resources, // inherit if absent
        out,
        depth + 1,
      );
    } catch (_) {
      // a malformed form XObject simply contributes no text
    }
  }

  // --- font resolution -------------------------------------------------------

  Map<String, FontInfo> _buildFonts(PdfDict resources) {
    final result = <String, FontInfo>{};
    final fontDict = _doc.resolve(resources['Font']);
    if (fontDict is! PdfDict) return result;
    for (final e in fontDict.entries.entries) {
      final font = _doc.resolve(e.value);
      if (font is PdfDict) {
        try {
          result[e.key] = _fontInfo(font);
        } catch (_) {
          result[e.key] = FontInfo(codeBytes: 1);
        }
      }
    }
    return result;
  }

  FontInfo _fontInfo(PdfDict font) {
    ToUnicodeCMap? tu;
    final tuObj = _doc.resolve(font['ToUnicode']);
    if (tuObj is PdfStream) {
      try {
        tu = ToUnicodeCMap.parse(_doc.decoded(tuObj));
      } catch (_) {
        tu = null;
      }
    }

    final subtype = font['Subtype'];
    if (subtype is PdfName && subtype.name == 'Type0') {
      var width = 2; // Identity-H/V and most CJK CMaps are 2-byte
      final enc = _doc.resolve(font['Encoding']);
      if (enc is PdfStream) {
        width = cmapCodeWidth(_doc.decoded(enc)) ?? 2;
      }
      return FontInfo(codeBytes: tu?.codeByteLength ?? width, toUnicode: tu);
    }

    return FontInfo(
      codeBytes: tu?.codeByteLength ?? 1,
      toUnicode: tu,
      simpleMap: _simpleEncoding(font),
    );
  }

  Map<int, String> _simpleEncoding(PdfDict font) {
    String? baseName;
    List<Object?>? differences;
    final enc = _doc.resolve(font['Encoding']);
    if (enc is PdfName) {
      baseName = enc.name;
    } else if (enc is PdfDict) {
      final be = _doc.resolve(enc['BaseEncoding']);
      if (be is PdfName) baseName = be.name;
      final diff = _doc.resolve(enc['Differences']);
      if (diff is PdfArray) {
        differences = [
          for (final item in diff.items)
            if (item is PdfNumber)
              item.value.toInt()
            else if (item is PdfName)
              item.name,
        ];
      }
    }
    final map = Map<int, String>.from(baseEncodingMap(baseName));
    if (differences != null) applyDifferences(map, differences);
    return map;
  }

  // --- low-level content readers ---------------------------------------------

  int _skipWs(String s, int pos) {
    while (pos < s.length) {
      final c = s[pos];
      if (c == ' ' ||
          c == '\t' ||
          c == '\r' ||
          c == '\n' ||
          c == '\x00' ||
          c == '\f') {
        pos++;
      } else if (c == '%') {
        while (pos < s.length && s[pos] != '\n' && s[pos] != '\r') {
          pos++;
        }
      } else {
        break;
      }
    }
    return pos;
  }

  int _skipDict(String s, int pos) {
    var depth = 0;
    var i = pos;
    while (i + 1 < s.length) {
      if (s[i] == '<' && s[i + 1] == '<') {
        depth++;
        i += 2;
      } else if (s[i] == '>' && s[i + 1] == '>') {
        depth--;
        i += 2;
        if (depth == 0) break;
      } else {
        i++;
      }
    }
    return i;
  }

  int _skipInlineImage(String s, int pos) {
    final idIdx = s.indexOf('ID', pos);
    if (idIdx == -1) return s.length;
    var i = idIdx + 2;
    if (i < s.length && _isWs(s[i])) i++; // single whitespace after ID
    while (i + 1 < s.length) {
      if (s[i] == 'E' &&
          s[i + 1] == 'I' &&
          (i == 0 || _isWs(s[i - 1])) &&
          (i + 2 >= s.length || _isWs(s[i + 2]) || _isDelim(s[i + 2]))) {
        return i + 2;
      }
      i++;
    }
    return s.length;
  }

  _StrResult _readLiteral(String s, int pos) {
    pos++;
    final out = <int>[];
    var depth = 1;
    while (pos < s.length) {
      final c = s[pos++];
      if (c == '\\') {
        if (pos >= s.length) break;
        final e = s[pos];
        const named = {
          'n': 10,
          'r': 13,
          't': 9,
          'b': 8,
          'f': 12,
          '(': 40,
          ')': 41,
          '\\': 92,
        };
        final code = e.codeUnitAt(0);
        if (named.containsKey(e)) {
          out.add(named[e]!);
          pos++;
        } else if (e == '\n') {
          pos++; // line continuation
        } else if (e == '\r') {
          pos++;
          if (pos < s.length && s[pos] == '\n') pos++;
        } else if (code >= 0x30 && code <= 0x37) {
          // \ddd octal, 1–3 digits
          var oct = '';
          for (
            var k = 0;
            k < 3 &&
                pos < s.length &&
                s[pos].codeUnitAt(0) >= 0x30 &&
                s[pos].codeUnitAt(0) <= 0x37;
            k++
          ) {
            oct += s[pos];
            pos++;
          }
          out.add(int.parse(oct, radix: 8) & 0xFF);
        } else {
          out.add(code); // \X for any other X is literally X
          pos++;
        }
      } else if (c == '(') {
        depth++;
        out.add(40);
      } else if (c == ')') {
        if (--depth == 0) break;
        out.add(41);
      } else {
        out.add(c.codeUnitAt(0));
      }
    }
    return _StrResult(Uint8List.fromList(out), pos);
  }

  _StrResult _readHex(String s, int pos) {
    pos++;
    final hex = StringBuffer();
    while (pos < s.length && s[pos] != '>') {
      final c = s[pos++];
      if (!_isWs(c)) hex.write(c);
    }
    if (pos < s.length) pos++;
    var h = hex.toString();
    if (h.length.isOdd) h += '0';
    final out = Uint8List(h.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return _StrResult(out, pos);
  }

  _NameResult _readName(String s, int pos) {
    pos++;
    final b = StringBuffer();
    while (pos < s.length) {
      final c = s[pos];
      if (_isWs(c) || _isDelim(c)) break;
      b.write(c);
      pos++;
    }
    return _NameResult(b.toString(), pos);
  }

  _NumResult _readNumber(String s, int pos) {
    final b = StringBuffer();
    while (pos < s.length) {
      final c = s[pos];
      if ((c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57) ||
          c == '.' ||
          c == '-' ||
          c == '+') {
        b.write(c);
        pos++;
      } else {
        break;
      }
    }
    return _NumResult(double.tryParse(b.toString()) ?? 0, pos);
  }

  _ArrResult _readArray(String s, int pos) {
    pos++;
    final items = <_Operand>[];
    while (pos < s.length) {
      pos = _skipWs(s, pos);
      if (pos >= s.length || s[pos] == ']') {
        if (pos < s.length) pos++;
        break;
      }
      final c = s[pos];
      if (c == '(') {
        final r = _readLiteral(s, pos);
        items.add(_Operand.string(r.bytes));
        pos = r.next;
      } else if (c == '<') {
        final r = _readHex(s, pos);
        items.add(_Operand.string(r.bytes));
        pos = r.next;
      } else if (_isNumStart(c)) {
        final r = _readNumber(s, pos);
        items.add(_Operand.number(r.value));
        pos = r.next;
      } else {
        pos++;
      }
    }
    return _ArrResult(_Operand.array(items), pos);
  }

  _OpResult _readOperator(String s, int pos) {
    final b = StringBuffer();
    while (pos < s.length) {
      final c = s[pos];
      if (_isWs(c) || _isDelim(c)) break;
      b.write(c);
      pos++;
    }
    if (b.isEmpty) pos++; // never stall
    return _OpResult(b.toString(), pos);
  }

  static bool _isWs(String c) =>
      c == ' ' ||
      c == '\t' ||
      c == '\r' ||
      c == '\n' ||
      c == '\x00' ||
      c == '\f';

  static bool _isDelim(String c) =>
      c == '/' ||
      c == '[' ||
      c == ']' ||
      c == '(' ||
      c == ')' ||
      c == '<' ||
      c == '>' ||
      c == '{' ||
      c == '}' ||
      c == '%';

  static bool _isNumStart(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 48 && u <= 57) || c == '-' || c == '+' || c == '.';
  }
}

class _Operand {
  _Operand.string(this.bytes)
    : name = null,
      number = null,
      array = null,
      _kind = 0;
  _Operand.name(this.name)
    : bytes = null,
      number = null,
      array = null,
      _kind = 1;
  _Operand.number(this.number)
    : bytes = null,
      name = null,
      array = null,
      _kind = 2;
  _Operand.array(this.array)
    : bytes = null,
      name = null,
      number = null,
      _kind = 3;

  final Uint8List? bytes;
  final String? name;
  final double? number;
  final List<_Operand>? array;
  final int _kind;

  bool get isString => _kind == 0;
  bool get isName => _kind == 1;
  bool get isNumber => _kind == 2;
  bool get isArray => _kind == 3;
}

class _StrResult {
  _StrResult(this.bytes, this.next);
  final Uint8List bytes;
  final int next;
}

class _NameResult {
  _NameResult(this.value, this.next);
  final String value;
  final int next;
}

class _NumResult {
  _NumResult(this.value, this.next);
  final double value;
  final int next;
}

class _ArrResult {
  _ArrResult(this.operand, this.next);
  final _Operand operand;
  final int next;
}

class _OpResult {
  _OpResult(this.op, this.next);
  final String op;
  final int next;
}
