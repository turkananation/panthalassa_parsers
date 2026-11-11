import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../../core/content_hasher.dart';
import '../../core/parse_options.dart';
import '../../core/parse_result.dart';
import '../../core/structured_artifacts.dart';
import 'pdf_internals.dart';

/// Deep PDF metadata extraction: XMP, outlines, AcroForm fields, annotations,
/// signature envelopes, page labels, embedded files, and encoded image objects.
///
/// Everything here is presence/metadata only. Signatures are never verified and
/// image payloads are passed through in their encoded form (no raster decode).
final class PdfMetadataExtractor {
  PdfMetadataExtractor(
    this.doc,
    this.hasher,
    this.options, {
    required this.fileLength,
    required this.pages,
  });

  final PdfDocument doc;
  final ContentHasher hasher;
  final ParseOptions options;
  final int fileLength;
  final List<PdfDict> pages;

  PdfExtraction extract() {
    final metadata = <String, Object?>{};
    final warnings = <ParseWarning>[];
    final attachments = <DocumentAttachment>[];
    final signatures = <DocumentSignature>[];

    final xmp = _xmp(metadata, warnings);
    if (xmp != null) metadata['xmp'] = xmp;

    final labels = _pageLabels();
    if (labels.isNotEmpty) metadata['pageLabels'] = labels;

    final outline = options.includeOutline
        ? _outline()
        : const <OutlineEntry>[];
    if (outline.isNotEmpty) {
      metadata['outlineCount'] = _countOutline(outline);
    }

    final forms = options.includeFormFields
        ? _formFields()
        : const <Map<String, Object?>>[];
    if (forms.isNotEmpty) metadata['formFields'] = forms;

    if (options.includeSignatures) {
      signatures.addAll(_signatures(forms));
      if (signatures.isNotEmpty) {
        metadata['signatureCount'] = signatures.length;
      }
    }

    if (options.includeAnnotations) {
      final annotations = _annotations();
      if (annotations.isNotEmpty) metadata['annotations'] = annotations;
    }

    if (options.includeAttachments) {
      _embeddedFiles(attachments, warnings);
      _imageObjects(attachments, warnings);
    }

    return PdfExtraction(
      metadata: metadata,
      attachments: attachments,
      signatures: signatures,
      outline: outline,
      warnings: warnings,
      xmpText: xmp == null ? null : _xmpPlainText(xmp),
    );
  }

  // --- XMP ------------------------------------------------------------------

  Map<String, Object?>? _xmp(
    Map<String, Object?> metadata,
    List<ParseWarning> warnings,
  ) {
    final cat = doc.catalog;
    if (cat == null) return null;
    final stream = doc.resolve(cat['Metadata']);
    if (stream is! PdfStream) return null;
    final Uint8List bytes;
    try {
      bytes = doc.decoded(stream);
    } catch (_) {
      warnings.add(
        const ParseWarning(
          'pdf.xmp_decode_failed',
          'XMP stream could not be decoded',
        ),
      );
      return null;
    }
    final source = utf8.decode(bytes, allowMalformed: true);
    if (source.trim().isEmpty) return null;
    final XmlDocument xml;
    try {
      xml = XmlDocument.parse(source);
    } catch (_) {
      warnings.add(
        const ParseWarning(
          'pdf.xmp_parse_failed',
          'XMP stream is not well-formed XML',
        ),
      );
      return null;
    }

    String? text(String local) {
      for (final e in xml.descendantElements) {
        if (e.name.local != local) continue;
        final li = e.descendantElements
            .where((c) => c.name.local == 'li')
            .toList(growable: false);
        if (li.isNotEmpty) {
          final value = li
              .map((c) => c.innerText.trim())
              .where((v) => v.isNotEmpty);
          if (value.isNotEmpty) return value.join('; ');
        }
        final v = e.innerText.trim();
        if (v.isNotEmpty) return v;
      }
      return null;
    }

    final map = <String, Object?>{};
    void put(String key, String local) {
      final v = text(local);
      if (v != null) map[key] = v;
    }

    put('title', 'title');
    put('creator', 'creator');
    put('description', 'description');
    put('subject', 'subject');
    put('keywords', 'Keywords');
    put('createDate', 'CreateDate');
    put('modifyDate', 'ModifyDate');
    put('metadataDate', 'MetadataDate');
    put('producer', 'Producer');
    put('creatorTool', 'CreatorTool');
    put('label', 'Label');
    put('documentId', 'DocumentID');
    put('instanceId', 'InstanceID');
    put('pdfVersion', 'PDFVersion');
    if (map.isNotEmpty) {
      metadata.addAll(map);
    }
    return map.isEmpty ? null : map;
  }

