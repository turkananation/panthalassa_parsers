import 'dart:convert';
import 'dart:typed_data';

import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_exception.dart';
import '../core/parse_result.dart';
import 'pdf/pdf_internals.dart';
import 'pdf/pdf_text.dart';
import 'pdf/pdf_visual.dart';

/// Public parser for PDF documents.
///
/// Extracts per-page text — decrypting RC4/AES-protected documents, decoding
/// object and cross-reference streams, resolving font encodings and ToUnicode
/// maps, and recursing into form XObjects — plus document metadata, permission
/// flags, and PDF/A-3 associated files (whose XML/JSON payloads are folded into
/// the extracted text).
final class PdfParser implements DocumentParser {
  const PdfParser();

  @override
  DocumentFormat get format => DocumentFormat.pdf;

  @override
  bool canParse(Uint8List bytes) {
    // The %PDF- marker must appear at or very near the start (the spec allows a
    // small amount of leading garbage, so scan the first 1 KiB).
    final limit = bytes.length < 1024 ? bytes.length : 1024;
    final head = latin1.decode(
      Uint8List.sublistView(bytes, 0, limit),
      allowInvalid: true,
    );
    return head.contains('%PDF-');
  }

  @override
  ParseResult parse(Uint8List bytes, {required ContentHasher hasher}) {
    final PdfDocument doc;
    try {
      doc = PdfDocument.parse(bytes);
    } on ParseException {
      rethrow;
    } catch (e) {
      throw MalformedDocumentException('failed to parse PDF structure: $e');
    }

    final warnings = <ParseWarning>[];
    final pages = doc.pages();
    final pageTexts = <String>[];
    for (final page in pages) {
      try {
        pageTexts.add(ContentTextExtractor.extractPage(doc, page));
      } catch (e) {
        warnings.add(
          ParseWarning(
            'pdf.page_extract_failed',
            'a page could not be extracted: $e',
          ),
        );
        pageTexts.add('');
      }
    }

    final pageText = pageTexts.join('\n\f\n').trim();
    if (pages.isNotEmpty && pageText.isEmpty) {
      warnings.add(
        const ParseWarning(
          'pdf.no_text_extracted',
          'pages found but no text recovered; the document may use a scanned '
              'image layer or CID fonts without ToUnicode',
        ),
      );
    }

    // PDF/A-3 (and PDF 2.0) can carry associated files — e.g. the hybrid
    // invoice XML in ZUGFeRD/Factur-X. Surface them and fold any textual
    // payload into the extracted content.
    final embedded = _extractEmbeddedFiles(doc);
    final text = embedded.text.isEmpty
        ? pageText
        : (pageText.isEmpty
              ? embedded.text
              : '$pageText\n\f\n${embedded.text}');

    final info = doc.info;
    String? infoString(String key) {
      final v = doc.resolve(info?[key]);
      return v is PdfString ? v.latin1Value.trim() : null;
    }

    final encryptDict = doc.resolve(doc.trailer?['Encrypt']);
    final permissionsValue = encryptDict is PdfDict
        ? doc.resolve(encryptDict['P'])
        : null;
    final permissions = permissionsValue is PdfNumber
        ? _permissionFlags(permissionsValue.value.toInt())
        : null;
    final visualPages = PdfVisualExtractor.extract(doc, pages);

    return ParseResult(
      documentId: hasher.idFor(bytes),
      format: format,
      byteLength: bytes.length,
      metadata: {
        'pdfVersion': doc.version,
        'pageCount': pages.length,
        if (visualPages.isNotEmpty) 'visualPages': visualPages,
        if (infoString('Title') != null) 'title': infoString('Title'),
        if (infoString('Author') != null) 'author': infoString('Author'),
        if (infoString('Subject') != null) 'subject': infoString('Subject'),
        if (infoString('Keywords') != null) 'keywords': infoString('Keywords'),
        if (infoString('Producer') != null) 'producer': infoString('Producer'),
        if (infoString('Creator') != null) 'creator': infoString('Creator'),
        if (infoString('CreationDate') != null)
          'creationDate': infoString('CreationDate'),
        if (infoString('ModDate') != null) 'modDate': infoString('ModDate'),
        if (doc.encryptionLabel != null) 'encrypted': true,
        if (doc.encryptionLabel != null) 'encryption': doc.encryptionLabel,
        'permissions': ?permissions,
        if (embedded.files.isNotEmpty)
          'embeddedFileCount': embedded.files.length,
        if (embedded.files.isNotEmpty) 'embeddedFiles': embedded.files,
        if (embedded.hasAssociatedFiles) 'pdfA3': true,
      },
      text: text.isEmpty ? null : text,
      warnings: warnings,
    );
  }

