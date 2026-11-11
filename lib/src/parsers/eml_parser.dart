import 'dart:convert';
import 'dart:typed_data';

import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_options.dart';
import '../core/parse_result.dart';
import '../core/structured_artifacts.dart';

/// Parser for RFC 822 / MIME email messages (`.eml`, `.msg` text export).
///
/// Detection requires a strict header block (`From:`, `To:`, `Subject:`,
/// `MIME-Version:` followed by a blank line) so ordinary text is never
/// misreported as email. Headers are unfolded, `Content-Type`/`Content-
/// Transfer-Encoding` are honoured, and `base64` / `quoted-printable` bodies
/// are decoded. Attachments are surfaced as [DocumentAttachment]s with digests;
/// nested `message/rfc822` parts are parsed recursively when enabled.
final class EmlParser
    implements
        DocumentParser,
        OptionAwareDocumentParser,
        HintAwareDocumentParser {
  const EmlParser();

  static const _requiredHeaders = {'from', 'to', 'subject', 'mime-version'};

  @override
  DocumentFormat get format => DocumentFormat.eml;

  String get parserVersion => parserImplementationVersion;

  @override
  bool canParse(Uint8List bytes) {
    final prefix = _peek(bytes, 4096);
    if (prefix.isEmpty) return false;
    final headers = _splitHeaders(prefix).$1;
    final names = headers.keys.toSet();
    return _requiredHeaders.every((h) => names.contains(h));
  }

  @override
  bool canParseWithHints(Uint8List bytes, DocumentHints hints) {
    if (!canParse(bytes)) return false;
    final ext = hints.extension ?? '';
    if (ext.isEmpty) return true;
    return switch (ext) {
      'eml' || 'msg' || 'mbox' => true,
      _ => false,
    };
  }

  @override
  ParseResult parse(Uint8List bytes, {required ContentHasher hasher}) =>
      parseWithOptions(bytes, hasher: hasher);

  @override
  ParseResult parseWithOptions(
    Uint8List bytes, {
    required ContentHasher hasher,
    ParseOptions options = const ParseOptions(),
    DocumentHints? hints,
  }) {
    final digest = hasher.digestFor(bytes);
    final source = _decodeBytes(bytes);
    final (headers, body) = _splitHeaders(source);

    final warnings = <ParseWarning>[];
    final metadata = <String, Object?>{};

    final from = _unfold(headers['from'] ?? '');
    final to = _unfold(headers['to'] ?? '');
    final cc = _unfold(headers['cc'] ?? '');
    final date = _unfold(headers['date'] ?? '');
    final subject = _decodeEncodedWords(_unfold(headers['subject'] ?? ''));
    final messageId = _unfold(headers['message-id'] ?? '');
    final inReplyTo = _unfold(headers['in-reply-to'] ?? '');
    final references = _unfold(headers['references'] ?? '');

    if (from.isNotEmpty) metadata['from'] = from;
    if (to.isNotEmpty) metadata['to'] = to;
    if (cc.isNotEmpty) metadata['cc'] = cc;
    if (date.isNotEmpty) metadata['date'] = date;
    if (subject.isNotEmpty) metadata['subject'] = subject;
    if (messageId.isNotEmpty) metadata['messageId'] = messageId;
    if (inReplyTo.isNotEmpty) metadata['inReplyTo'] = inReplyTo;
    if (references.isNotEmpty) metadata['references'] = references;

    final contentType = _unfold(headers['content-type'] ?? '');
    final contentTransfer = _unfold(headers['content-transfer-encoding'] ?? '');
    final mimeParams = _mimeParameters(contentType);
    final boundary = mimeParams['boundary'];

    final textParts = <String>[];
    final htmlParts = <String>[];
    final attachments = <DocumentAttachment>[];
    var totalAttachmentBytes = 0;

    if (boundary == null || boundary.isEmpty) {
      final ct = mimeParams['content-type'] ?? 'text/plain';
      final charset = mimeParams['charset'] ?? 'utf-8';
      final decoded = _transferDecode(body, contentTransfer);
      final text = _charsetDecode(decoded, charset);
      if (ct.contains('html')) {
        htmlParts.add(text);
      } else {
        textParts.add(text);
      }
    } else {
      final parts = _splitMimeParts(body, boundary);
      for (final part in parts) {
        if (attachments.length >= options.limits.maxAttachments) {
          warnings.add(
            const ParseWarning(
              'eml.attachment_limit',
              'attachment count exceeded the configured limit',
            ),
          );
          break;
        }
        final (pHeaders, pBody) = _splitHeaders(part);
        final pCte = _unfold(pHeaders['content-transfer-encoding'] ?? '');
        final pCt = _unfold(pHeaders['content-type'] ?? '');
        final pParams = _mimeParameters(pCt);
        final pBoundary = pParams['boundary'];
        final disposition = _unfold(pHeaders['content-disposition'] ?? '');
        final filename =
            pParams['name'] ??
            _filenameParam(disposition) ??
            _unfold(pHeaders['content-name'] ?? '');
        final isAttachment =
            disposition.contains('attachment') || filename.isNotEmpty;

        if (pBoundary != null && pBoundary.isNotEmpty) {
          for (final sub in _splitMimeParts(pBody, pBoundary)) {
            final (sHeaders, sBody) = _splitHeaders(sub);
            final subDecoded = _transferDecode(
              sBody,
              _unfold(sHeaders['content-transfer-encoding'] ?? ''),
            );
            final subCt = _mimeParameters(
              _unfold(sHeaders['content-type'] ?? ''),
            );
            final subCharset = subCt['charset'] ?? 'utf-8';
            final subText = _charsetDecode(subDecoded, subCharset);
            final subContentType = subCt['content-type'] ?? '';
            if (subContentType.contains('html')) {
              htmlParts.add(subText);
            } else {
              textParts.add(subText);
            }
          }
          continue;
        }

        if (isAttachment) {
          final decoded = _transferDecode(pBody, pCte);
          if (totalAttachmentBytes + decoded.length >
              options.limits.maxAttachmentBytes) {
            warnings.add(
              const ParseWarning(
                'eml.attachment_byte_limit',
                'attachment payloads exceeded the configured byte limit',
              ),
            );
            continue;
          }
          totalAttachmentBytes += decoded.length;
          final mediaType =
              pParams['content-type'] ??
              _mediaTypeFromName(filename) ??
              'application/octet-stream';
          var attachment = DocumentAttachment(
            name: filename.isEmpty ? 'attachment' : filename,
            mediaType: mediaType,
            size: decoded.length,
            digest: hasher.digestFor(decoded),
            bytes: options.includeAttachmentBytes ? decoded : null,
            path: [filename],
          );
          if (options.parseAttachments &&
              attachment.mediaType == 'message/rfc822' &&
              attachment.bytes != null) {
            final child = parseWithOptions(
              attachment.bytes!,
              hasher: hasher,
              options: options.copyWith(
                parseAttachments: false,
                includeAttachmentBytes: false,
              ),
            );
            attachment = attachment.copyWith(child: child);
          }
          attachments.add(attachment);
          continue;
        }

        final decoded = _transferDecode(pBody, pCte);
        final text = _charsetDecode(decoded, pParams['charset'] ?? 'utf-8');
        if (pCt.contains('html') ||
            pParams['content-type']?.contains('html') == true) {
          htmlParts.add(text);
        } else {
          textParts.add(text);
        }
      }
    }

    var text = textParts.join('\n').trim();
    if (text.isEmpty && htmlParts.isNotEmpty) {
      text = _stripHtml(htmlParts.join('\n'));
    }

    return ParseResult(
      documentId: digest.sha256,
      digest: digest,
      format: format,
      byteLength: bytes.length,
      metadata: metadata,
      text: text.isEmpty ? null : text,
      warnings: warnings,
      attachments: attachments,
      parserVersion: parserVersion,
    );
  }

  // --- header parsing -------------------------------------------------------

  /// Splits the source into (headers, body). Headers are unfolded and
  /// lower-cased keys map to unfolded values.
  (Map<String, String>, String) _splitHeaders(String source) {
    final headers = <String, String>{};

    // Find the blank line that terminates headers.
    var blankLineIdx = source.indexOf('\n\n');
    if (blankLineIdx == -1) {
      blankLineIdx = source.indexOf('\r\n\r\n');
    }
    if (blankLineIdx == -1) {
      return (headers, '');
    }

    // Body starts after the blank line and its terminator(s).
    var bodyStart = blankLineIdx + 2;
    if (source[blankLineIdx] == '\r') bodyStart++; // \r\n\r\n -> skip \r\n\n
    while (bodyStart < source.length &&
        (source[bodyStart] == '\r' || source[bodyStart] == '\n')) {
      bodyStart++;
    }
    final body = source.substring(bodyStart);

    // Parse header lines from source[0..blankLineIdx].
    final headerBlock = source.substring(0, blankLineIdx);
    // Normalize line terminators to \n for splitting.
    final normalized = headerBlock.replaceAll('\r\n', '\n');
    String? lastKey;
    for (final rawLine in normalized.split('\n')) {
      final line = rawLine;
      if (line.startsWith(' ') || line.startsWith('\t')) {
        if (lastKey != null) {
          headers[lastKey] = '${headers[lastKey]} ${line.trim()}';
        }
        continue;
      }
      final colon = line.indexOf(':');
      if (colon == -1) continue;
      final name = line.substring(0, colon).trim().toLowerCase();
      final value = line.substring(colon + 1).trim();
      headers[name] = value;
      lastKey = name;
    }

    return (headers, body);
  }

  static String _unfold(String value) =>
      value.replaceAll(RegExp(r'\r?\n[ \t]+'), ' ').trim();

  String? _filenameParam(String disposition) {
    final match = RegExp(
      r'filename\*?=(?:"([^"]*)"|([^;\s]*))',
      caseSensitive: false,
    ).firstMatch(disposition);
    if (match == null) return null;
    return (match.group(1) ?? match.group(2))?.trim();
  }

  static Map<String, String> _mimeParameters(String contentType) {
    final out = <String, String>{};
    var rest = contentType;
    final semi = rest.indexOf(';');
    if (semi != -1) {
      out['content-type'] = rest.substring(0, semi).trim().toLowerCase();
      rest = rest.substring(semi + 1);
    } else {
      out['content-type'] = rest.trim().toLowerCase();
      return out;
    }
    for (final param in rest.split(';')) {
      final eq = param.indexOf('=');
      if (eq == -1) continue;
      final key = param.substring(0, eq).trim().toLowerCase();
      var val = param.substring(eq + 1).trim();
      if (val.startsWith('"') && val.endsWith('"') && val.length > 1) {
        val = val.substring(1, val.length - 1);
      }
      out[key] = val;
    }
    return out;
  }

  // --- body decoding --------------------------------------------------------

  List<String> _splitMimeParts(String body, String boundary) {
    final out = <String>[];
    final marker = '--$boundary';
    final endMarker = '--$boundary--';
    for (final part in body.split(marker)) {
      if (part.isEmpty || part == endMarker || part.startsWith(endMarker)) {
        continue;
      }
      final trimmed = part.startsWith('\r\n')
          ? part.substring(2)
          : (part.startsWith('\n') ? part.substring(1) : part);
      out.add(trimmed);
    }
    return out;
  }

  Uint8List _transferDecode(String body, String encoding) {
    final bytes = latin1.encode(body.trimRight());
    return switch (encoding.toLowerCase()) {
      'base64' => _base64Decode(bytes),
      'quoted-printable' || 'quotedprintable' => _qpDecode(bytes),
      '8bit' || '7bit' || 'binary' || '' => bytes,
      _ => bytes,
    };
  }

  Uint8List _base64Decode(Uint8List data) {
    final clean = StringBuffer();
    for (final b in data) {
      final c = String.fromCharCode(b);
      if (c.contains(RegExp(r'[A-Za-z0-9+/=]'))) {
        clean.write(c);
      }
    }
    try {
      return Uint8List.fromList(base64.decode(clean.toString()));
    } catch (_) {
      return Uint8List(0);
    }
  }

  Uint8List _qpDecode(Uint8List data) {
    final out = <int>[];
    var i = 0;
    while (i < data.length) {
      final c = data[i];
      if (c == 0x3D && i + 2 < data.length) {
        final hex = String.fromCharCodes(data.sublist(i + 1, i + 3));
        final value = int.tryParse(hex, radix: 16);
        if (value != null) {
          out.add(value);
          i += 3;
          continue;
        }
      }
      if (c == 0x5F) {
        out.add(0x20);
      } else {
        out.add(c);
      }
      i++;
    }
    return Uint8List.fromList(out);
  }

  String _charsetDecode(Uint8List bytes, String charset) {
    try {
      switch (charset.toLowerCase()) {
        case 'utf-8' || 'utf8':
          return utf8.decode(bytes, allowMalformed: true);
        case 'iso-8859-1' || 'latin-1' || 'latin1':
          return latin1.decode(bytes, allowInvalid: true);
        case 'iso-8859-15' || 'latin9':
          return latin1.decode(bytes, allowInvalid: true);
        case 'us-ascii' || 'ascii':
          return ascii.decode(bytes, allowInvalid: true);
        case 'utf-16le' || 'utf-16be' || 'utf-16' || 'utf16':
          // UTF-16 email bodies are rare; decode conservatively as Latin-1
          // so callers can apply the correct charset themselves.
          return latin1.decode(bytes, allowInvalid: true);
        default:
          return latin1.decode(bytes, allowInvalid: true);
      }
    } catch (_) {
      return latin1.decode(bytes, allowInvalid: true);
    }
  }

  static String _decodeEncodedWords(String value) {
    return value.replaceAllMapped(
      RegExp(r'=\?([^?]*)\?([QBqb])\?(.*?)\?=', dotAll: true),
      (m) {
        final charset = m.group(1) ?? 'utf-8';
        final encoding = m.group(2)!;
        final encoded = m.group(3) ?? '';
        try {
          final decoded = switch (encoding.toUpperCase()) {
            'Q' => _qpDecodeStatic(latin1.encode(encoded)),
            'B' => _base64DecodeStatic(latin1.encode(encoded)),
            _ => latin1.encode(encoded),
          };
          return _charsetDecodeStatic(decoded, charset);
        } catch (_) {
          return m.group(0)!;
        }
      },
    );
  }

  static Uint8List _qpDecodeStatic(Uint8List data) {
    final out = <int>[];
    var i = 0;
    while (i < data.length) {
      final c = data[i];
      if (c == 0x3D && i + 2 < data.length) {
        final hex = String.fromCharCodes(data.sublist(i + 1, i + 3));
        final value = int.tryParse(hex, radix: 16);
        if (value != null) {
          out.add(value);
          i += 3;
          continue;
        }
      }
      if (c == 0x5F) {
        out.add(0x20);
      } else {
        out.add(c);
      }
      i++;
    }
    return Uint8List.fromList(out);
  }

  static Uint8List _base64DecodeStatic(Uint8List data) {
    final clean = StringBuffer();
    for (final b in data) {
      final c = String.fromCharCode(b);
      if (c.contains(RegExp(r'[A-Za-z0-9+/=]'))) {
        clean.write(c);
      }
    }
    try {
      return Uint8List.fromList(base64.decode(clean.toString()));
    } catch (_) {
      return Uint8List(0);
    }
  }

  static String _charsetDecodeStatic(Uint8List bytes, String charset) {
    try {
      switch (charset.toLowerCase()) {
        case 'utf-8' || 'utf8':
          return utf8.decode(bytes, allowMalformed: true);
        case 'iso-8859-1' || 'latin-1' || 'latin1':
          return latin1.decode(bytes, allowInvalid: true);
        case 'us-ascii' || 'ascii':
          return ascii.decode(bytes, allowInvalid: true);
        default:
          return latin1.decode(bytes, allowInvalid: true);
      }
    } catch (_) {
      return latin1.decode(bytes, allowInvalid: true);
    }
  }

  static String _stripHtml(String html) {
    var text = html.replaceAll(
      RegExp(r'<(script|style)[^>]*>.*?</\1>', dotAll: true),
      ' ',
    );
    text = text.replaceAll(
      RegExp(r'</?(p|div|h[1-6]|br|li|tr|blockquote|pre)[^>]*>'),
      '\n',
    );
    text = text.replaceAll(RegExp(r'<[^>]*>'), ' ');
    text = text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&nbsp;', ' ');
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String? _mediaTypeFromName(String? name) {
    if (name == null) return null;
    final n = name.toLowerCase();
    if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
    if (n.endsWith('.png')) return 'image/png';
    if (n.endsWith('.gif')) return 'image/gif';
    if (n.endsWith('.pdf')) return 'application/pdf';
    if (n.endsWith('.zip')) return 'application/zip';
    if (n.endsWith('.xml')) return 'application/xml';
    if (n.endsWith('.json')) return 'application/json';
    if (n.endsWith('.txt')) return 'text/plain';
    if (n.endsWith('.html') || n.endsWith('.htm')) return 'text/html';
    if (n.endsWith('.eml')) return 'message/rfc822';
    return null;
  }

  String _peek(Uint8List bytes, int max) {
    final slice = bytes.length <= max
        ? bytes
        : Uint8List.sublistView(bytes, 0, max);
    try {
      return latin1.decode(slice, allowInvalid: true);
    } catch (_) {
      return '';
    }
  }

  String _decodeBytes(Uint8List bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      return latin1.decode(bytes, allowInvalid: true);
    } catch (_) {
      return latin1.decode(bytes, allowInvalid: true);
    }
  }
}
