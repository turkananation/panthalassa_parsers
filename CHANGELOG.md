# Changelog

## 0.5.1

- **CLI:** new `panthalassa` executable with `detect`, `parse`, `render`,
  `batch`, `digest`, `formats`, and `version` commands; styled ANSI console,
  `--json`/`--text`/`--metadata` modes, stdin (`-`) support, detection hints,
  strict resource ceilings, bounded batch isolates, per-file JSON output, SVG
  visual export, and `sysexits.h`-style exit codes. `args` is used only by
  `bin/`.
- **Content addressing:** `ParseResult` now carries SHA-256, SHA-384, and
  SHA-512 via `ContentDigest`/`PqBytesContentHasher`; `documentId` remains the
  SHA-256 hex string for vault compatibility. Results also stamp
  `parseResultSchemaVersion` (2) and `parserVersion` (0.5.1).
- **New formats:** hint-gated Markdown and CSV/TSV; image metadata
  (JPEG/PNG/GIF/WebP/TIFF/SVG); EPUB 2/3; OOXML (DOCX/XLSX/PPTX); RFC 822/MIME
  email; HTML/XHTML; DICOM JSON (PS3.18); DICOM Structured Report extraction;
  and encapsulated PDF/CDA handling behind `ParseOptions.parseAttachments`.
- **Depth:** CDA header roles, nested sections, narrative tables, and
  `observationMedia`; ISO 20022 group headers, parties, accounts, transaction
  tables, and currency totals; DICOM sequences and undefined-length items; NITF
  segment tables/subheaders; ODF/OOXML/EPUB structure; STANAG family depth from
  0.5.0 retained.
- **Hardening and API:** `ParseOptions`/`ParseLimits` resource ceilings,
  structured tables/outline/attachments/signatures/security labels, isolate and
  web fallback runners, bounded batch parsing, typed `ParseException` wrapping,
  ZIP central-directory scanning, and malformed-input/property tests.
- **Detection:** hint-aware detection now reports hint-only matches as
  high-confidence and marks them with `hint-match` evidence; ambiguous text
  formats still never claim files without a filename/MIME hint.
- **Packaging and CI:** standalone package resolution, Dart 3.13.5 CI, CLI
  version generation/check, CLI smoke coverage, and web compile smoke target.

## 0.5.0

- STANAG depth: 4607 Dwell/target body fields, 4609 MISB ST 0601 local-set TLVs,
  4676 per-track-point kinematics, new 7023 NPIF parser, and conservative 5516
  Link 16 framed-message metadata.
- Binary depth: DICOM SQ descent with undefined-length item handling,
  multi-valued attribute rendering, broader dictionary-backed metadata, and
  generic attribute lists; NITF image/graphic/text/DES/RES segment
  subheader/body walking.
- Hardening: malformed-input parser tests, environment-gated real-file
  conformance harness, benchmark entrypoint, web compile smoke target, CI, and
  stable issue-code documentation.
- Render engine start: pure-Dart `DocumentIr`, capability flags, renderer SPI,
  text/Markdown/escaped-HTML renderers, visual display-list primitives, SVG
  visual preview output, PDF page geometry/simple visual commands, and
  DICOM/NITF visual placeholders.

## 0.4.0

Closes the Panthalassa formats matrix — every advertised standard now has a parser.

- **FHIR JSON** (R4/R5) + **NDJSON** bulk-export streams.
- **HL7 v2.x** pipe-delimited messages (MSH-driven delimiters, message type/version).
- **HL7 v3 CDA** clinical documents (urn:hl7-org:v3).
- **W3C Verifiable Credentials** in JSON-LD and compact JWT serializations.
- **NIEM** detection (XML and JSON) → `DocumentFormat.niem`.
- **ISO 20022** financial messages (XML), with message-definition id from the namespace.
- **ANSI X12** EDI interchanges (positional ISA delimiters, GS/ST envelope).
- **PDF/A-3** embedded/associated files (`/AF` + EmbeddedFiles name tree); XML/JSON
  payloads (e.g. ZUGFeRD/Factur-X invoice XML) folded into the extracted text.
- Generic **JSON** and **XML** catch-all engines so unrecognised structured documents
  still yield text + a content id rather than being rejected.
- New `DocumentFormat` values: fhirJson, hl7v2, cda, verifiableCredential, niem,
  iso20022, x12, json, xml.

## 0.3.0

- PDF encryption: Standard security handler — RC4-40/128, AES-128 (AESV2), and
  AES-256 (AESV3/R6) with empty user password, validated against `/U`
  (password-protected documents fail closed). Strings and streams decrypted;
  verified against qpdf-generated fixtures.
- PDF fonts: WinAnsi/MacRoman encodings, `/Differences` glyph-name resolution
  (Adobe Glyph List subset + `uniXXXX`), and Type0/Identity-H composite fonts.
- PDF content: Form XObject (`Do`) recursion, inline-image (`BI/ID/EI`) skipping,
  and octal string-escape decoding.
- PDF metadata: subject, keywords, creation/mod dates, encryption scheme, and
  permission flags.

## 0.2.0

- PDF: resolve modern PDF 1.5+ documents — cross-reference stream `/Root`
  recovery and compressed object stream (`/ObjStm`) expansion.
- PDF: full stream filter set — FlateDecode, LZWDecode, ASCII85Decode,
  ASCIIHexDecode, RunLengthDecode — with PNG/TIFF predictors.
- STANAG: family dispatcher covering 4607, 4609, 4676, 4774, 4778.
- Default content hasher is `PqBytes.sha256` (via `pqforge`).

## 0.1.0

Initial scaffold.

- Core framework: `ParserRegistry`, `FormatDetector`, `DocumentParser`,
  `ByteReader`, content-addressed `ParseResult`, sealed `ParseException`.
- Complete parsers: FHIR/XML, EDIFACT, STEP (ISO 10303-21), USMTF, ODF.
- Structural parsers (metadata-complete, bodies as extension points):
  DICOM (PS3.10), NITF 2.1.
- STANAG family dispatcher with sub-parsers for 4607 (GMTI), 4609 (MPEG-2 TS /
  MISB KLV presence), 4676 (NITS tracking), 4774 (confidentiality label), and
  4778 (metadata binding).
- Default content hasher is `PqBytes.sha256` (via `pqforge`) for a single hash
  path across the vault.
- PDF text extraction for non-object-stream documents (classic + brute-force
  object indexing, FlateDecode, content-stream tokeniser, ToUnicode CMaps).

See CONTINUATION.md for the remaining ticketed work.
