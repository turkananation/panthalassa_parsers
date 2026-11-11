# CLAUDE.md — panthalassa_parsers

Project context for Claude Code. Read this first.

## What this is

A **pure-Dart, zero-FFI** library that detects and parses document formats into
content-addressed, isolate-safe `ParseResult`s. It is the plaintext-extraction
layer that feeds the Panthalassa Vault sealing pipeline (parse → canonicalize →
content-id → sign → hybrid-seal). This package does **no** sealing, signing, key
custody, signature verification, or network access; it turns bytes into
structured text + metadata and content-addresses them with the vault's
SHA-256/SHA-384/SHA-512 hash path.

Targets: healthcare (FHIR JSON/XML, HL7 v2, CDA), structured JSON/XML (Verifiable
Credentials, NIEM, ISO 20022, generic), EDI (EDIFACT, X12), positional (USMTF, STEP),
binary (DICOM PS3.10/PS3.18 JSON, NITF, image metadata), the STANAG family
(4607/4609/4676/4774/4778/7023/5516), composite (PDF, ODF, OOXML, EPUB), email,
HTML, and hint-gated Markdown/CSV/TSV. The headline capabilities are text
extraction from ordinary PDFs plus pure-Dart semantic and visual render
foundations. A companion `panthalassa` CLI lives in `bin/` and exposes the same
registry for detection, parsing, rendering, viewing, batch ingestion, and
content addressing without adding `dart:io` to the library.

## Build & test

```bash
export PATH=/opt/dart-sdk/bin:$PATH   # if the SDK is not already on PATH
dart pub get
dart run tool/version/generate_version.dart --check
dart analyze        # must be clean (CI gate)
dart test           # must be green; optional conformance fixtures may skip
dart run bin/panthalassa.dart version --json
dart run bin/panthalassa.dart formats --json >/dev/null
dart compile js -O2 -o /tmp/panthalassa_web_smoke.js tool/web_smoke.dart
```

SDK floor is Dart 3.12 (`pqforge` requires it). **No `dart:io`** is used anywhere
in `lib/`, so the package is web-safe (dart2js/wasm) — keep it that way: inflate
goes through `package:archive`, not `ZLibCodec` from `dart:io`.

## Dependencies

- `pointycastle` — pure-Dart MD5/RC4/AES for the PDF Standard security
  handler, plus the SHA-2 primitives behind the web/WASM hash backend.
- `pqforge` — provides `PqBytes.sha256`, `sha384`, and `sha512`, the native
  content-hash path. `documentId` remains the SHA-256 hex string; `ContentDigest`
  also carries SHA-384/SHA-512. Web/WASM uses the same PointyCastle primitives
  that `PqBytes` wraps, so digests remain byte-identical on every platform.
- `archive` — pure-Dart ZIP + inflate (ODF/OOXML/EPUB containers, PDF FlateDecode).
- `image` — pure-Dart JPEG baseline decode plus PNG encoding for DICOM frame
  rendering. JPEG-LS/JPEG 2000/JPEG lossless are not covered by this codec.
- `swissarmyknife` — safe JSON traversal, byte/string/collection helpers, and a
  bounded task queue used by batch parsing.
- `xml` — FHIR/XML, CDA, ISO 20022, ODF/OOXML content, EPUB/OPF, STANAG XML.
- `args` — command/subcommand parsing for `bin/` only. It must never be imported
  from `lib/`.

## Architecture

