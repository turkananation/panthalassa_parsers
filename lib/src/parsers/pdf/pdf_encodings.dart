/// PDF simple-font character encodings and glyph-name → Unicode resolution.
///
/// Used to recover text from Type1/TrueType fonts that lack a `/ToUnicode` CMap
/// (very common). Covers WinAnsiEncoding (CP1252) and MacRomanEncoding precisely,
/// approximates StandardEncoding/PDFDocEncoding via WinAnsi, and resolves
/// `/Differences` glyph names through an Adobe Glyph List subset plus the
/// algorithmic `uniXXXX` / `uXXXXXX` conventions.
library;

/// Returns a code → Unicode-string map for a named base encoding. Unknown or
/// absent encodings fall back to WinAnsi, the safest default for extraction.
Map<int, String> baseEncodingMap(String? name) {
  switch (name) {
    case 'MacRomanEncoding':
      return _macRoman;
    case 'WinAnsiEncoding':
    case 'PDFDocEncoding':
    case 'StandardEncoding':
    default:
      return _winAnsi;
  }
}

/// Applies an `/Differences` array (`[code name name … code name …]`) onto a
/// mutable base map, resolving each glyph name to Unicode.
void applyDifferences(Map<int, String> map, List<Object?> differences) {
  var code = 0;
  for (final item in differences) {
    if (item is int) {
      code = item;
    } else if (item is String) {
      final u = glyphToUnicode(item);
      if (u != null) map[code] = u;
      code++;
    }
  }
}

/// Resolves an Adobe glyph name to a Unicode string, or `null` if unknown.
String? glyphToUnicode(String name) {
  // Strip a font-specific suffix (e.g. "afii10017.sc" → "afii10017").
  final dot = name.indexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : name;

  final agl = _agl[base];
  if (agl != null) return agl;
  if (base.length == 1) return base; // single-char names map to themselves

  // uniXXXX(YYYY…) — one or more 4-hex UTF-16 code units.
  if (base.startsWith('uni') && (base.length - 3) % 4 == 0 && base.length > 3) {
    final units = <int>[];
    for (var i = 3; i + 4 <= base.length; i += 4) {
      final v = int.tryParse(base.substring(i, i + 4), radix: 16);
      if (v == null) return null;
      units.add(v);
    }
    return String.fromCharCodes(units);
  }
  // uXXXX..uXXXXXX — a single code point (4–6 hex).
  if (base.startsWith('u') && base.length >= 5 && base.length <= 7) {
    final v = int.tryParse(base.substring(1), radix: 16);
    if (v != null) return String.fromCharCode(v);
  }
  return null;
}

/// Parses the code-byte length (1 or 2) from a CMap's codespace range.
int? cmapCodeWidth(List<int> cmapBytes) {
  final src = String.fromCharCodes(cmapBytes);
  final cs = RegExp(r'begincodespacerange(.*?)endcodespacerange', dotAll: true)
      .firstMatch(src);
  if (cs == null) return null;
  final hex = RegExp(r'<([0-9A-Fa-f]+)>').firstMatch(cs.group(1)!);
  if (hex == null) return null;
  return (hex.group(1)!.length / 2).ceil().clamp(1, 2);
}

// --- WinAnsiEncoding (CP1252) -------------------------------------------------

final Map<int, String> _winAnsi = _buildWinAnsi();

Map<int, String> _buildWinAnsi() {
  final m = <int, String>{};
  for (var c = 0x20; c <= 0x7E; c++) {
    m[c] = String.fromCharCode(c); // ASCII identity
  }
  for (var c = 0xA0; c <= 0xFF; c++) {
    m[c] = String.fromCharCode(c); // Latin-1 identity
  }
  const special = <int, int>{
    0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026,
    0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160,
    0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019,
    0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
    0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153,
    0x9E: 0x017E, 0x9F: 0x0178,
  };
  special.forEach((k, v) => m[k] = String.fromCharCode(v));
  return m;
}

// --- MacRomanEncoding (high range) -------------------------------------------

final Map<int, String> _macRoman = _buildMacRoman();

