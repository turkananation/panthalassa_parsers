# Panthalassa Parsers

A Work in Progress — pure-Dart, zero-FFI parsers for structured, binary, and
composite document formats. Produces content-addressed, isolate-safe results for
the Panthalassa Vault or other projects that need to turn files into text,
metadata, and structure. No native dependencies, no `dart:io` — runs on server,
Flutter, and web.

## Supported formats

| Format | Detection | Output |
| --- | --- | --- |
| FHIR JSON / XML | resource root + FHIR namespace/profile | resourceType, id, profile, text |
| HL7 v2.x | `MSH` header and encoding characters | message type/version, control id, fields |
| HL7 v3 CDA | `ClinicalDocument` in `urn:hl7-org:v3` | header roles, patient/encounter, sections, tables, media |
| W3C Verifiable Credentials | JSON-LD context or compact JWT | issuer, subject, types, proof envelope |
| NIEM | NIEM namespace/prefixed roots | detected profile, text, metadata |
| ISO 20022 (XML) | ISO 20022 namespace | message definition, parties, accounts, transactions |
| UN/EDIFACT | `UNA`/`UNB` prefix | interchange header, message types, segments |
| ANSI X12 | positional `ISA` envelope | GS/ST envelopes, transaction sets, elements |
| USMTF (MIL-STD-6040) | set-terminated lines + known set IDs | MSGID, set list, text |
| STEP (ISO 10303-21) | `ISO-10303-21;` token | schema, header, entity-instance index |
| DICOM (PS3.10) | 128-byte preamble + `DICM` | transfer syntax, attributes, SQ items, SR, encapsulated docs |
| DICOM JSON (PS3.18) | tag-keyed objects with `vr` | attributes, sequences, SR, `InlineBinary` attachments |
| NITF 2.1 / NSIF | `NITF`/`NSIF` + version | file header, segment tables/subheaders, text bodies |
| STANAG family | per-standard sub-parsers (see below) | matched standard + its fields |
| PDF | `%PDF-` marker | per-page text, page count, Info metadata, attachments |
| ODF (ODT/ODS/ODP) | ZIP magic + `mimetype` member | paragraphs, sheets/slides, tables, meta |
| OOXML (DOCX/XLSX/PPTX) | ZIP central directory + content types | headings, sheets/cells, slides, tables, media |
| EPUB 2 / 3 | ZIP with `META-INF/container.xml` | spine chapters, nav/NCX TOC, Dublin Core, media |
| EML / MIME | RFC 822 headers + MIME boundaries | headers, bodies, attachments, nested messages |
| HTML / XHTML | doctype or `<html>` root | title, headings, links, tables, text |
| Markdown | filename/MIME hint only | front matter, headings, lists, tables, code, links |
| CSV / TSV | filename/MIME hint only | delimiter, header, rows, quoted fields, tables |
| Images | JPEG/PNG/GIF/WebP/TIFF/SVG magic | dimensions, EXIF/GPS, PNG text, XMP, SVG safety flags |
| Generic JSON / XML | fallback after specific parsers | text, shape metadata, content id |

Ambiguous text formats never claim files by content alone. Markdown (`.md`,
`.markdown`, `text/markdown`) and CSV/TSV (`.csv`, `.tsv`, `text/csv`,
`text/tab-separated-values`) require a filename or MIME hint via
`DocumentHints`; without one, detection reports `DocumentFormat.unknown` rather
than misclassifying arbitrary text.

The STANAG family covers **4607** (GMTI, binary), **4609** (motion imagery /
MPEG-2 TS + MISB ST 0601 local-set fields), **4676** (NITS tracking + point
kinematics, XML), **4774** (confidentiality label, XML), **4778** (metadata
binding, XML), **7023** (NPIF header/segment index), and **5516** (conservative
Link 16 / TADIL-J framed-message metadata). STANAG 4545 (NSIF) is handled by the
NITF parser.

## Quickstart

```dart
import 'dart:typed_data';
import 'package:panthalassa_parsers/panthalassa_parsers.dart';

Future<void> main(List<String> args) async {
  final bytes = await loadBytes(args.first);
  final registry = ParserRegistry.standard();

  final format = registry.detect(bytes);          // cheap detection
  final result = await registry.parseInIsolate(bytes); // offload CPU work

  print('${result.format.label}  id=${result.documentId}');
  print(result.metadata);
  if (result.hasText) print(result.text);
}
```

Implement `loadBytes(...)` with the appropriate platform API in your app
(`File.readAsBytes` on server, `rootBundle.load` on Flutter, `fetch`/XHR on web).
Do not import `dart:io` from the `lib/` package — production `lib/` code is
pure-Dart and must remain web-safe.

Synchronous `registry.parse(bytes)` is available for small inputs. Pass hints
for formats that cannot be recognised from content alone:

```dart
final result = registry.parse(
  bytes,
  hints: const DocumentHints(filename: 'notes.md'),
);
```

## Command-line interface

The package ships `panthalassa`, a styled, script-friendly CLI built on the same
parser registry. It lives entirely under `bin/`, so `dart:io` never enters the
library and the package stays web-safe.