  String? _xmpPlainText(Map<String, Object?> xmp) {
    final values = xmp.values.whereType<String>().where((v) => v.isNotEmpty);
    if (values.isEmpty) return null;
    return values.join('\n');
  }

  // --- Outline --------------------------------------------------------------

  List<OutlineEntry> _outline() {
    final cat = doc.catalog;
    if (cat == null) return const [];
    final outlines = doc.resolve(cat['Outlines']);
    if (outlines is! PdfDict) return const [];
    final out = <OutlineEntry>[];
    var count = 0;
    void walk(PdfDict node, int level, Set<PdfDict> seen, int depth) {
      if (depth > 32) return;
      var item = doc.resolve(node['First']);
      while (item is PdfDict && count < 5000) {
        if (!seen.add(item)) break;
        count++;
        final title = _text(item['Title']);
        final children = <OutlineEntry>[];
        final dest = _destinationPage(item);
        final before = out.length;
        walk(item, level + 1, seen, depth + 1);
        // walk() appends to out; reparent descendants under this entry.
        final descendants = out.sublist(before);
        out.removeRange(before, out.length);
        children.addAll(descendants);
        if (title != null && title.trim().isNotEmpty) {
          out.add(
            OutlineEntry(
              title: title.trim(),
              level: level,
              page: dest,
              children: children,
            ),
          );
        } else {
          out.addAll(children);
        }
        item = doc.resolve(item['Next']);
      }
    }

    walk(outlines, 1, <PdfDict>{}, 0);
    return out;
  }

  int _countOutline(List<OutlineEntry> entries) =>
      entries.fold(entries.length, (sum, e) => sum + _countOutline(e.children));

  int? _destinationPage(PdfDict item) {
    PdfObject? dest = item['Dest'];
    if (dest == null) {
      final action = doc.resolve(item['A']);
      if (action is PdfDict) dest = action['D'];
    }
    final resolvedDest = doc.resolve(dest);
    if (resolvedDest is PdfArray && resolvedDest.items.isNotEmpty) {
      final first = resolvedDest.items.first;
      final index = doc.pageIndexOf(first, pages);
      if (index != null) return index;
      if (first is PdfNumber) return first.value.toInt();
    }
    if (resolvedDest is PdfName) {
      final target = _namedDestination(resolvedDest.name);
      if (target is PdfArray && target.items.isNotEmpty) {
        return doc.pageIndexOf(target.items.first, pages) ??
            (target.items.first is PdfNumber
                ? (target.items.first as PdfNumber).value.toInt()
                : null);
      }
    }
    return null;
  }

