import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_exception.dart';
import '../core/parse_result.dart';

/// Parser for OpenDocument Format files (ODT/ODS/ODP — ISO/IEC 26300).
///
/// ODF is a ZIP container. Recognition checks the ZIP local-file-header magic
/// *and* peeks the uncompressed `mimetype` entry (which OpenDocument requires to
/// be the first, STORED entry) so a generic ZIP is never misreported as ODF.
/// Text is harvested from `content.xml`.
final class OdfParser implements DocumentParser {
  const OdfParser();

  static const _odfMimePrefix = 'application/vnd.oasis.opendocument';

  @override
  DocumentFormat get format => DocumentFormat.odf;

  @override
  bool canParse(Uint8List bytes) {
    if (bytes.length < 4) return false;
    // ZIP local file header: 'P' 'K' 0x03 0x04
    if (bytes[0] != 0x50 ||
        bytes[1] != 0x4B ||
        bytes[2] != 0x03 ||
        bytes[3] != 0x04) {
      return false;
    }
    // The OpenDocument spec mandates an uncompressed `mimetype` member as the
    // first entry; its content appears verbatim near the start of the archive.
    final head = ascii.decode(
      Uint8List.sublistView(bytes, 0, bytes.length.clamp(0, 256)),
      allowInvalid: true,
    );
    return head.contains('mimetype') && head.contains(_odfMimePrefix);
  }

  @override
  ParseResult parse(Uint8List bytes, {required ContentHasher hasher}) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw MalformedDocumentException('corrupt ODF (ZIP) container: $e');
    }

    final mimetype = _readEntry(archive, 'mimetype');
    final mime = mimetype == null
        ? null
        : ascii.decode(mimetype, allowInvalid: true).trim();
    if (mime == null || !mime.startsWith(_odfMimePrefix)) {
      throw const MalformedDocumentException(
        'ODF mimetype entry missing or invalid',
      );
    }

    final contentBytes = _readEntry(archive, 'content.xml');
    if (contentBytes == null) {
      throw const MalformedDocumentException(
        'content.xml not found in ODF container',
      );
    }

    final XmlDocument content;
    try {
      content = XmlDocument.parse(utf8.decode(contentBytes));
    } on XmlException catch (e) {
      throw MalformedDocumentException('invalid content.xml: ${e.message}');
    } on FormatException catch (e) {
      throw TextDecodingException(
        'content.xml is not valid UTF-8: ${e.message}',
      );
    }

    final paragraphs = <String>[];
    for (final p in content.findAllElements('p', namespace: '*')) {
      final t = p.innerText.trim();
      if (t.isNotEmpty) paragraphs.add(t);
    }

    final meta = _readMeta(archive);

    return ParseResult(
      documentId: hasher.idFor(bytes),
      format: format,
      byteLength: bytes.length,
      metadata: {
        'mimetype': mime,
        'documentClass': mime.substring(_odfMimePrefix.length + 1),
        'paragraphCount': paragraphs.length,
        ...meta,
      },
      text: paragraphs.join('\n'),
    );
  }

  Map<String, Object?> _readMeta(Archive archive) {
    final metaBytes = _readEntry(archive, 'meta.xml');
    if (metaBytes == null) return const {};
    try {
      final doc = XmlDocument.parse(utf8.decode(metaBytes));
      final title = doc
          .findAllElements('title', namespace: '*')
          .firstOrNull
          ?.innerText;
      final creator = doc
          .findAllElements('creator', namespace: '*')
          .firstOrNull
          ?.innerText;
      return {
        if (title != null && title.isNotEmpty) 'title': title,
        if (creator != null && creator.isNotEmpty) 'creator': creator,
      };
    } catch (_) {
      return const {};
    }
  }

  Uint8List? _readEntry(Archive archive, String name) {
    for (final file in archive.files) {
      if (file.isFile && file.name == name) {
        return Uint8List.fromList(file.content as List<int>);
      }
    }
    return null;
  }
}
