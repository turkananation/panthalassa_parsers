# CONTINUATION.md — resuming panthalassa_parsers in Claude Code

## How the handoff actually works

A claude.ai **chat** session (where this package was built) and a **Claude Code**
session are separate runtimes — there is no shared session id to pass between
them. What carries the context is this repository: drop the `panthalassa_parsers/`
folder into your monorepo and run Claude Code from inside it. `CLAUDE.md` is
auto-loaded as project context; this file is the resume brief and backlog.

```bash
cd panthalassa_parsers
claude          # start Claude Code here
```

## Resume prompt (paste into the new Claude Code session)

> You are continuing `panthalassa_parsers`, a pure-Dart zero-FFI document-parsing
> library. Read `CLAUDE.md` for architecture and invariants. The framework and
> the FHIR/XML, EDIFACT, STEP, USMTF, and ODF parsers are complete; DICOM, NITF,
> PDF, and the STANAG family (4607/4609/4676/4774/4778) are structurally complete
> with marked extension points. **PDF is feature-complete for text + metadata**
> (object/xref streams, all filters, encryption RC4/AES-128/AES-256, font
> encodings + Type0, Form XObjects, inline images). The default content hasher is `PqBytes.sha256`
> via `pqforge`. All 60 tests pass (`dart analyze` clean, `dart test` green).
> Work the backlog below top-to-bottom. Hold the invariants: `PqBytes.sha256`
> content ids (never `hashCode`), stateless isolate-safe parsers, cheap
> non-throwing `canParse`/`matches`, binary-magic-before-text detection order,
> typed `ParseException`s, bounds-checked `ByteReader`, and **no `dart:io`**. For
> every change: add an in-code fixture + test, keep analyze clean, never let an
> untyped error escape a parser.

## Backlog (priority order)

### PDF — DONE (feature-complete for text + metadata)

- **PDF-1** xref streams + `/ObjStm` (0.2.0). **PDF-2** all stream filters +
  predictors (0.2.0).
- **PDF-3** encryption — Standard handler RC4-40/128, AES-128 (AESV2), AES-256
  (AESV3/R6), empty user password, validated against /U (fails closed). Verified
  against qpdf-generated fixtures.
- **PDF-4** fonts — ToUnicode + WinAnsi/MacRoman encodings + `/Differences`
  glyph-name resolution (AGL + uniXXXX) + Type0/Identity-H composite fonts.
- Plus Form XObject (`Do`) recursion, inline-image skipping, octal string
  escapes, and rich metadata (subject/keywords/dates, encryption, permissions).

The only remaining PDF items are inherent, not bugs: CID fonts that carry **no**
ToUnicode (glyph indices have no Unicode mapping — skipped rather than guessed),
and image-only filters (DCTDecode/JPXDecode/CCITTFax/JBIG2 — not text). A future
nicety would be embedded-CMap CID→Unicode via the font's `cmap` table.

### P1 — STANAG depth & breadth — DONE for parser metadata depth

- **STANAG-4607-1: Segment body decode** — dwell and target-report fields
  (existence masks, scaled lat/lon, velocity), Job Definition, Mission.
- **STANAG-4609-1: MISB KLV decode** — ST 0601 local set TLVs from TS payloads
  (sensor lat/lon, platform heading, frame center).
- **STANAG-4676-1: Track kinematics** — per-TrackPoint position/velocity/time.
- **STANAG-7023: NPIF** — `StanagSubParser` for binary NPIF header + segment
  index.
- **STANAG-5516: Link 16 / TADIL-J** — conservative framed-message metadata only;
  tactical J-series word semantics remain explicitly out of scope.
- Note: **4545 (NSIF)** is already covered by the NITF parser — no new work.

### P1 — Binary depth (DICOM / NITF) — DONE for metadata/render intake

- **DICOM-1: Dictionary-backed attributes + SQ descent.** Broad keyword mapping,
  generic numeric tag listing, nested datasets, and undefined-length
  item/delimitation handling. A generated exhaustive PS3.6 keyword table remains
  a future polish item, not a parser blocker.
- **DICOM-2: More transfer syntaxes & multi-valued (VM > 1) rendering.** Explicit
  LE/BE and implicit LE traversal plus encapsulated syntax warning; multi-valued
  strings render as lists.
- **NITF-1: Segment subheaders + bodies** — image, graphic, text, DES, RES segment
  tables/subheaders and safe text body extraction.

### Format breadth — DONE (Panthalassa matrix closed in 0.4.0)

The full advertised matrix now has parsers: FHIR JSON (+NDJSON), HL7 v2, HL7 v3
CDA, W3C Verifiable Credentials (JSON-LD + JWT), NIEM (XML+JSON), ISO 20022 (XML),
ANSI X12, and PDF/A-3 embedded files — plus generic JSON/XML catch-alls so
unrecognised structured documents still extract.

Genuine remainders (not bugs — niche or out of the document-parser scope):

- **OMOP CDM** is a *relational data model* (CSV/Parquet table exports), not a
  single document wire format. Supporting it means a tabular-ingestion path
  (CSV/Parquet → per-row records), which is a different shape than these parsers.
- **ISO 20022 ASN.1 variant** — ISO 20022 on the wire is overwhelmingly XML; the
  ASN.1 BER/DER binary encoding is rare. Would need a DER TLV walker.
- **STANAG 5516 / Link 16 J-series** word-level decode (the family is detected;
  per-message tactical decode is depth, tracked under STANAG below).
- Optional: richer EDIFACT/STEP field extraction where downstream needs it.

### P2 — Hardening & ops — STARTED

- **TEST-1: Real-file conformance fixtures** behind `PANTHALASSA_CONFORMANCE_DIR`;
  optional manifest asserts stable ids + extraction.
- **TEST-2: Property + fuzz tests** — truncated/permuted bytes across fixture
  families assert only typed `ParseException`s escape.
- **PERF-1: Benchmarks** — `benchmark/parse_benchmark.dart` covers PDF, DICOM,
  MPEG-TS/KLV, NITF, and isolate parse smoke.
- **WEB-1: dart2js CI job** — `.github/workflows/ci.yml` compiles
  `tool/web_smoke.dart` to JavaScript.
- **I18N-1: Stable warning/exception codes** — `docs/ISSUE_CODES.md` documents
  UI-side localization keys.

### Render engine — STARTED

- Pure-Dart `DocumentIr` model, parser capability flags, `DocumentRenderer<T>`,
  and text/Markdown/escaped-HTML semantic renderers.
- Faithful rendering foundation is now started with `VisualDocument`,
  `VisualPage`, display-list commands, `SvgVisualRenderer`, PDF page geometry and
  simple text/rect/image-placeholder commands, plus NITF/DICOM visual
  placeholders.
- All current fixture families project through `DocumentIr.fromParseResult` and
  render nonblank semantic HTML. Flutter and Jaspr adapters should consume this
  semantic layer without adding framework dependencies to this core package.
