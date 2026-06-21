import 'dart:convert';
import 'dart:typed_data';

import 'pdf_encodings.dart';
import 'pdf_internals.dart';
import 'pdf_text.dart';

/// Extracts a conservative, pure-Dart visual display list from PDF pages.
///
/// This is not a full rasterizer. It captures the stable substrate needed by a
/// faithful renderer: page boxes, positioned text, simple rectangles, image
/// placeholders, and explicit unsupported operator diagnostics.
class PdfVisualExtractor {
  PdfVisualExtractor(this._doc);

  final PdfDocument _doc;

  static List<Map<String, Object?>> extract(
    PdfDocument doc,
    List<PdfDict> pages,
  ) {
    final extractor = PdfVisualExtractor(doc);
    return [
      for (var i = 0; i < pages.length; i++)
        extractor._extractPage(pages[i], i),
    ];
  }

  Map<String, Object?> _extractPage(PdfDict page, int pageIndex) {
    final box = _pageBox(page);
    final resources = _doc.resolve(page['Resources']);
    final commands = <Map<String, Object?>>[];
    try {
      _run(
        _doc.pageContentBytes(page),
        resources is PdfDict ? resources : const PdfDict({}),
        commands,
        _VisualState(),
        0,
      );
    } catch (e) {
      commands.add({
        'type': 'unsupported',
        'operator': 'pdf.visual_extract_failed',
        'detail': '$e',
      });
    }
    return {
      'pageIndex': pageIndex,
      'sourceId': 'pdf-page-$pageIndex',
      'description': 'PDF page ${pageIndex + 1}',
      'x': box.x,
      'y': box.y,
      'width': box.width,
      'height': box.height,
      'coordinateSpace': 'pdfUserSpace',
      'commands': commands,
    };
  }

  _PageBox _pageBox(PdfDict page) {
    final crop = _boxArray(_doc.resolve(page['CropBox']));
    if (crop != null) return crop;
    final media = _boxArray(_doc.resolve(page['MediaBox']));
    return media ?? const _PageBox(0, 0, 612, 792);
  }

  _PageBox? _boxArray(PdfObject? value) {
    if (value is! PdfArray || value.items.length < 4) return null;
    final nums = value.items
        .take(4)
        .map(_numberValue)
        .whereType<double>()
        .toList();
    if (nums.length != 4) return null;
    final x0 = nums[0];
    final y0 = nums[1];
    final x1 = nums[2];
    final y1 = nums[3];
    return _PageBox(
      x0 < x1 ? x0 : x1,
      y0 < y1 ? y0 : y1,
      (x1 - x0).abs(),
      (y1 - y0).abs(),
    );
  }

