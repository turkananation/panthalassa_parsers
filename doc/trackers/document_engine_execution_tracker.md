# Panthalassa Parsers Document Engine Execution Tracker

Status: active  
Scope: finish `CONTINUATION.md` parser backlog first, then start the pure-Dart
DIR/render engine that can feed Flutter and Jaspr UI adapters.

## Ground Rules

- Preserve the current `ParserRegistry` and `ParseResult` API while adding richer
  structures.
- Keep production `lib/` free of `dart:io` and native/FFI dependencies.
- Every parser failure must be a `ParseException` subtype.
- Every completed item needs in-code fixtures, tests, `dart analyze`, and
  `dart test` evidence.
- Rendering starts semantic and pure-Dart: text, Markdown, HTML, and a neutral
  render tree before Flutter/Jaspr-specific adapters.

## CONTINUATION.md Backlog

| Item | Status | Completion Standard | Evidence |
|---|---|---|---|
| PDF text/metadata backlog | Complete before tracker | Existing PDF tests cover object streams, filters, encryption, fonts, Form XObject, inline image, PDF/A-3 embedded files. | Existing 60-test baseline. |
| STANAG-4607 segment body decode | Complete | Decode Mission, Dwell, Job Definition, and Target Report body fields with scaled coordinates/velocity when present. | `test/stanag_test.dart`; focused STANAG test green. |
| STANAG-4609 MISB KLV decode | Complete | Extract ST 0601 local-set TLVs from TS payloads and surface platform/sensor/frame-center fields. | `test/stanag_test.dart`; focused STANAG test green. |
| STANAG-4676 track kinematics | Complete | Extract per-track-point time, position, and velocity metadata from XML/GML variants. | `test/stanag_test.dart`; focused STANAG test green. |
| STANAG-7023 NPIF | Complete | Add sub-parser with safe binary detection and header/segment index extraction. | `test/stanag_test.dart`; focused STANAG test green. |
| STANAG-5516 Link 16 | Complete | Implement conservative framing-level detection/metadata only; no unsupported tactical word semantics. | `test/stanag_test.dart`; README/CONTINUATION caveat. |
| DICOM dictionary + SQ descent | Complete with caveat | Add broader dictionary, multi-value rendering, explicit/implicit SQ recursion, undefined-length item handling. Exhaustive generated PS3.6 keywords remain future polish. | `test/binary_formats_test.dart`; focused binary test green. |
| NITF segment subheaders + bodies | Complete | Decode image, graphic, text, DES, and RES segment tables/subheaders; extract textual bodies where safe. | `test/binary_formats_test.dart`; focused binary test green. |
| Real-file conformance fixtures | Complete | Add environment-gated conformance test harness for external fixture directories. | `test/real_conformance_test.dart`; skipped unless env var set. |
| Fuzz/property parser hardening | Complete | Truncated/permuted built-in fixtures never leak raw errors or hang. | `test/parser_hardening_test.dart`; focused hardening test green. |
| Performance benchmarks | Complete | Add repeatable benchmark entrypoint for large parser classes and isolate parsing. | `benchmark/parse_benchmark.dart`. |
| Web compile CI | Complete | Add CI job that proves package imports compile to JS without `dart:io`. | `.github/workflows/ci.yml`; local `dart compile js` green. |
| Standalone workspace CI | Complete | Recreate a one-package Dart workspace before `pub get` so `resolution: workspace` works in the individual repo. | `.github/workflows/ci.yml`. |
| Dart 3.12 CI | Complete | Install Dart 3.12.0 so `pqforge`'s SDK floor is satisfied without hosted SDK patch drift. | `.github/workflows/ci.yml`. |
| I18N/stable issue messages | Complete | Keep stable machine-readable issue codes and document UI-side localization path. | `docs/ISSUE_CODES.md`. |

## Render Engine Track

| Phase | Status | Completion Standard | Evidence |
|---|---|---|---|
| DIR core | Complete initial | Public immutable document/block/inline model plus `ParseResult` projection helpers. | `test/render_engine_test.dart`. |
| Renderer SPI | Complete initial | Pure-Dart `DocumentRenderer<T>`, render options, and stable output versioning. | `test/render_engine_test.dart`. |
| Text/Markdown/HTML renderers | Complete initial | All existing formats can render a semantic screen/export view through the same model. | `test/render_engine_test.dart`; local web compile green. |
| Visual display-list model | Complete initial | Pure-Dart page/frame geometry plus text, rectangle, image-placeholder, and unsupported-command primitives. | `lib/src/render/visual_primitives.dart`; `test/render_engine_test.dart`. |
| PDF visual page extraction | Complete initial | Surface page boxes and conservative text/rect/image-placeholder display-list commands without claiming full rasterization. | `lib/src/parsers/pdf/pdf_visual.dart`; `test/render_engine_test.dart`. |
| SVG visual renderer | Complete initial | Framework-free faithful preview/export output for display-list pages. | `lib/src/render/visual_renderer.dart`; `test/render_engine_test.dart`. |
| NITF/DICOM visual placeholders | Complete initial | Project known image/frame dimensions into visual pages until pixel codecs land. | `test/render_engine_test.dart`. |
| Flutter adapter | Not started | Separate adapter package/app layer; sliver/lazy `DocumentView`, accessibility, search. | Flutter tests/screenshots. |
| Jaspr adapter | Not started | HTML/component adapter that consumes pure-Dart DIR/render tree without duplicating parser logic. | Jaspr smoke test. |
| Faithful visual rendering | Started | Display-list substrate exists. Full PDF rasterization and DICOM/NITF pixel decode remain scoped follow-up work. | `docs/trackers/faithful_visual_rendering_tracker.md`. |