  PdfObject? _namedDestination(String name) {
    final cat = doc.catalog;
    if (cat == null) return null;
    final dests = doc.resolve(cat['Dests']);
    if (dests is PdfDict) {
      final d = doc.resolve(dests.entries[name]);
      if (d is PdfDict) return doc.resolve(d['D']);
      if (d != null) return d;
    }
    final names = doc.resolve(cat['Names']);
    if (names is PdfDict) {
      final tree = doc.resolve(names['Dests']);
      if (tree is PdfDict) {
        PdfObject? found;
        void walk(PdfDict node, int depth) {
          if (depth > 32 || found != null) return;
          final arr = doc.resolve(node['Names']);
          if (arr is PdfArray) {
            for (var i = 0; i + 1 < arr.items.length; i += 2) {
              final key = _text(arr.items[i]);
              if (key == name) {
                final value = doc.resolve(arr.items[i + 1]);
                found = value is PdfDict ? doc.resolve(value['D']) : value;
                return;
              }
            }
          }
          final kids = doc.resolve(node['Kids']);
          if (kids is PdfArray) {
            for (final kid in kids.items) {
              final k = doc.resolve(kid);
              if (k is PdfDict) walk(k, depth + 1);
            }
          }
        }

        walk(tree, 0);
        return found;
      }
    }
    return null;
  }

  // --- AcroForm / signatures ------------------------------------------------

  List<Map<String, Object?>> _formFields() {
    final cat = doc.catalog;
    if (cat == null) return const [];
    final form = doc.resolve(cat['AcroForm']);
    if (form is! PdfDict) return const [];
    final fields = doc.resolve(form['Fields']);
    if (fields is! PdfArray) return const [];
    final out = <Map<String, Object?>>[];
    final seen = <PdfDict>{};
    void walk(PdfObject? obj, String? parentName, int depth) {
      if (depth > 32 || out.length >= 5000) return;
      final field = doc.resolve(obj);
      if (field is! PdfDict || !seen.add(field)) return;
      final partial = _text(field['T']);
      final name = partial == null || partial.isEmpty
          ? parentName
          : (parentName == null || parentName.isEmpty
                ? partial
                : '$parentName.$partial');
      final kids = doc.resolve(field['Kids']);
      final hasWidgetKids =
          kids is PdfArray &&
          kids.items.any((k) {
            final kd = doc.resolve(k);
            return kd is PdfDict && _nameEquals(kd['Subtype'], 'Widget');
          });
      if (name != null && name.isNotEmpty) {
        out.add({
          'name': name,
          'type': ?_text(field['FT']),
          'value': ?_fieldValue(field['V']),
          'tooltip': ?_text(field['TU']),
          if (field['Ff'] is PdfNumber)
            'flags': (field['Ff'] as PdfNumber).value.toInt(),
          if (field['F'] is PdfNumber)
            'annotationFlags': (field['F'] as PdfNumber).value.toInt(),
        });
      }
      if (kids is PdfArray && !hasWidgetKids) {
        for (final kid in kids.items) {
          walk(kid, name, depth + 1);
        }
      }
    }

    for (final f in fields.items) {
      walk(f, null, 0);
    }
    return out;
  }

  List<DocumentSignature> _signatures(List<Map<String, Object?>> forms) {
    final out = <DocumentSignature>[];
    final seen = <PdfDict>{};
    void addField(PdfDict field) {
      final value = doc.resolve(field['V']);
      if (value is! PdfDict || !seen.add(value)) return;
      final name = _text(field['T']) ?? _text(value['Name']);
      final byteRangeObj = doc.resolve(value['ByteRange']);
      final byteRange = byteRangeObj is PdfArray
          ? byteRangeObj.items
                .whereType<PdfNumber>()
                .map((n) => n.value.toInt())
                .toList()
          : null;
      bool? coversWhole;
      if (byteRange != null && byteRange.length == 4) {
        final end = byteRange[2] + byteRange[3];
        coversWhole = byteRange[0] == 0 && end >= fileLength;
      }
      out.add(
        DocumentSignature(
          role: 'signature',
          signer: (name == null || name.trim().isEmpty)
              ? 'unknown'
              : name.trim(),
          verified: null,
          algorithm: _signatureAlgorithm(value),
          subFilter: _text(value['SubFilter']),
          signingTime: _text(value['M']),
          byteRange: byteRange,
          coversWholeDocument: coversWhole,
          reason: _text(value['Reason']),
          location: _text(value['Location']),
        ),
      );
    }

    final cat = doc.catalog;
    final acro = cat == null ? null : doc.resolve(cat['AcroForm']);
    if (acro is PdfDict) {
      final fields = doc.resolve(acro['Fields']);
      if (fields is PdfArray) {
        void walk(PdfObject? obj, int depth) {
          if (depth > 32) return;
          final f = doc.resolve(obj);
          if (f is! PdfDict) return;
          if (_nameEquals(f['FT'], 'Sig')) {
            addField(f);
            return;
          }
          final kids = doc.resolve(f['Kids']);
          if (kids is PdfArray) {
            for (final kid in kids.items) {
              walk(kid, depth + 1);
            }
          }
        }

        for (final f in fields.items) {
          walk(f, 0);
        }
      }
    }
    // Also scan raw annotation dictionaries for signature widgets not reachable
    // through a broken AcroForm tree.
    for (final page in pages) {
      final annots = doc.resolve(page['Annots']);
      if (annots is! PdfArray) continue;
      for (final a in annots.items) {
        final annot = doc.resolve(a);
        if (annot is PdfDict && _nameEquals(annot['FT'], 'Sig')) {
          addField(annot);
        }
      }
    }
    return out;
  }

