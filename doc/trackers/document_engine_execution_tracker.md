# Panthalassa Parsers Document Engine Execution Tracker

Status: v0.5.1 remediation and feature roadmap complete; faithful visual
rendering and adapter packages remain active follow-up tracks.

Scope: keep the parser registry/CLI stable while extending the pure-Dart
DIR/render engine that feeds Flutter and Jaspr UI adapters.

## Ground Rules

- Preserve the current `ParserRegistry`, `ParseResult`, and CLI JSON contracts
  while adding richer structures.
- Keep production `lib/` free of `dart:io`, `package:args`, and native/FFI
  dependencies.
- Every parser failure must be a `ParseException` subtype.
- Every completed item needs in-code fixtures, tests, `dart analyze`, and
  `dart test` evidence; CLI behavior also needs the CLI smoke commands.
- Rendering starts semantic and pure-Dart: text, Markdown, HTML, and a neutral
  render tree before Flutter/Jaspr-specific adapters.

## Completed Backlog

| Item | Status | Completion Standard | Evidence |
|---|---|---|---|
| PDF text/metadata backlog | Complete | Object streams, filters, encryption, fonts, Form XObjects, inline images, PDF/A-3 embedded files. | Existing PDF tests; `test/pdf_features_test.dart`. |
| STANAG-4607 segment body decode | Complete | Mission, Dwell, Job Definition, and Target Report body fields with scaled coordinates/velocity when present. | `test/stanag_test.dart`. |
| STANAG-4609 MISB KLV decode | Complete | Extract ST 0601 local-set TLVs from TS payloads and surface platform/sensor/frame-center fields. | `test/stanag_test.dart`. |
| STANAG-4676 track kinematics | Complete | Extract per-track-point time, position, and velocity metadata from XML/GML variants. | `test/stanag_test.dart`. |
| STANAG-7023 NPIF | Complete | Safe binary detection and header/segment-index extraction. | `test/stanag_test.dart`. |
| STANAG-5516 Link 16 | Complete | Conservative framing-level detection/metadata only; no unsupported tactical word semantics. | `test/stanag_5516_link16_test.dart`; README/CONTINUATION caveat. |
| DICOM dictionary + SQ descent | Complete with caveat | Broader dictionary, multi-value rendering, explicit/implicit SQ recursion, undefined-length items. Exhaustive generated PS3.6 keywords remain future polish. | `test/binary_formats_test.dart`; `test/new_formats_test.dart`. |
| DICOM SR + PS3.18 JSON | Complete | SR content trees, nested sequences, `InlineBinary` attachments, and `BulkDataURI` reporting without fetching. | `test/new_formats_test.dart`; `test/binary_formats_test.dart`. |
| NITF segment subheaders + bodies | Complete | Image, graphic, text, DES, and RES segment tables/subheaders; safe textual bodies; visual placeholder geometry. | `test/binary_formats_test.dart`; `test/render_engine_test.dart`. |
| CDA depth | Complete | Header roles, patient/encounter, nested sections, narrative tables, and `observationMedia`. | `test/new_formats_test.dart`. |
| ISO 20022 depth | Complete | Group header, parties/agents, accounts, transaction tables, currency totals, balances. | `test/new_formats_test.dart`. |
| ODF/OOXML/EPUB depth | Complete | Text/structure, sheets/slides, tables, media, metadata, and safety warnings without layout fidelity. | `test/odf_test.dart`; `test/ooxml_test.dart`; `test/new_formats_test.dart`. |
| EML/HTML/Image/Markdown/CSV | Complete | New format families with hint-gated Markdown/CSV and safety warnings for scripts/external refs. | `test/eml_test.dart`; `test/html_test.dart`; `test/new_formats_test.dart`. |
| Triple content digest | Complete | SHA-256/384/512 via `PqBytes`; `documentId` remains SHA-256; `ParseResult` carries `ContentDigest`. | `test/framework_test.dart`; `lib/src/core/content_hasher.dart`. |
| ParseResult schema/parser versioning | Complete | `parseResultSchemaVersion` (2) and `parserVersion` (0.5.1) stamped on results. | `lib/src/core/parse_result.dart`; `test/framework_test.dart`. |
| Structured artifacts + options | Complete | Tables, outline, structured text, attachments, signatures, security labels, `ParseOptions`/`ParseLimits`. | `test/render_engine_test.dart`; `test/parser_hardening_test.dart`. |
| Isolate/web/batch runners | Complete | Background isolate parsing, web fallback, bounded batch concurrency. | `test/framework_test.dart`; `lib/src/core/parser_registry.dart`. |
| Fuzz/property parser hardening | Complete | Truncated/permuted built-in fixtures never leak raw errors or hang. | `test/parser_hardening_test.dart`. |
| Real-file conformance fixtures | Complete | Environment-gated conformance harness for external fixture directories. | `test/real_conformance_test.dart`; skipped unless env var set. |
| Performance benchmarks | Complete | Repeatable benchmark entrypoint for large parser classes and isolate parsing. | `benchmark/parse_benchmark.dart`. |
| Web compile CI | Complete | Package imports compile to JS without `dart:io`. | `.github/workflows/ci.yml`; `tool/web_smoke.dart`. |
| Standalone package resolution | Complete | Package resolves with no workspace declaration; CI uses plain `dart pub get`. | `.github/workflows/ci.yml`; local `dart pub get`. |
| Dart 3.13.5 CI | Complete | CI pins the supported SDK and satisfies `pqforge`'s floor. | `.github/workflows/ci.yml`. |
| I18N/stable issue messages | Complete | Stable machine-readable issue codes and documented UI-side localization path. | `doc/ISSUE_CODES.md`. |
| CLI command surface | Complete | `detect`, `parse`, `render`, `view`, `batch`, `digest`, `formats`, `version`; JSON/text modes, stdin, hints, strict limits, batch output, self-contained viewer. | `bin/panthalassa.dart`; `test/cli_test.dart`; CLI smoke commands. |
| CLI version generation | Complete | `bin/src/version.g.dart` generated from `pubspec.yaml`; CI checks drift. | `tool/version/generate_version.dart`; `.github/workflows/ci.yml`. |

