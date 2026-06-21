# CLAUDE.md — panthalassa_parsers

Project context for Claude Code. Read this first.

## What this is

A **pure-Dart, zero-FFI** library that detects and parses document formats into
content-addressed, isolate-safe `ParseResult`s. It is the plaintext-extraction
layer that feeds the Panthalassa Vault sealing pipeline (parse → canonicalize →
content-id → sign → hybrid-seal). This package does **no** cryptography itself; it
turns bytes into structured text + metadata and content-addresses them with the
vault's hash.

Targets: healthcare (FHIR JSON/XML, HL7 v2, CDA), structured JSON/XML (Verifiable
Credentials, NIEM, ISO 20022, generic), EDI (EDIFACT, X12), positional (USMTF, STEP),
binary (DICOM, NITF),
the STANAG family (4607/4609/4676/4774/4778), and composite (PDF, ODF). The
headline capability is text extraction from ordinary PDFs.

## Build & test

```bash
export PATH=/opt/dart-sdk/bin:$PATH   # if the SDK is not already on PATH
dart pub get
dart analyze        # must be clean (CI gate)
dart test           # 60 tests, all green
```

SDK floor is Dart 3.4 (sealed classes, switch expressions). **No `dart:io`** is
used anywhere in `lib/`, so the package is web-safe (dart2js/wasm) — keep it that
way: inflate goes through `package:archive`, not `ZLibCodec` from `dart:io`.

## Dependencies

- `pointycastle` — pure-Dart MD5/SHA/RC4/AES for the PDF Standard security handler.
- `pqforge` — provides `PqBytes.sha256`, the **default** content hasher. Document
  ids are therefore byte-identical to ids minted anywhere else in the vault
  (sealing pipeline, audit chain, AAD binding). One hash path, end to end.
- `archive` — pure-Dart ZIP + inflate (ODF container, PDF FlateDecode).
- `xml` — FHIR/XML, ODF content.xml, STANAG XML standards.

## Architecture

```
lib/
  panthalassa_parsers.dart        # public barrel — export new public types here
  src/core/
    document_format.dart          # DocumentFormat enum + FormatCategory
    parse_exception.dart          # sealed ParseException hierarchy
    parse_result.dart             # immutable ParseResult + ParseWarning
    content_hasher.dart           # ContentHasher / PqBytesContentHasher (default)
    byte_reader.dart              # bounds-checked, endian-aware cursor
    document_parser.dart          # the DocumentParser interface
    format_detector.dart          # ordered detection
    parser_registry.dart          # entry point: detect / parse / parseInIsolate
  src/parsers/
    json_support.dart / xml_support.dart   # shared JSON & XML harvesters + sniffers
    fhir_json_parser.dart, verifiable_credential_parser.dart, json_structured_parser.dart
    cda_parser.dart, iso20022_parser.dart, xml_structured_parser.dart, xml_fhir_parser.dart
    hl7v2_parser.dart, x12_parser.dart
    xml_fhir_parser.dart  edifact_parser.dart  step_parser.dart
    usmtf_parser.dart     odf_parser.dart      dicom_parser.dart
    nitf_parser.dart
    pdf_parser.dart                # public PDF parser
    pdf/pdf_internals.dart         # object model, value parser, page tree, ObjStm/xref-stream, decrypt hook
    pdf/pdf_filters.dart           # Flate/LZW/ASCII85/ASCIIHex/RunLength + PNG/TIFF predictors
    pdf/pdf_crypt.dart             # Standard security handler: RC4, AES-128 (AESV2), AES-256 (AESV3/R6)
    pdf/pdf_encodings.dart         # WinAnsi/MacRoman tables + glyph-name→Unicode (AGL + uniXXXX)
    pdf/pdf_text.dart              # content tokenizer, fonts (ToUnicode/encoding/Type0), Do recursion, inline-image skip
    stanag/
      stanag_parser.dart           # family dispatcher + StanagSubParser contract
      stanag_4607_gmti.dart        # GMTI (binary)
      stanag_4609_motion_imagery.dart  # MPEG-2 TS / MISB KLV
      stanag_xml.dart              # 4676 NITS, 4774 label, 4778 binding
test/
  framework_test.dart  structured_formats_test.dart  binary_formats_test.dart
  pdf_test.dart  odf_test.dart  stanag_test.dart
  support/fixtures.dart           # synthesises DICOM/ODF/PDF/STANAG fixtures in-code
```

## Invariants — do not regress

1. **Content addressing via `PqBytes.sha256`, never `hashCode`.** The default
   `PqBytesContentHasher` is the single hash path across the stack.
   `Object.hashCode` is unstable across isolates/runs and collides.