  String? _signatureAlgorithm(PdfDict sig) {
    final sub = _text(sig['SubFilter']);
    final filter = _text(sig['Filter']);
    return switch (sub) {
      'adbe.pkcs7.detached' => 'PKCS#7 detached',
      'adbe.pkcs7.sha1' => 'PKCS#7 SHA-1',
      'adbe.x509.rsa_sha1' => 'X.509 RSA SHA-1',
      'ETSI.CAdES.detached' => 'CAdES detached',
      'ETSI.RFC3161' => 'RFC 3161 timestamp',
      _ => sub ?? filter,
    };
  }

  // --- Annotations ----------------------------------------------------------

  List<Map<String, Object?>> _annotations() {
    final out = <Map<String, Object?>>[];
    for (var i = 0; i < pages.length && out.length < 2000; i++) {
      final annots = doc.resolve(pages[i]['Annots']);
      if (annots is! PdfArray) continue;
      for (final a in annots.items) {
        if (out.length >= 2000) break;
        final annot = doc.resolve(a);
        if (annot is! PdfDict) continue;
        final subtype = _text(annot['Subtype']);
        if (subtype == null) continue;
        final rect = doc.resolve(annot['Rect']);
        final contents = _text(annot['Contents'])?.trim();
        final author = _text(annot['T'])?.trim();
        out.add({
          'pageIndex': i,
          'subtype': subtype,
          if (contents != null && contents.isNotEmpty) 'contents': contents,
          if (author != null && author.isNotEmpty) 'author': author,
          'modified': ?_text(annot['M']),
          if (rect is PdfArray)
            'rect': [
              for (final n in rect.items.take(4))
                if (n is PdfNumber) n.value.toDouble(),
            ],
        });
      }
    }
    return out;
  }

  // --- Page labels ----------------------------------------------------------

  Map<String, String> _pageLabels() {
    final cat = doc.catalog;
    if (cat == null) return const {};
    final labels = doc.resolve(cat['PageLabels']);
    if (labels is! PdfDict) return const {};
    final nums = doc.resolve(labels['Nums']);
    if (nums is! PdfArray) return const {};
    final starts = <int, PdfDict>{};
    for (var i = 0; i + 1 < nums.items.length; i += 2) {
      final index = nums.items[i];
      final dict = doc.resolve(nums.items[i + 1]);
      if (index is PdfNumber && dict is PdfDict) {
        starts[index.value.toInt()] = dict;
      }
    }
    if (starts.isEmpty) return const {};
    final indices = starts.keys.toList()..sort();
    final out = <String, String>{};
    for (var page = 0; page < pages.length; page++) {
      var active = -1;
      for (var i = 0; i < indices.length; i++) {
        if (indices[i] <= page) active = i;
      }
      if (active < 0) continue;
      final dict = starts[indices[active]]!;
      final start = indices[active];
      final st = dict['St'] is PdfNumber
          ? (dict['St'] as PdfNumber).value.toInt()
          : 1;
      final p = _text(dict['P']) ?? '';
      final style = _text(dict['S']);
      final value = st + (page - start);
      out['$page'] = '$p${_formatPageNumber(value, style)}';
    }
    return out;
  }

