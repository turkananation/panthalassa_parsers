# panthalassa_parsers

Pure-Dart, zero-FFI parsers for structured, binary, and composite document
formats. Produces content-addressed, isolate-safe results for the Panthalassa
Vault. No native dependencies, no `dart:io` — runs on server, Flutter, and web.

## Supported formats

| Format | Detection | Output |
|---|---|---|
| FHIR/XML | FHIR namespace / known resource root | resourceType, id, profile, text |
| UN/EDIFACT | `UNA`/`UNB` prefix | interchange header, message types, segments |
| STEP (ISO 10303-21) | `ISO-10303-21;` token | schema, header, entity-instance index |
| USMTF (MIL-STD-6040) | set-terminated lines + known set IDs | MSGID, set list, text |
| DICOM (PS3.10) | 128-byte preamble + `DICM` | transfer syntax, attributes, SQ items, multi-values |
| NITF 2.1 / NSIF | `NITF`/`NSIF` + version | file header, segment tables/subheaders, text bodies |
| STANAG family | per-standard sub-parsers (see below) | matched standard + its fields |
| PDF | `%PDF-` marker | per-page text, page count, Info metadata |
| ODF (ODT/ODS/ODP) | ZIP magic + `mimetype` member | paragraphs, document class, meta |

The STANAG family covers **4607** (GMTI, binary), **4609** (motion imagery /
MPEG-2 TS + MISB ST 0601 local-set fields), **4676** (NITS tracking + point
kinematics, XML), **4774** (confidentiality label, XML), **4778** (metadata
binding, XML), **7023** (NPIF header/segment index), and **5516** (conservative
Link 16 / TADIL-J framed-message metadata). STANAG 4545 (NSIF) is handled by the
NITF parser.

## Quickstart

```dart
import 'dart:io';
import 'package:panthalassa_parsers/panthalassa_parsers.dart';

Future<void> main(List<String> args) async {
  final bytes = await File(args.first).readAsBytes();
  final registry = ParserRegistry.standard();

  final format = registry.detect(bytes);          // cheap detection
  final result = await registry.parseInIsolate(bytes); // offload CPU work

  print('${result.format.label}  id=${result.documentId}');
  print(result.metadata);
  if (result.hasText) print(result.text);

  final doc = DocumentIr.fromParseResult(result);
  final html = const HtmlDocumentRenderer().render(doc);
  print(html); // escaped semantic HTML for web/Jaspr-style adapters

  final visual = doc.toVisualDocument();
  final svg = const SvgVisualRenderer().render(visual);
  print(svg); // faithful display-list preview where visual pages exist
}
```

Synchronous `registry.parse(bytes)` is available for small inputs. Inject a
custom `ContentHasher` (e.g. backed by the vault's `PqBytes.sha256`) via
`ParserRegistry.standard(hasher: ...)` to keep one hash implementation across the
stack — the default `PqBytesContentHasher` is byte-identical.

## Errors

Every failure is a sealed `ParseException`: `UnsupportedFormatException`,
`MalformedDocumentException`, `TruncatedDocumentException`,
`TextDecodingException`, `UnsupportedFeatureException`. Switch on them
exhaustively. Non-fatal warnings carry stable `ParseWarning.code` values for
UI-side localization; see `docs/ISSUE_CODES.md`.

## Status & limitations

The framework and common structured/EDI/composite parsers are complete for
metadata and text extraction. DICOM now descends SQ items and renders
multi-valued attributes while still stopping before pixel data. NITF walks image,
graphic, text, DES, and RES segment tables/subheaders and extracts text segment
bodies. STANAG now includes 4607 body fields, 4609 MISB KLV local sets, 4676
track kinematics, 7023 NPIF, and conservative 5516 framed-message metadata.

The render engine has a pure-Dart DIR plus text, Markdown, escaped HTML, and a
visual display-list layer. PDF parse results now expose page geometry and
conservative text/rectangle/image-placeholder commands; NITF and DICOM metadata
project to image/frame placeholders when dimensions are known. `SvgVisualRenderer`
provides a framework-free preview/export path, and Flutter/Jaspr adapters should
consume the same semantic and visual models without adding framework dependencies
to this core package.

Full pixel-faithful PDF rasterization remains a larger track: glyph outlines,
transforms, clipping, shadings, masks, blend modes, and image codecs are not yet
complete. DICOM/NITF pixel decode is also not complete. This package performs no
cryptography and makes no cryptographic claims.

## Develop

```bash
dart pub get && dart analyze && dart test
```