2. **Parsers are stateless and isolate-safe.** A single `const` instance is
   shared and may run on any isolate. No mutable fields, no I/O.
3. **`canParse` / `matches` is cheap and never throws.** Inspect a small prefix
   / fixed offsets. Return `false` on any doubt rather than risk a false positive.
4. **Detection order is load-bearing.** Strong binary magic (DICOM, PDF, NITF)
   before permissive text heuristics. STANAG runs before the generic XML/text
   parsers but its XML sub-parsers match on the *root element*, so they never
   shadow FHIR or claim arbitrary XML.
5. **All failures are typed.** Every error is a `ParseException` subtype; wrap
   third-party exceptions. Nothing untyped escapes a parser.
6. **Bounds-checked binary reads** through `ByteReader`, which throws
   `TruncatedDocumentException` past end-of-buffer.

## STANAG family

`StanagParser` dispatches over an ordered list of `StanagSubParser`s; the matched
standard is reported in `metadata['standard']`. Adding a standard = implement
`StanagSubParser` + register it in `stanag_parser.dart`; no enum or registry
change. **STANAG 4545 (NSIF) is the NATO profile of NITF and is handled by the
NITF parser** (it recognises the `NSIF` header), so it is not duplicated.

## Completeness map (be honest with the user about this)

| Format | State |
|---|---|
| FHIR JSON/XML, EDIFACT, STEP, USMTF, ODF | Complete for common cases; metadata + text. |
| FHIR JSON | resourceType/Bundle detection, NDJSON bulk export, profile/id. |
| HL7 v2.x | MSH-driven delimiters, message type/version/control id, all data values. |
| HL7 v3 CDA | ClinicalDocument (urn:hl7-org:v3): title, doc type, templateIds, sections, narrative. |
| W3C Verifiable Credentials | JSON-LD **and** compact JWT (decodes header+payload), issuer/type/proof. |
| NIEM | Detected (namespace/prefixed-element hints) in both the JSON and XML engines → `DocumentFormat.niem`. |
| ISO 20022 | XML messages (pain/pacs/camt/…): message-definition id from namespace, business area. ASN.1 variant not impl (rare). |
| X12 | ANSI ASC X12: positional ISA delimiters, GS/ST envelope, transaction sets, element text. |
| Generic JSON / XML | Catch-all structured extraction (text + content-id + shape metadata) for anything unrecognised. |
| DICOM | Meta group + dataset header + curated dictionary; stops at pixel data. No SQ descent, no full dictionary, no pixel decode. |
| NITF | File header + image-segment table. Graphic/text/DES segments and TREs not parsed. |
| STANAG 4607 | Packet header + segment enumeration. Segment *bodies* (dwell/target kinematics) are an extension point. |
| STANAG 4609 | MPEG-2 TS geometry + PIDs + KLV-presence detection. Full MISB KLV decode is an extension point. |
| STANAG 4676 | Track / track-point counts + security + ids. Per-point kinematics is an extension point. |
| STANAG 4774 / 4778 | Label fields / binding structure (label + signature presence). Signature verification out of scope. |
| PDF | **Feature-complete for text + metadata.** Object streams + cross-reference streams; full filter set (Flate/LZW/ASCII85/ASCIIHex/RunLength) with PNG/TIFF predictors; **encryption** — Standard handler RC4-40/128, AES-128 (AESV2), AES-256 (AESV3/R6) with empty user password (validated against /U, fails closed otherwise); **fonts** — ToUnicode CMaps, WinAnsi/MacRoman encodings with `/Differences` glyph-name resolution, Type0/Identity-H composite fonts; Form XObject (`Do`) recursion; inline-image (`BI/ID/EI`) skipping; rich metadata (title/author/subject/keywords/dates, encryption scheme, permission flags); **PDF/A-3** associated/embedded files (`/AF` + `/Names/EmbeddedFiles` name tree) with XML/JSON payload text folded into the result (ZUGFeRD/Factur-X). **Inherent limits:** CID fonts with *no* ToUnicode (glyph indices carry no Unicode — skipped, not guessed), and image-only filters (DCT/JPX/CCITT/JBIG2, which are not text). |

See `CONTINUATION.md` for the ticketed backlog.

## Conventions

- Effective Dart; `package:lints/recommended` + strict-casts/strict-raw-types.
- Doc-comment public APIs; explain *why* for non-obvious parsing decisions.
- New format → implement `DocumentParser`, add to `ParserRegistry.standard()` in
  the correct detection slot, export public types from the barrel, add a test
  with an in-code fixture (no binary assets).