  String _formatPageNumber(int n, String? style) => switch (style) {
    'r' => _roman(n).toLowerCase(),
    'R' => _roman(n),
    'a' => _alpha(n).toLowerCase(),
    'A' => _alpha(n),
    _ => '$n',
  };

  String _alpha(int n) {
    if (n <= 0) return '';
    final b = StringBuffer();
    var v = n;
    while (v > 0) {
      v--;
      b.writeCharCode(0x41 + (v % 26));
      v ~/= 26;
    }
    return b.toString().split('').reversed.join();
  }

  String _roman(int n) {
    if (n <= 0 || n > 3999) return '$n';
    const table = [
      (1000, 'M'),
      (900, 'CM'),
      (500, 'D'),
      (400, 'CD'),
      (100, 'C'),
      (90, 'XC'),
      (50, 'L'),
      (40, 'XL'),
      (10, 'X'),
      (9, 'IX'),
      (5, 'V'),
      (4, 'IV'),
      (1, 'I'),
    ];
    final b = StringBuffer();
    var v = n;
    for (final (value, symbol) in table) {
      while (v >= value) {
        b.write(symbol);
        v -= value;
      }
    }
    return b.toString();
  }

  // --- Embedded files -------------------------------------------------------

  void _embeddedFiles(
    List<DocumentAttachment> out,
    List<ParseWarning> warnings,
  ) {
    final cat = doc.catalog;
    if (cat == null) return;
    final filespecs = <PdfDict>[];
    final seen = <PdfDict>{};
    void add(PdfObject? fs) {
      final d = doc.resolve(fs);
      if (d is PdfDict && seen.add(d)) filespecs.add(d);
    }

    final names = doc.resolve(cat['Names']);
    if (names is PdfDict) {
      final ef = doc.resolve(names['EmbeddedFiles']);
      if (ef is PdfDict) _walkNameTree(ef, add, 0);
    }
    final af = doc.resolve(cat['AF']);
    if (af is PdfArray) {
      for (final f in af.items) {
        add(f);
      }
    }

    var total = 0;
    for (final fs in filespecs) {
      if (out.length >= options.limits.maxAttachments) {
        warnings.add(
          const ParseWarning(
            'pdf.attachment_limit',
            'embedded-file count exceeded the configured limit',
          ),
        );
        break;
      }
      final name = _filespecName(fs);
      final relationship = _text(fs['AFRelationship']);
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
      if (data != null) {
        if (total + data.length > options.limits.maxAttachmentBytes) {
          warnings.add(
            const ParseWarning(
              'pdf.attachment_byte_limit',
              'embedded-file payloads exceeded the configured byte limit',
            ),
          );
          data = null;
        } else {
          total += data.length;
        }
      }
      final mediaType = _mediaType(name, data);
      String? text;
      if (data != null && _isTextual(mediaType, name)) {
        text = _decodeText(data);
      }
      out.add(
        DocumentAttachment(
          name: name,
          mediaType: mediaType,
          size: data?.length,
          digest: data == null ? null : hasher.digestFor(data),
          bytes: options.includeAttachmentBytes ? data : null,
          text: text,
          path: [name].whereType<String>().toList(),
          relationship: relationship,
        ),
      );
    }
  }