## Render Engine Track

| Phase | Status | Completion Standard | Evidence |
|---|---|---|---|
| DIR core | Complete initial | Public immutable document/block/inline model plus `ParseResult` projection helpers. | `test/render_engine_test.dart`. |
| Renderer SPI | Complete initial | Pure-Dart `DocumentRenderer<T>`, render options, and stable output versioning. | `test/render_engine_test.dart`. |
| Text/Markdown/HTML renderers | Complete initial | All existing formats can render a semantic screen/export view through the same model. | `test/render_engine_test.dart`; CLI `render`. |
| Visual display-list model | Complete initial | Pure-Dart page/frame geometry plus text, rectangle, image-placeholder, and unsupported-command primitives. | `lib/src/render/visual_primitives.dart`; `test/render_engine_test.dart`. |
| PDF visual page extraction | Complete initial | Surface page boxes and conservative text/rect/image-placeholder display-list commands without claiming full rasterization. | `lib/src/parsers/pdf/pdf_visual.dart`; `test/render_engine_test.dart`. |
| SVG visual renderer | Complete initial | Framework-free faithful preview/export output for display-list pages. | `lib/src/render/visual_renderer.dart`; `test/render_engine_test.dart`; CLI `render --format svg`. |
| NITF/DICOM visual placeholders | Complete initial | Project known image/frame dimensions into visual pages until pixel codecs land. | `test/render_engine_test.dart`. |
| DICOM viewer pixel path | Complete initial | Decode supported syntaxes to windowed PNG for self-contained HTML; unsupported codecs degrade to metadata-only notices. | `lib/src/parsers/dicom/dicom_image.dart`; `test/dicom_image_test.dart`; `test/viewer_test.dart`; CLI `view`. |
| Flutter adapter | Not started | Separate adapter package/app layer; sliver/lazy `DocumentView`, accessibility, search. | Flutter tests/screenshots. |
| Jaspr adapter | Not started | HTML/component adapter that consumes pure-Dart DIR/render tree without duplicating parser logic. | Jaspr smoke test. |
| Faithful visual rendering | Started | Display-list substrate and a DICOM viewer PNG path exist. Full PDF rasterization, shared DICOM projection, and NITF pixel decode remain scoped follow-up work. | `doc/trackers/faithful_visual_rendering_tracker.md`; `CONTINUATION.md`. |

## Remaining Work

See `CONTINUATION.md` for the ordered backlog, known limitations, and the
verification checklist. The next high-value track is faithful visual rendering,
followed by Flutter/Jaspr adapters and an expanded external conformance corpus.
