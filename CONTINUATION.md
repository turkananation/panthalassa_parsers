# Continuation — panthalassa_parsers

Current version: **0.5.1**  
Last updated: **2026-11-11**

This file is the resume point for the parser/document-engine work. Read
`CLAUDE.md` for architecture and invariants, and `README.md` for the public
surface.

## Current state

The audit remediation and feature roadmap through v0.5.1 are implemented and
covered by tests:

- **Content addressing:** SHA-256, SHA-384, and SHA-512 are computed in one
  pass. Native builds use `pqforge`'s `PqBytes`; web/WASM builds use the same
  PointyCastle SHA-2 primitives that `PqBytes` wraps, because pqforge's public
  barrel imports `dart:isolate` through `zeroize`. `documentId` remains the
  SHA-256 hex value for vault compatibility. `ParseResult` carries
  `schemaVersion` and `parserVersion`.
- **Core API:** `ParseOptions` / `ParseLimits`, structured text, outline,
  tables, attachments, signature envelopes, security labels, isolate and web
  fallback runners, and bounded batch parsing.
- **Formats:** FHIR JSON/XML, HL7 v2, CDA, Verifiable Credentials, NIEM, ISO
  20022, EDIFACT, X12, USMTF, STEP, DICOM PS3.10 and PS3.18 JSON, DICOM SR,
  NITF/NSIF, the STANAG family, PDF (text, metadata, encryption, filters, PDF/A-3
  attachments, conservative visual display lists), ODF, OOXML, EPUB, EML, HTML,
  Markdown, CSV/TSV, image metadata, generic JSON, and generic XML.
- **Detection:** strong binary magic runs before permissive text heuristics.
  Markdown and CSV/TSV are hint-gated and never claim arbitrary text. Hint-only
  matches are reported with high confidence and `hint-match` evidence.
- **CLI:** `panthalassa` provides `detect`, `parse`, `render`, `batch`, `digest`,
  `formats`, and `version`, with JSON/text modes, stdin support, hints, strict
  limits, and per-file batch output. CLI code is confined to `bin/`; `lib/`
  remains pure Dart and web-safe.
- **Verification:** `dart analyze`, `dart test`, the CLI smoke commands, and
  `dart compile js` on `tool/web_smoke.dart` are expected to be green. CI pins
  Dart 3.13.5 and checks that the generated CLI version matches `pubspec.yaml`.

## Known limitations

These are deliberate scope boundaries, not regressions:

- **PDF rendering** is a display-list foundation, not pixel-faithful
  rasterization. Glyph outlines, arbitrary transforms, clipping, shadings,
  masks, blend modes, and DCT/JPX/CCITT/JBIG2 image codecs are not implemented.
- **DICOM/NITF pixels** are never decoded. Visual output uses placeholder
  commands based on known geometry.
- **DICOM dictionary** covers common attributes and keywords, but is not an
  exhaustive generated PS3.6 table.
- **NITF/STANAG** extraction is conservative. Tactical word semantics, dense
  body decoding, and full standards conformance remain future work.
- **OOXML/ODF/EPUB** extract structure and text without layout fidelity. EPUB
  DRM is not bypassed and scripts are not executed.
- **Image formats** expose container metadata only; pixels are not decoded and
  SVG scripts/external references are not executed.
- **ISO 20022** covers XML messages; the ASN.1 variant is not implemented.
- **Markdown/CSV** need a filename or MIME hint because content-only detection
  would misclassify ordinary text.
- **Signatures** are surfaced as presence metadata only. This package performs
  no cryptographic verification, sealing, signing, key custody, or networking.
- **CLI JSON** is stable by documented schema but is not a formal versioned
  protocol beyond `ParseResult.schemaVersion` and the batch envelope
  `schemaVersion: 1`.

## Backlog

Ordered by value for the vault pipeline:

1. **Faithful visual rendering track:** complete the PDF display list
   (transforms/clipping/text positioning), add raster/image codec support, then
   project DICOM/NITF frames into renderable pages.
2. **Adapter packages:** Flutter `DocumentView` and Jaspr/HTML adapters that
   consume `DocumentIr`/`VisualDocument` without adding framework dependencies
   to this core package.
3. **Standards depth:** exhaustive DICOM PS3.6 dictionary generation, fuller
   STANAG/NITF bodies, ISO 20022 ASN.1, and additional OOXML/ODF edge cases.
4. **CLI polish:** shell completions, a `--watch` batch mode, and richer
   render-time page selection (the current command intentionally stays small).
5. **Conformance corpus:** expand the environment-gated real-file harness with
   externally generated PDFs, DICOM studies, OOXML, EPUB, and EML fixtures.
6. **Performance:** re-run `benchmark/parse_benchmark.dart` on large PDFs,
   DICOM studies, and batch workloads; tune isolate concurrency defaults only
   with measured evidence.

Out of scope unless the project explicitly expands: OCR, DRM bypass, signature
verification, key custody, network fetching of `BulkDataURI`, and execution of
embedded scripts or macros.

## Resume checklist

```bash
dart pub get
dart run tool/version/generate_version.dart --check
dart analyze
dart test
dart run bin/panthalassa.dart version --json
dart run bin/panthalassa.dart formats --json >/dev/null
dart run bin/panthalassa.dart parse README.md --json >/dev/null
dart compile js -O2 -o /tmp/panthalassa_web_smoke.js tool/web_smoke.dart
```

For a focused parser change, run its test file first (for example
`dart test test/new_formats_test.dart`), then the full suite. Keep public
exports in `lib/panthalassa_parsers.dart` synchronized with new public types,
and update `README.md`, `CHANGELOG.md`, `doc/ISSUE_CODES.md`, and this file when
behavior or scope changes.