  void _walkNameTree(
    PdfDict node,
    void Function(PdfObject?) onValue,
    int depth,
  ) {
    if (depth > 32) return;
    final names = doc.resolve(node['Names']);
    if (names is PdfArray) {
      for (var i = 1; i < names.items.length; i += 2) {
        onValue(names.items[i]);
      }
    }
    final kids = doc.resolve(node['Kids']);
    if (kids is PdfArray) {
      for (final kid in kids.items) {
        final k = doc.resolve(kid);
        if (k is PdfDict) _walkNameTree(k, onValue, depth + 1);
      }
    }
  }

  String? _filespecName(PdfDict fs) {
    for (final key in const ['UF', 'F']) {
      final v = doc.resolve(fs[key]);
      if (v is PdfString) {
        final s = _pdfTextString(v.bytes).trim();
        if (s.isNotEmpty) return s;
      }
    }
    return null;
  }

  // --- Image XObjects -------------------------------------------------------

  void _imageObjects(
    List<DocumentAttachment> out,
    List<ParseWarning> warnings,
  ) {
    var count = 0;
    var total = 0;
    for (var pageIndex = 0; pageIndex < pages.length; pageIndex++) {
      final resources = doc.resolve(pages[pageIndex]['Resources']);
      if (resources is! PdfDict) continue;
      final xobjects = doc.resolve(resources['XObject']);
      if (xobjects is! PdfDict) continue;
      for (final entry in xobjects.entries.entries) {
        if (count >= options.limits.maxAttachments) {
          warnings.add(
            const ParseWarning(
              'pdf.image_limit',
              'image XObject count exceeded the configured limit',
            ),
          );
          return;
        }
        final stream = doc.resolve(entry.value);
        if (stream is! PdfStream) continue;
        if (!_nameEquals(stream.dict['Subtype'], 'Image')) continue;
        final filters = _filterNames(stream.dict['Filter']);
        final media = _imageMediaType(filters);
        if (media == null) continue;
        Uint8List? data;
        try {
          // Unknown image filters are passed through; DCT/JPX stay encoded.
          data = doc.decoded(stream);
        } catch (_) {
          data = stream.raw;
        }
        if (data.length > options.limits.maxAttachmentBytes - total) {
          warnings.add(
            const ParseWarning(
              'pdf.image_byte_limit',
              'image XObject payloads exceeded the configured byte limit',
            ),
          );
          return;
        }
        total += data.length;
        count++;
        final width = _int(stream.dict['Width']);
        final height = _int(stream.dict['Height']);
        out.add(
          DocumentAttachment(
            name: 'page-${pageIndex + 1}-image-$count',
            mediaType: media,
            size: data.length,
            digest: hasher.digestFor(data),
            bytes: options.includeAttachmentBytes ? data : null,
            path: ['page-${pageIndex + 1}', entry.key],
            text: width != null && height != null ? '${width}x$height' : null,
          ),
        );
      }
    }
  }

  static List<String> _filterNames(PdfObject? filter) {
    if (filter is PdfName) return [filter.name];
    if (filter is PdfArray) {
      return filter.items
          .whereType<PdfName>()
          .map((n) => n.name)
          .toList(growable: false);
    }
    return const [];
  }

  static String? _imageMediaType(List<String> filters) {
    if (filters.isEmpty) return null;
    final last = filters.last;
    return switch (last) {
      'DCTDecode' || 'DCT' => 'image/jpeg',
      'JPXDecode' => 'image/jp2',
      'JBIG2Decode' => 'image/jbig2',
      'CCITTFaxDecode' || 'CCF' => 'image/tiff',
      'FlateDecode' || 'Fl' => 'image/raw',
      'LZWDecode' || 'LZW' => 'image/raw',
      _ => null,
    };
  }

  // --- helpers --------------------------------------------------------------

  static bool _nameEquals(PdfObject? o, String name) =>
      o is PdfName && o.name == name;

  static int? _int(PdfObject? o) => o is PdfNumber ? o.value.toInt() : null;