```
bin/
  panthalassa.dart                # CLI entry point + styled CommandRunner usage
  src/
    console.dart                  # ANSI styling, banner, terminal detection
    support.dart                  # input I/O, hints, ParseOptions, batch helpers
    inspect_commands.dart         # detect / formats / version
    parse_commands.dart           # parse / render
    batch_command.dart            # bounded batch ingestion
    digest_command.dart           # SHA-256/384/512 content addressing
    view_command.dart             # HTML viewer output + browser launch
    version.g.dart                # generated from pubspec.yaml
tool/
  version/generate_version.dart   # single-source CLI version + --check
lib/
  panthalassa_parsers.dart        # public barrel — export new public types here
  src/core/
    document_format.dart          # DocumentFormat enum + FormatCategory
    parse_exception.dart          # sealed ParseException hierarchy
    parse_result.dart             # immutable ParseResult + ParseWarning + schema version
    parse_options.dart            # ParseOptions / ParseLimits resource ceilings
    structured_artifacts.dart     # tables, outline, pages, attachments, hints
    content_hasher.dart           # ContentDigest + PqBytesContentHasher (SHA-256/384/512)
    byte_reader.dart              # bounds-checked, endian-aware cursor
    document_parser.dart          # DocumentParser + HintAwareDocumentParser + parserMatches
    document_capability.dart      # honest capability flags per format
    zip_container.dart            # ZIP magic + bounded central-directory name scan
    format_detector.dart          # ordered detection
    parser_registry.dart          # entry point: detect / parse / parseInIsolate / batch
    isolate_runner_io.dart        # isolate offload
    isolate_runner_web.dart       # synchronous web fallback
  src/parsers/
    json_support.dart / xml_support.dart   # shared JSON & XML harvesters + sniffers
    fhir_json_parser.dart, verifiable_credential_parser.dart, json_structured_parser.dart
    cda_parser.dart, iso20022_parser.dart, xml_structured_parser.dart, xml_fhir_parser.dart
    hl7v2_parser.dart, x12_parser.dart, edifact_parser.dart, step_parser.dart
    usmtf_parser.dart
    dicom_parser.dart, dicom_json_parser.dart, dicom_sr.dart
    dicom/dicom_image.dart         # pixel model, decoder (native/RLE/JPEG), PNG encode
    nitf_parser.dart
    odf_parser.dart, ooxml_parser.dart, epub_parser.dart
    eml_parser.dart, html_parser.dart, markdown_parser.dart, csv_parser.dart
    image_metadata_parser.dart
    pdf_parser.dart                # public PDF parser
    pdf/pdf_internals.dart         # object model, value parser, page tree, ObjStm/xref-stream, decrypt hook
    pdf/pdf_filters.dart           # Flate/LZW/ASCII85/ASCIIHex/RunLength + PNG/TIFF predictors
    pdf/pdf_crypt.dart             # Standard security handler: RC4, AES-128 (AESV2), AES-256 (AESV3/R6)
    pdf/pdf_encodings.dart         # WinAnsi/MacRoman tables + glyph-name→Unicode (AGL + uniXXXX)
    pdf/pdf_text.dart              # content tokenizer, fonts (ToUnicode/encoding/Type0), Do recursion, inline-image skip
    pdf/pdf_visual.dart            # conservative visual display-list extraction for page geometry/text/rects/images
  src/render/
    document_ir.dart               # semantic DIR + RawVisualBlock bridge
    document_renderer.dart         # text/Markdown/escaped-HTML renderers
    visual_primitives.dart         # pure-Dart page/frame geometry + visual commands
    visual_document.dart           # DIR -> VisualDocument projection
    visual_renderer.dart           # SVG visual renderer
    stanag/
      stanag_parser.dart           # family dispatcher + StanagSubParser contract
      stanag_4607_gmti.dart        # GMTI (binary)
      stanag_4609_motion_imagery.dart  # MPEG-2 TS / MISB KLV
      stanag_xml.dart              # 4676 NITS, 4774 label, 4778 binding
  src/view/
    viewer_document.dart           # ViewerDocument model + ViewBuilder SPI
    viewer_registry.dart           # viewer-builder selection
    viewer_html.dart               # self-contained HTML/CSS/JS shell
    csv_view_builder.dart          # filterable CSV/TSV table view
    dicom_view_builder.dart        # DICOM image frames, windowing, notices
    document_view_builder.dart     # semantic-HTML fallback
    viewer_support.dart            # basename + shared viewer helpers
test/
  framework_test.dart  structured_formats_test.dart  binary_formats_test.dart
  pdf_test.dart  odf_test.dart  ooxml_test.dart  eml_test.dart  html_test.dart
  new_formats_test.dart  stanag_test.dart
  cli_test.dart  dicom_image_test.dart  viewer_test.dart
  support/fixtures.dart           # synthesises fixtures in-code
```