  void _run(
    Uint8List content,
    PdfDict resources,
    List<Map<String, Object?>> commands,
    _VisualState state,
    int depth,
  ) {
    if (depth > 12 || commands.length > 4000) return;
    final fonts = _buildFonts(resources);
    final src = latin1.decode(content, allowInvalid: true);
    final stack = <_Operand>[];
    final pathRects = <_Rect>[];
    var pos = 0;

    while (pos < src.length && commands.length <= 4000) {
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
        pos = _skipDict(src, pos);
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
        pos++;
      } else {
        final r = _readOperator(src, pos);
        pos = r.next;
        _applyOperator(
          r.op,
          stack,
          resources,
          fonts,
          state,
          pathRects,
          commands,
          depth,
        );
        if (r.op == 'BI') pos = _skipInlineImage(src, pos);
        stack.clear();
      }
    }
  }

  void _applyOperator(
    String op,
    List<_Operand> stack,
    PdfDict resources,
    Map<String, FontInfo> fonts,
    _VisualState state,
    List<_Rect> pathRects,
    List<Map<String, Object?>> commands,
    int depth,
  ) {
    switch (op) {
      case 'q':
        state.push();
      case 'Q':
        state.pop();
      case 'BT':
        state.textX = 0;
        state.textY = 0;
      case 'Tf':
        if (stack.length >= 2 &&
            stack[stack.length - 2].isName &&
            stack.last.isNumber) {
          state.fontName = stack[stack.length - 2].name;
          state.fontSize = stack.last.number!.abs();
          state.font = fonts[state.fontName];
        }
      case 'Td' || 'TD':
        if (stack.length >= 2) {
          state.textX += stack[stack.length - 2].number ?? 0;
          state.textY += stack.last.number ?? 0;
        }
      case 'Tm':
        if (stack.length >= 6) {
          state.textX = stack[4].number ?? state.textX;
          state.textY = stack[5].number ?? state.textY;
        }
      case 'T*':
        state.textY -= state.leading == 0
            ? state.fontSize * 1.2
            : state.leading;
      case 'TL':
        if (stack.isNotEmpty && stack.last.isNumber) {
          state.leading = stack.last.number!;
        }
      case 'Tj':
        if (stack.isNotEmpty && stack.last.isString) {
          _emitText(commands, state, stack.last.bytes!);
        }
      case 'TJ':
        if (stack.isNotEmpty && stack.last.isArray) {
          for (final el in stack.last.array!) {
            if (el.isString) {
              _emitText(commands, state, el.bytes!);
            } else if (el.isNumber) {
              state.textX -= el.number! / 1000 * state.fontSize;
            }
          }
        }
      case "'" || '"':
        state.textY -= state.leading == 0
            ? state.fontSize * 1.2
            : state.leading;
        if (stack.isNotEmpty && stack.last.isString) {
          _emitText(commands, state, stack.last.bytes!);
        }
      case 'rg':
        if (stack.length >= 3) {
          state.fill = _rgb(
            stack[stack.length - 3],
            stack[stack.length - 2],
            stack.last,
          );
        }
      case 'RG':
        if (stack.length >= 3) {
          state.stroke = _rgb(
            stack[stack.length - 3],
            stack[stack.length - 2],
            stack.last,
          );
        }
      case 'g':
        if (stack.isNotEmpty) state.fill = _gray(stack.last);
      case 'G':
        if (stack.isNotEmpty) state.stroke = _gray(stack.last);
      case 'w':
        if (stack.isNotEmpty && stack.last.isNumber) {
          state.strokeWidth = stack.last.number!.abs();
        }
      case 're':
        if (stack.length >= 4) {
          pathRects.add(
            _Rect(
              stack[stack.length - 4].number ?? 0,
              stack[stack.length - 3].number ?? 0,
              stack[stack.length - 2].number ?? 0,
              stack.last.number ?? 0,
            ),
          );
        }
      case 'f' || 'F' || 'f*':
        _paintRects(commands, pathRects, fill: state.fill);
      case 'S' || 's':
        _paintRects(
          commands,
          pathRects,
          stroke: state.stroke,
          strokeWidth: state.strokeWidth,
        );
      case 'B' || 'B*' || 'b' || 'b*':
        _paintRects(
          commands,
          pathRects,
          fill: state.fill,
          stroke: state.stroke,
          strokeWidth: state.strokeWidth,
        );
      case 'n':
        pathRects.clear();
      case 'Do':
        if (stack.isNotEmpty && stack.last.isName) {
          _runXObject(stack.last.name!, resources, commands, state, depth);
        }
      case 'BI':
        commands.add({
          'type': 'image',
          'sourceId': 'inline-image-${commands.length}',
          'x': state.textX,
          'y': state.textY,
          'width': state.fontSize,
          'height': state.fontSize,
          'mediaType': 'application/pdf-inline-image',
          'description': 'PDF inline image',
        });
      case 'cm' ||
          'm' ||
          'l' ||
          'c' ||
          'v' ||
          'y' ||
          'h' ||
          'W' ||
          'W*' ||
          'sh':
        _markUnsupported(commands, op);
      default:
        if (_isLikelyDrawingOperator(op)) _markUnsupported(commands, op);
    }
  }

  void _emitText(
    List<Map<String, Object?>> commands,
    _VisualState state,
    Uint8List bytes,
  ) {
    final text =
        state.font?.decode(bytes) ?? latin1.decode(bytes, allowInvalid: true);
    if (text.isEmpty) return;
    commands.add({
      'type': 'text',
      'text': text,
      'x': state.textX,
      'y': state.textY,
      'fontSize': state.fontSize,
      if (state.fontName != null) 'fontName': state.fontName,
      'fill': state.fill,
    });
    state.textX += text.runes.length * state.fontSize * 0.5;
  }

  void _paintRects(
    List<Map<String, Object?>> commands,
    List<_Rect> rects, {
    String? fill,
    String? stroke,
    double strokeWidth = 1,
  }) {
    for (final rect in rects) {
      commands.add({
        'type': 'rect',
        'x': rect.x,
        'y': rect.y,
        'width': rect.width,
        'height': rect.height,
        if (fill != null) 'fill': fill,
        if (stroke != null) 'stroke': stroke,
        'strokeWidth': strokeWidth,
      });
    }
    rects.clear();
  }

  void _runXObject(
    String name,
    PdfDict resources,
    List<Map<String, Object?>> commands,
    _VisualState state,
    int depth,
  ) {
    final xobjects = _doc.resolve(resources['XObject']);
    if (xobjects is! PdfDict) return;
    final xobj = _doc.resolve(xobjects[name]);
    if (xobj is! PdfStream) return;
    final subtype = xobj.dict['Subtype'];
    if (subtype is PdfName && subtype.name == 'Form') {
      final formRes = _doc.resolve(xobj.dict['Resources']);
      _run(
        _doc.decoded(xobj),
        formRes is PdfDict ? formRes : resources,
        commands,
        state.copy(),
        depth + 1,
      );
      return;
    }
    if (subtype is PdfName && subtype.name == 'Image') {
      final width = _numberValue(_doc.resolve(xobj.dict['Width'])) ?? 0;
      final height = _numberValue(_doc.resolve(xobj.dict['Height'])) ?? 0;
      commands.add({
        'type': 'image',
        'sourceId': name,
        'x': state.textX,
        'y': state.textY,
        'width': width,
        'height': height,
        'mediaType': 'application/pdf-image-xobject',
        'description': 'PDF image XObject /$name',
      });
    }
  }

  Map<String, FontInfo> _buildFonts(PdfDict resources) {
    final result = <String, FontInfo>{};
    final fontDict = _doc.resolve(resources['Font']);
    if (fontDict is! PdfDict) return result;
    for (final entry in fontDict.entries.entries) {
      final font = _doc.resolve(entry.value);
      if (font is PdfDict) {
        try {
          result[entry.key] = _fontInfo(font);
        } catch (_) {
          result[entry.key] = FontInfo(codeBytes: 1);
        }
      }
    }
    return result;
  }

  FontInfo _fontInfo(PdfDict font) {
    ToUnicodeCMap? toUnicode;
    final toUnicodeObj = _doc.resolve(font['ToUnicode']);
    if (toUnicodeObj is PdfStream) {
      try {
        toUnicode = ToUnicodeCMap.parse(_doc.decoded(toUnicodeObj));
      } catch (_) {
        toUnicode = null;
      }
    }

    final subtype = font['Subtype'];
    if (subtype is PdfName && subtype.name == 'Type0') {
      var width = 2;
      final enc = _doc.resolve(font['Encoding']);
      if (enc is PdfStream) width = cmapCodeWidth(_doc.decoded(enc)) ?? 2;
      return FontInfo(
        codeBytes: toUnicode?.codeByteLength ?? width,
        toUnicode: toUnicode,
      );
    }

    return FontInfo(
      codeBytes: toUnicode?.codeByteLength ?? 1,
      toUnicode: toUnicode,
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

  static bool _isLikelyDrawingOperator(String op) =>
      const {'Do', 'cs', 'CS', 'sc', 'SC', 'scn', 'SCN'}.contains(op);

  static void _markUnsupported(List<Map<String, Object?>> commands, String op) {
    if (commands.any((c) => c['operator'] == op)) return;
    commands.add({'type': 'unsupported', 'operator': op});
  }

  static String _rgb(_Operand r, _Operand g, _Operand b) {
    int channel(_Operand operand) =>
        (((operand.number ?? 0).clamp(0, 1)) * 255).round();
    return _hex(channel(r), channel(g), channel(b));
  }

  static String _gray(_Operand value) {
    final c = (((value.number ?? 0).clamp(0, 1)) * 255).round();
    return _hex(c, c, c);
  }

  static String _hex(int r, int g, int b) {
    String c(int value) =>
        value.clamp(0, 255).toRadixString(16).padLeft(2, '0');
    return '#${c(r)}${c(g)}${c(b)}';
  }

  static double? _numberValue(PdfObject? value) =>
      value is PdfNumber ? value.value.toDouble() : null;

  int _skipWs(String s, int pos) {
    while (pos < s.length) {
      final c = s[pos];
      if (_isWs(c)) {
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
    if (i < s.length && _isWs(s[i])) i++;
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
          pos++;
        } else if (e == '\r') {
          pos++;
          if (pos < s.length && s[pos] == '\n') pos++;
        } else if (code >= 0x30 && code <= 0x37) {
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
          out.add(code);
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
    if (b.isEmpty) pos++;
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

final class _VisualState {
  String? fontName;
  FontInfo? font;
  double fontSize = 12;
  double textX = 0;
  double textY = 0;
  double leading = 0;
  String fill = '#000000';
  String stroke = '#000000';
  double strokeWidth = 1;

  final List<_VisualState> _stack = [];

  void push() => _stack.add(copy());

  void pop() {
    if (_stack.isEmpty) return;
    final previous = _stack.removeLast();
    fontName = previous.fontName;
    font = previous.font;
    fontSize = previous.fontSize;
    textX = previous.textX;
    textY = previous.textY;
    leading = previous.leading;
    fill = previous.fill;
    stroke = previous.stroke;
    strokeWidth = previous.strokeWidth;
  }

  _VisualState copy() => _VisualState()
    ..fontName = fontName
    ..font = font
    ..fontSize = fontSize
    ..textX = textX
    ..textY = textY
    ..leading = leading
    ..fill = fill
    ..stroke = stroke
    ..strokeWidth = strokeWidth;
}

final class _PageBox {
  const _PageBox(this.x, this.y, this.width, this.height);
  final double x;
  final double y;
  final double width;
  final double height;
}

final class _Rect {
  const _Rect(this.x, this.y, this.width, this.height);
  final double x;
  final double y;
  final double width;
  final double height;
}

final class _Operand {
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

final class _StrResult {
  _StrResult(this.bytes, this.next);
  final Uint8List bytes;
  final int next;
}

final class _NameResult {
  _NameResult(this.value, this.next);
  final String value;
  final int next;
}

final class _NumResult {
  _NumResult(this.value, this.next);
  final double value;
  final int next;
}

final class _ArrResult {
  _ArrResult(this.operand, this.next);
  final _Operand operand;
  final int next;
}

final class _OpResult {
  _OpResult(this.op, this.next);
  final String op;
  final int next;
}