```bash
# From a checkout
dart pub global activate --source path .
panthalassa --help

# Or run in-tree without activating
dart run bin/panthalassa.dart --help
```

| Command | Purpose |
| --- | --- |
| `detect <file>` | Format, confidence, and evidence. `--filename` / `--mime` disambiguate. |
| `parse <file>` | Full parse with a human summary, `--json`, `--text`, or `--metadata`. |
| `render <file>` | Text, Markdown, escaped HTML, or SVG (`--format`). |
| `batch <path>...` | Files/directories with bounded isolate concurrency, `--recursive`, `--include`, `--out-dir`, `--json`, and `--fail-fast`. |
| `digest <file>...` | SHA-256/384/512 content addresses, `--algo`, `--short`, and `--expect` verification. |
| `formats [query]` | Supported formats, capabilities, detection hints, and parser families. |
| `version` | CLI/package/parser/schema versions. |

Examples:

```bash
# Content-address exact bytes without parsing them
panthalassa digest report.pdf --json

# Full ParseResult (schema v2) with the triple digest
panthalassa parse report.pdf --json --out report.parse.json

# Only the extracted text, ready to pipe
panthalassa parse report.pdf --text > report.txt

# Ambiguous formats are hint-gated, including on stdin
printf '# Notes\n' | panthalassa parse - --filename notes.md --text

# Batch-ingest a tree; per-file JSON goes to parsed/
panthalassa batch inbox/ --recursive --include pdf,docx --out-dir parsed/

# Semantic and visual previews
panthalassa render report.pdf --format markdown
panthalassa render report.pdf --format svg --out report.svg
```

`parse --json` emits the `ParseResult` JSON governed by
`parseResultSchemaVersion`; `batch --json` emits a small batch envelope with
`"schemaVersion": 1`, per-file results, failures, and timing. Human output is
styled when stdout is a terminal and plain when piped. Exit codes follow
`sysexits.h` conventions: `0` success, `1` partial batch failure, `64` usage,
`65` parse/data error, `66` missing input, and `70` unexpected internal error.

## Content addressing

Every result carries a `ContentDigest` with three lowercase-hex values computed
from the exact input bytes:

- `sha256` — canonical `documentId`, kept byte-identical to historical vault ids
- `sha384` — long-lived integrity evidence
- `sha512` — cross-system interop

`result.documentId` and `result.digest!.sha256` are the same value;
`result.sha384` and `result.sha512` are convenience getters. On native platforms
all three hashes come from `pqforge`'s `PqBytes` primitives; on web/WASM the
hasher calls the same PointyCastle SHA-2 implementations that `PqBytes` wraps.
Either way, a document id minted here matches one minted by the sealing pipeline,
audit chain, or AAD binding. Results also carry `schemaVersion` and
`parserVersion` so downstream vaults can explain output-shape changes.

Inject a custom `ContentHasher` via `ParserRegistry.standard(hasher: ...)` when
the vault supplies its own hash implementation.

## Errors

Every failure is a sealed `ParseException`: `UnsupportedFormatException`,
`MalformedDocumentException`, `TruncatedDocumentException`,
`TextDecodingException`, `UnsupportedFeatureException`. Switch on them
exhaustively. Non-fatal warnings carry stable `ParseWarning.code` values for
UI-side localization; see `doc/ISSUE_CODES.md`.

## Status & limitations

Text, metadata, and structural extraction are complete for common cases across
the formats above. DICOM extracts Structured Report content trees and can parse
encapsulated PDF/CDA documents when `ParseOptions.parseAttachments` is enabled;
pixel data is never decoded. CDA walks nested sections, narrative tables, and
inline `observationMedia`. ISO 20022 surfaces group headers, parties, accounts,
transaction tables, and per-currency totals. OOXML and ODF expose sheets, slides,
tables, and embedded media without rendering fidelity. EPUB reads the OCF/OPF
spine and navigation documents but does not decrypt DRM or execute scripts.
Image parsers read container metadata only; they do not decode pixels or execute
SVG scripts/external references.

The render engine has a pure-Dart DIR plus text, Markdown, escaped HTML, and a
visual display-list layer. PDF parse results expose page geometry and
conservative text/rectangle/image-placeholder commands; NITF and DICOM metadata
project to image/frame placeholders when dimensions are known. `SvgVisualRenderer`
provides a framework-free preview/export path, and Flutter/Jaspr adapters should
consume the same semantic and visual models without adding framework dependencies
to this core package.

Full pixel-faithful PDF rasterization remains a larger track: glyph outlines,
transforms, clipping, shadings, masks, blend modes, and image codecs are not yet
complete. DICOM/NITF pixel decode is also not complete. This package performs no
sealing, signing, key custody, signature verification, or network access; it only
content-addresses the bytes it parses.

## Develop

```bash
dart pub get
dart run tool/version/generate_version.dart --check
dart analyze
dart test
dart run bin/panthalassa.dart version --json
dart compile js -O2 -o /tmp/panthalassa_web_smoke.js tool/web_smoke.dart
```

The CLI version is generated from the top-level `version:` field in
`pubspec.yaml`; CI runs the `--check` form so the package and executable cannot
drift.