  String? _fieldValue(PdfObject? value) {
    final v = doc.resolve(value);
    if (v is PdfString) return _pdfTextString(v.bytes);
    if (v is PdfName) return v.name;
    if (v is PdfNumber) return '${v.value}';
    if (v is PdfBool) return '${v.value}';
    if (v is PdfArray) {
      final parts = v.items.map(_fieldValue).whereType<String>().toList();
      return parts.isEmpty ? null : parts.join(', ');
    }
    return null;
  }

  String? _text(PdfObject? obj) {
    final v = doc.resolve(obj);
    if (v is PdfString) return _pdfTextString(v.bytes);
    if (v is PdfName) return v.name;
    if (v is PdfNumber) return '${v.value}';
    if (v is PdfBool) return '${v.value}';
    return null;
  }

  static String _pdfTextString(Uint8List b) {
    if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
      final units = <int>[];
      for (var i = 2; i + 1 < b.length; i += 2) {
        units.add((b[i] << 8) | b[i + 1]);
      }
      return String.fromCharCodes(units);
    }
    if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) {
      return utf8.decode(Uint8List.sublistView(b, 3), allowMalformed: true);
    }
    return latin1.decode(b, allowInvalid: true);
  }

  static String? _mediaType(String? name, Uint8List? data) {
    final n = name?.toLowerCase() ?? '';
    const byExt = {
      '.xml': 'application/xml',
      '.json': 'application/json',
      '.txt': 'text/plain',
      '.csv': 'text/csv',
      '.html': 'text/html',
      '.htm': 'text/html',
      '.pdf': 'application/pdf',
      '.png': 'image/png',
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.gif': 'image/gif',
      '.tif': 'image/tiff',
      '.tiff': 'image/tiff',
      '.zip': 'application/zip',
      '.eml': 'message/rfc822',
    };
    for (final entry in byExt.entries) {
      if (n.endsWith(entry.key)) return entry.value;
    }
    if (data != null && data.length >= 4) {
      if (data[0] == 0x25 &&
          data[1] == 0x50 &&
          data[2] == 0x44 &&
          data[3] == 0x46) {
        return 'application/pdf';
      }
      if (data[0] == 0x50 && data[1] == 0x4B) return 'application/zip';
    }
    return data == null ? null : 'application/octet-stream';
  }

  static bool _isTextual(String? mediaType, String? name) {
    final m = mediaType ?? '';
    if (m.startsWith('text/') ||
        m == 'application/xml' ||
        m == 'application/json' ||
        m.endsWith('+xml') ||
        m.endsWith('+json')) {
      return true;
    }
    final n = name?.toLowerCase() ?? '';
    return n.endsWith('.xml') || n.endsWith('.json') || n.endsWith('.txt');
  }

  static String _decodeText(Uint8List data) {
    if (data.length >= 2 && data[0] == 0xFF && data[1] == 0xFE) {
      final units = <int>[];
      for (var i = 2; i + 1 < data.length; i += 2) {
        units.add(data[i] | (data[i + 1] << 8));
      }
      return String.fromCharCodes(units);
    }
    if (data.length >= 2 && data[0] == 0xFE && data[1] == 0xFF) {
      final units = <int>[];
      for (var i = 2; i + 1 < data.length; i += 2) {
        units.add((data[i] << 8) | data[i + 1]);
      }
      return String.fromCharCodes(units);
    }
    return utf8.decode(data, allowMalformed: true);
  }
}

/// Bundle returned by [PdfMetadataExtractor.extract].
final class PdfExtraction {
  const PdfExtraction({
    required this.metadata,
    required this.attachments,
    required this.signatures,
    required this.outline,
    required this.warnings,
    this.xmpText,
  });

  final Map<String, Object?> metadata;
  final List<DocumentAttachment> attachments;
  final List<DocumentSignature> signatures;
  final List<OutlineEntry> outline;
  final List<ParseWarning> warnings;
  final String? xmpText;
}