## CLI

`bin/panthalassa.dart` wires a `CommandRunner` modeled on pqforge's styled
console. Commands:

| Command | Notes |
|---|---|
| `detect` | `detectDetailed`; `--filename`/`--mime`; `--require-match` exits 65 when unknown. |
| `parse` | Human summary, `--json` (`ParseResult` schema), `--text`, `--metadata`; shared `ParseOptions`/`ParseLimits` flags. |
| `render` | `text`, `markdown`, `html`, or `svg` through `DocumentIr`/`SvgVisualRenderer`. |
| `view` | Parse, select a `ViewBuilder`, write self-contained HTML, and open a browser. `--out`, `--no-open`, `--print-path`, `--raw`, `--json`, `--sync`, `--quiet`, `--title`, `--limit`/`--all-rows`, and DICOM `--frame`/`--all-frames`/`--window-center`/`--window-width`/`--invert`. |
| `batch` | `expandBatchInputs` + `mapPool`; bounded isolate concurrency; `--out-dir`, `--json`, `--fail-fast`. |
| `digest` | `PqBytesContentHasher`; all three digests by default; `--expect` compares SHA-256. |
| `formats` | Formats grouped by category, capabilities, hint requirements, parser classes. |
| `version` | CLI/package/parser/schema versions. |

Exit codes: `0` success, `1` partial batch failure, `64` usage, `65` parse/data
error, `66` missing input, `70` unexpected internal error. Machine output:
`parse --json` follows `parseResultSchemaVersion`; `batch --json` uses a small
envelope with `schemaVersion: 1`. Human status goes to stdout, diagnostics to
stderr, and ANSI color is auto-disabled when piped or `NO_COLOR` is set. The CLI
version is generated from `pubspec.yaml` and checked in CI.

## Invariants — do not regress

1. **Content addressing via SHA-2, never `hashCode`.** The default
   `PqBytesContentHasher` produces SHA-256, SHA-384, and SHA-512 in one pass.
   Native builds use `pqforge`'s `PqBytes`; web/WASM builds use the same
   PointyCastle digest primitives that `PqBytes` wraps, because pqforge's public
   barrel imports `dart:isolate` through `zeroize`. Both paths are byte-identical.
   `documentId` stays the SHA-256 hex string for backward compatibility;
   `ParseResult.sha384`/`sha512` expose the other digests. `Object.hashCode` is
   unstable across isolates/runs and collides.
2. **Parsers are stateless and isolate-safe.** A single `const` instance is
   shared and may run on any isolate. No mutable fields, no I/O.
3. **`canParse` / `matches` is cheap and never throws.** Inspect a small prefix
   / fixed offsets. Return `false` on any doubt rather than risk a false positive.
   Ambiguous formats (Markdown, CSV/TSV) implement `HintAwareDocumentParser` and
   decline without a filename/MIME hint. Detection must call `parserMatches`
   (not the extension default) so instance hint overrides actually win.
4. **Detection order is load-bearing.** Strong binary magic (DICOM, image
   containers, PDF, NITF) before permissive text heuristics. Container formats
   inspect the ZIP central directory (bounded) rather than a first-512-byte
   prefix. STANAG runs before generic text parsers but its XML sub-parsers match
   on the *root element*, so they never shadow FHIR or claim arbitrary XML.
5. **All failures are typed.** Every error is a `ParseException` subtype; wrap
   third-party exceptions. Nothing untyped escapes a parser.
6. **Bounds-checked binary reads** through `ByteReader`, which throws
   `TruncatedDocumentException` past end-of-buffer.
7. **CLI I/O stays in `bin/`.** `dart:io`, `package:args`, terminal styling,
   file reading, cache paths, and browser launching belong to the executable
   layer. `lib/` must stay pure Dart and web-safe; viewer builders consume
   `ParseResult` + bytes and return a `ViewerDocument`, while the CLI handles
   paths and OS integration. The CLI must call the public registry/render APIs
   rather than duplicating parser logic.