  /// Decodes the Standard security handler permission bits (PDF 7.6.3.2).
  Map<String, bool> _permissionFlags(int p) => {
    'print': p & (1 << 2) != 0,
    'modify': p & (1 << 3) != 0,
    'copy': p & (1 << 4) != 0,
    'annotate': p & (1 << 5) != 0,
    'fillForms': p & (1 << 8) != 0,
    'extractAccessibility': p & (1 << 9) != 0,
    'assemble': p & (1 << 10) != 0,
    'printHighRes': p & (1 << 11) != 0,
  };

  /// Collects embedded files from the catalog `/Names /EmbeddedFiles` name tree
  /// and the `/AF` associated-files array, returning their metadata, any text
  /// recovered from XML/JSON/text payloads, and whether associated files exist
  /// (the PDF/A-3 signal).
  ({List<Map<String, Object?>> files, String text, bool hasAssociatedFiles})
  _extractEmbeddedFiles(PdfDocument doc) {
    final cat = doc.catalog;
    if (cat == null) {
      return (files: const [], text: '', hasAssociatedFiles: false);
    }

    final filespecs = <PdfDict>[];
    final seen = <PdfDict>{};
    void addFilespec(PdfObject? fs) {
      final d = doc.resolve(fs);
      if (d is PdfDict && seen.add(d)) filespecs.add(d);
    }

    final names = doc.resolve(cat['Names']);
    if (names is PdfDict) {
      final ef = doc.resolve(names['EmbeddedFiles']);
      if (ef is PdfDict) _walkNameTree(doc, ef, addFilespec, 0);
    }

    final afObj = doc.resolve(cat['AF']);
    final hasAF = afObj is PdfArray && afObj.items.isNotEmpty;
    if (afObj is PdfArray) {
      for (final f in afObj.items) {
        addFilespec(f);
      }
    }

    final files = <Map<String, Object?>>[];
    final textOut = StringBuffer();
    for (final fs in filespecs) {
      final name = _filespecName(doc, fs);
      final relationship = doc.resolve(fs['AFRelationship']);
      Uint8List? data;
      final ef = doc.resolve(fs['EF']);
      if (ef is PdfDict) {
        final stream = doc.resolve(ef['F']) ?? doc.resolve(ef['UF']);
        if (stream is PdfStream) {
          try {
            data = doc.decoded(stream);
          } catch (_) {
            data = null;
          }
        }
      }
      files.add({
        'name': ?name,
        if (data != null) 'size': data.length,
        if (relationship is PdfName) 'relationship': relationship.name,
      });
      if (data != null && _looksTextual(name, data)) {
        textOut.writeln(utf8.decode(data, allowMalformed: true).trim());
      }
    }

    return (
      files: files,
      text: textOut.toString().trimRight(),
      hasAssociatedFiles: hasAF,
    );
  }

  void _walkNameTree(
    PdfDocument doc,
    PdfDict node,
    void Function(PdfObject?) onValue,
    int depth,
  ) {
    if (depth > 32) return;
    final names = doc.resolve(node['Names']);
    if (names is PdfArray) {
      for (var i = 1; i < names.items.length; i += 2) {
        onValue(names.items[i]); // [key value key value …]
      }
    }
    final kids = doc.resolve(node['Kids']);
    if (kids is PdfArray) {
      for (final kid in kids.items) {
        final k = doc.resolve(kid);
        if (k is PdfDict) _walkNameTree(doc, k, onValue, depth + 1);
      }
    }
  }

  String? _filespecName(PdfDocument doc, PdfDict fs) {
    for (final key in const ['UF', 'F']) {
      final v = doc.resolve(fs[key]);
      if (v is PdfString) {
        final s = _pdfTextString(v.bytes).trim();
        if (s.isNotEmpty) return s;
      }
    }
    return null;
  }

  String _pdfTextString(Uint8List b) {
    if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
      final units = <int>[];
      for (var i = 2; i + 1 < b.length; i += 2) {
        units.add((b[i] << 8) | b[i + 1]); // UTF-16BE
      }
      return String.fromCharCodes(units);
    }
    return latin1.decode(b, allowInvalid: true);
  }

  bool _looksTextual(String? name, Uint8List data) {
    final n = name?.toLowerCase() ?? '';
    if (n.endsWith('.xml') ||
        n.endsWith('.json') ||
        n.endsWith('.txt') ||
        n.endsWith('.csv') ||
        n.endsWith('.html')) {
      return true;
    }
    for (final b in data.take(64)) {
      const skip = {0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF};
      if (skip.contains(b)) continue;
      return b == 0x3C || b == 0x7B; // '<' or '{'
    }
    return false;
  }
}