Map<int, String> _buildMacRoman() {
  final m = <int, String>{};
  for (var c = 0x20; c <= 0x7E; c++) {
    m[c] = String.fromCharCode(c);
  }
  const high = <int, int>{
    0x80: 0xC4, 0x81: 0xC5, 0x82: 0xC7, 0x83: 0xC9, 0x84: 0xD1, 0x85: 0xD6,
    0x86: 0xDC, 0x87: 0xE1, 0x88: 0xE0, 0x89: 0xE2, 0x8A: 0xE4, 0x8B: 0xE3,
    0x8C: 0xE5, 0x8D: 0xE7, 0x8E: 0xE9, 0x8F: 0xE8, 0x90: 0xEA, 0x91: 0xEB,
    0x92: 0xED, 0x93: 0xEC, 0x94: 0xEE, 0x95: 0xEF, 0x96: 0xF1, 0x97: 0xF3,
    0x98: 0xF2, 0x99: 0xF4, 0x9A: 0xF6, 0x9B: 0xF5, 0x9C: 0xFA, 0x9D: 0xF9,
    0x9E: 0xFB, 0x9F: 0xFC, 0xA0: 0x2020, 0xA1: 0xB0, 0xA2: 0xA2, 0xA3: 0xA3,
    0xA4: 0xA7, 0xA5: 0x2022, 0xA6: 0xB6, 0xA7: 0xDF, 0xA8: 0xAE, 0xA9: 0xA9,
    0xAA: 0x2122, 0xAB: 0xB4, 0xAC: 0xA8, 0xAD: 0x2260, 0xAE: 0xC6, 0xAF: 0xD8,
    0xB0: 0x221E, 0xB1: 0xB1, 0xB2: 0x2264, 0xB3: 0x2265, 0xB4: 0xA5, 0xB5: 0xB5,
    0xB6: 0x2202, 0xB7: 0x2211, 0xB8: 0x220F, 0xB9: 0x3C0, 0xBA: 0x222B,
    0xBB: 0xAA, 0xBC: 0xBA, 0xBD: 0x3A9, 0xBE: 0xE6, 0xBF: 0xF8, 0xC0: 0xBF,
    0xC1: 0xA1, 0xC2: 0xAC, 0xC3: 0x221A, 0xC4: 0x192, 0xC5: 0x2248,
    0xC6: 0x2206, 0xC7: 0xAB, 0xC8: 0xBB, 0xC9: 0x2026, 0xCA: 0xA0, 0xCB: 0xC0,
    0xCC: 0xC3, 0xCD: 0xD5, 0xCE: 0x152, 0xCF: 0x153, 0xD0: 0x2013, 0xD1: 0x2014,
    0xD2: 0x201C, 0xD3: 0x201D, 0xD4: 0x2018, 0xD5: 0x2019, 0xD6: 0xF7,
    0xD7: 0x25CA, 0xD8: 0xFF, 0xD9: 0x178, 0xDA: 0x2044, 0xDB: 0x20AC,
    0xDC: 0x2039, 0xDD: 0x203A, 0xDE: 0xFB01, 0xDF: 0xFB02, 0xE0: 0x2021,
    0xE1: 0xB7, 0xE2: 0x201A, 0xE3: 0x201E, 0xE4: 0x2030, 0xE5: 0xC2,
    0xE6: 0xCA, 0xE7: 0xC1, 0xE8: 0xCB, 0xE9: 0xC8, 0xEA: 0xCD, 0xEB: 0xCE,
    0xEC: 0xCF, 0xED: 0xCC, 0xEE: 0xD3, 0xEF: 0xD4, 0xF1: 0xD2, 0xF2: 0xDA,
    0xF3: 0xDB, 0xF4: 0xD9, 0xF5: 0x131, 0xF6: 0x2C6, 0xF7: 0x2DC, 0xF8: 0xAF,
    0xF9: 0x2D8, 0xFA: 0x2D9, 0xFB: 0x2DA, 0xFC: 0xB8, 0xFD: 0x2DD, 0xFE: 0x2DB,
    0xFF: 0x2C7,
  };
  high.forEach((k, v) => m[k] = String.fromCharCode(v));
  return m;
}

// --- Adobe Glyph List subset --------------------------------------------------

