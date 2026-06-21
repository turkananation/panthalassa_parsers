# Changelog

## 0.5.0-dev

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