## STANAG family

`StanagParser` dispatches over an ordered list of `StanagSubParser`s; the matched
standard is reported in `metadata['standard']`. Adding a standard = implement
`StanagSubParser` + register it in `stanag_parser.dart`; no enum or registry
change. **STANAG 4545 (NSIF) is the NATO profile of NITF and is handled by the
NITF parser** (it recognises the `NSIF` header), so it is not duplicated.

## Completeness map (be honest with the user about this)

| Format | State |
|---|---|
| FHIR JSON/XML, EDIFACT, STEP, USMTF | Complete for common cases; metadata + text. |
| FHIR JSON | resourceType/Bundle detection, NDJSON bulk export, profile/id. |
| HL7 v2.x | MSH-driven delimiters, message type/version/control id, all data values. |
| HL7 v3 CDA | ClinicalDocument (urn:hl7-org:v3): ids/type/confidentiality, patient, authors, custodian, service event, encounter, nested section tree, narrative tables, observationMedia. Structured `<entry>` assertions are not interpreted. |
| W3C Verifiable Credentials | JSON-LD **and** compact JWT (decodes header+payload), issuer/type/proof. |
| NIEM | Detected (namespace/prefixed-element hints) in both the JSON and XML engines → `DocumentFormat.niem`. |
| ISO 20022 | XML messages (pain/pacs/camt/…): message-definition id from namespace, group header, parties/agents, debtor/creditor accounts, transaction table, per-currency totals, balances metadata. ASN.1 variant not impl (rare). |
| X12 | ANSI ASC X12: positional ISA delimiters, GS/ST envelope, transaction sets, element text. |
| Generic JSON / XML | Catch-all structured extraction (text + content-id + shape metadata) for anything unrecognised. |
| DICOM | PS3.10 meta group + dataset; SQ descent including undefined-length items; multi-valued rendering; broad keyword dictionary; SR content trees (text/outline/table); encapsulated PDF/CDA attachments when `parseAttachments` is enabled; visual frame placeholder when dimensions are known. `DicomParser.readImage` discovers pixel tags and `DicomPixelDecoder` renders uncompressed implicit/explicit LE, explicit BE, deflated, RLE, and JPEG-baseline frames with rescale/windowing, MONOCHROME1 inversion, mono/RGB/YBR handling, a 2048px output cap, and a 16M-input-pixel guard. JPEG-LS, JPEG 2000, JPEG lossless, PALETTE COLOR, and some RLE/YBR combinations surface as `UnsupportedFeatureException`; ordinary `parse` stays metadata-only. The dictionary is not an exhaustive generated PS3.6 table. |
| DICOM JSON | PS3.18 tag-keyed model: nested sequences, PersonName objects, dictionary metadata, SR extraction, `InlineBinary` attachments, and `BulkDataURI` reporting without fetching. |
| NITF | File header + image/graphic/text/DES/RES segment tables, subheaders, offsets, safe text-body extraction, and visual image placeholder when dimensions are known. Image pixels are not decoded. |
| ODF | ODT paragraphs/headings/tables; ODS sheets, repeated rows/cells, and values/formulas; ODP slides, speaker notes, and tables. Meta statistics and embedded media. No layout rendering. |
| OOXML | DOCX headings/paragraphs/tables, XLSX sheets/cells/formulas, PPTX slides/notes, core/app metadata, embedded media, macro/external-link flags. No layout rendering. |
| EPUB 2/3 | OCF → OPF, Dublin Core, spine chapters, NCX/EPUB3 nav TOC, XHTML text/headings/tables, manifest media, cover image, DRM/encryption/script warnings. No DRM bypass or script execution. |
| EML / MIME | RFC 822 headers, MIME multipart bodies, text/HTML alternatives, attachments, nested messages. |
| HTML / XHTML | Title/meta, headings, links, tables, text, external-resource warnings. No DOM execution or fetching. |
| Markdown | Hint-gated; front matter, ATX/setext headings, lists, quotes, GFM tables, fenced code, inline links/images, truncation warnings. No rendering/execution. |
| CSV / TSV | Hint-gated; quote-aware whole-document scan, embedded newlines, doubled quotes, delimiter scoring, ragged-row/truncation/encoding warnings, tables. |
| Image metadata | JPEG segments/EXIF/GPS/orientation/ICC/XMP, PNG IHDR/text/physical/gamma/eXIf, GIF dimensions/comments/frames, WebP VP8/VP8L/VP8X/EXIF/XMP, TIFF IFD metadata, strict SVG root plus script/external/`javascript:` warnings. No pixel decode. |
| STANAG 4607 | Packet header + segment enumeration + common Mission/Dwell/Job Definition/Free Text body fields, including scaled coordinates and target velocities when present. |
| STANAG 4609 | MPEG-2 TS geometry + PIDs + MISB ST 0601 local-set TLV fields for platform/sensor/frame-center metadata. Video essence is not decoded. |
| STANAG 4676 | Track / track-point counts + security + ids + per-point time/position/velocity where present. |
| STANAG 7023 / 5516 | NPIF header/segment index and conservative Link 16 framed-message metadata. 5516 tactical word semantics remain out of scope. |
| STANAG 4774 / 4778 | Label fields / binding structure (label + signature presence). Signature verification out of scope. |
| PDF | **Feature-complete for text + metadata; visual rendering foundation started.** Object streams + cross-reference streams; full filter set (Flate/LZW/ASCII85/ASCIIHex/RunLength) with PNG/TIFF predictors; **encryption** — Standard handler RC4-40/128, AES-128 (AESV2), AES-256 (AESV3/R6) with empty user password (validated against /U, fails closed otherwise); **fonts** — ToUnicode CMaps, WinAnsi/MacRoman encodings with `/Differences` glyph-name resolution, Type0/Identity-H composite fonts; Form XObject (`Do`) recursion; inline-image (`BI/ID/EI`) skipping; rich metadata (title/author/subject/keywords/dates, encryption scheme, permission flags); **PDF/A-3** associated/embedded files (`/AF` + `/Names/EmbeddedFiles` name tree) with XML/JSON payload text folded into the result (ZUGFeRD/Factur-X). Visual metadata includes page geometry plus conservative text/rectangle/image-placeholder commands and SVG preview output. **Inherent limits:** CID fonts with *no* ToUnicode (glyph indices carry no Unicode — skipped, not guessed), full PDF graphics-state transforms/clipping/shading/masks/blends, glyph-outline rasterization, and image codecs (DCT/JPX/CCITT/JBIG2) remain future fidelity work. |

See `CONTINUATION.md` for the remaining backlog and known limitations.

## Conventions

- Effective Dart; `package:lints/recommended` + strict-casts/strict-raw-types.
- Doc-comment public APIs; explain *why* for non-obvious parsing decisions.
- New format → implement `DocumentParser`, add to `ParserRegistry.standard()` in
  the correct detection slot, export public types from the barrel, add a test
  with an in-code fixture (no binary assets), and update the capabilities,
  README table, issue-code prefixes, and CLI `formats` output expectations.
- New CLI behavior → add it under `bin/src/`, keep raw data on stdout and
  diagnostics on stderr, preserve `--json` for machine consumers, and add a
  focused test where the logic is not purely presentation.
- New viewer behavior → implement a `ViewBuilder` in `lib/src/view/`, register
  it in `ViewerRegistry`, keep HTML assembly in `viewer_html.dart`, and keep
  file paths/cache directories/browser launch in `bin/src/view_command.dart`.
  Viewer output must stay self-contained and degrade to a notice when a codec or
  feature is unsupported.
- Version changes → update `pubspec.yaml`, `parserImplementationVersion`, the
  generated CLI version (`dart run tool/version/generate_version.dart`), the
  changelog, and `CONTINUATION.md`.