final Map<String, String> _agl = {
  // ASCII punctuation / digits (letters resolve via single-char rule).
  'space': ' ', 'exclam': '!', 'quotedbl': '"', 'numbersign': '#',
  'dollar': r'$', 'percent': '%', 'ampersand': '&', 'quotesingle': "'",
  'parenleft': '(', 'parenright': ')', 'asterisk': '*', 'plus': '+',
  'comma': ',', 'hyphen': '-', 'period': '.', 'slash': '/', 'colon': ':',
  'semicolon': ';', 'less': '<', 'equal': '=', 'greater': '>', 'question': '?',
  'at': '@', 'bracketleft': '[', 'backslash': r'\', 'bracketright': ']',
  'asciicircum': '^', 'underscore': '_', 'grave': '`', 'braceleft': '{',
  'bar': '|', 'braceright': '}', 'asciitilde': '~',
  'zero': '0', 'one': '1', 'two': '2', 'three': '3', 'four': '4', 'five': '5',
  'six': '6', 'seven': '7', 'eight': '8', 'nine': '9',
  // Latin-1 accented and symbols.
  'exclamdown': '\u00A1', 'cent': '\u00A2', 'sterling': '\u00A3',
  'currency': '\u00A4', 'yen': '\u00A5', 'brokenbar': '\u00A6',
  'section': '\u00A7', 'dieresis': '\u00A8', 'copyright': '\u00A9',
  'ordfeminine': '\u00AA', 'guillemotleft': '\u00AB', 'logicalnot': '\u00AC',
  'registered': '\u00AE', 'macron': '\u00AF', 'degree': '\u00B0',
  'plusminus': '\u00B1', 'acute': '\u00B4', 'mu': '\u00B5',
  'paragraph': '\u00B6', 'periodcentered': '\u00B7', 'cedilla': '\u00B8',
  'ordmasculine': '\u00BA', 'guillemotright': '\u00BB', 'onequarter': '\u00BC',
  'onehalf': '\u00BD', 'threequarters': '\u00BE', 'questiondown': '\u00BF',
  'Agrave': '\u00C0', 'Aacute': '\u00C1', 'Acircumflex': '\u00C2',
  'Atilde': '\u00C3', 'Adieresis': '\u00C4', 'Aring': '\u00C5', 'AE': '\u00C6',
  'Ccedilla': '\u00C7', 'Egrave': '\u00C8', 'Eacute': '\u00C9',
  'Ecircumflex': '\u00CA', 'Edieresis': '\u00CB', 'Igrave': '\u00CC',
  'Iacute': '\u00CD', 'Icircumflex': '\u00CE', 'Idieresis': '\u00CF',
  'Eth': '\u00D0', 'Ntilde': '\u00D1', 'Ograve': '\u00D2', 'Oacute': '\u00D3',
  'Ocircumflex': '\u00D4', 'Otilde': '\u00D5', 'Odieresis': '\u00D6',
  'multiply': '\u00D7', 'Oslash': '\u00D8', 'Ugrave': '\u00D9',
  'Uacute': '\u00DA', 'Ucircumflex': '\u00DB', 'Udieresis': '\u00DC',
  'Yacute': '\u00DD', 'Thorn': '\u00DE', 'germandbls': '\u00DF',
  'agrave': '\u00E0', 'aacute': '\u00E1', 'acircumflex': '\u00E2',
  'atilde': '\u00E3', 'adieresis': '\u00E4', 'aring': '\u00E5', 'ae': '\u00E6',
  'ccedilla': '\u00E7', 'egrave': '\u00E8', 'eacute': '\u00E9',
  'ecircumflex': '\u00EA', 'edieresis': '\u00EB', 'igrave': '\u00EC',
  'iacute': '\u00ED', 'icircumflex': '\u00EE', 'idieresis': '\u00EF',
  'eth': '\u00F0', 'ntilde': '\u00F1', 'ograve': '\u00F2', 'oacute': '\u00F3',
  'ocircumflex': '\u00F4', 'otilde': '\u00F5', 'odieresis': '\u00F6',
  'divide': '\u00F7', 'oslash': '\u00F8', 'ugrave': '\u00F9', 'uacute': '\u00FA',
  'ucircumflex': '\u00FB', 'udieresis': '\u00FC', 'yacute': '\u00FD',
  'thorn': '\u00FE', 'ydieresis': '\u00FF',
  // Latin Extended-A / typographic.
  'OE': '\u0152', 'oe': '\u0153', 'Scaron': '\u0160', 'scaron': '\u0161',
  'Ydieresis': '\u0178', 'Zcaron': '\u017D', 'zcaron': '\u017E',
  'florin': '\u0192', 'circumflex': '\u02C6', 'caron': '\u02C7',
  'tilde': '\u02DC', 'dotlessi': '\u0131',
  'quoteleft': '\u2018', 'quoteright': '\u2019', 'quotesinglbase': '\u201A',
  'quotedblleft': '\u201C', 'quotedblright': '\u201D', 'quotedblbase': '\u201E',
  'dagger': '\u2020', 'daggerdbl': '\u2021', 'bullet': '\u2022',
  'ellipsis': '\u2026', 'perthousand': '\u2030', 'guilsinglleft': '\u2039',
  'guilsinglright': '\u203A', 'fraction': '\u2044', 'Euro': '\u20AC',
  'trademark': '\u2122', 'minus': '\u2212', 'endash': '\u2013',
  'emdash': '\u2014', 'fi': '\uFB01', 'fl': '\uFB02', 'nbspace': '\u00A0',
};
