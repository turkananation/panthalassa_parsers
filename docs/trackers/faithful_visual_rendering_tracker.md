# Faithful Visual Rendering Tracker

Status: active  
Scope: make visual rendering pixel-faithful over time while keeping the core
package pure Dart, web-safe, and honest about unsupported format features.

## Ground Rules

- Render from `DocumentIr` and `VisualDocument`, not directly from UI adapters.
- Keep `lib/` free of `dart:io`, `dart:ui`, Flutter, Jaspr, native, and FFI
  dependencies.
- Surface unsupported visual operators explicitly with display-list diagnostics.
- Never claim full raster fidelity until fixtures prove it for the relevant
  operators/codecs.
- Preserve the semantic renderer path; faithful rendering must not block text,
  Markdown, HTML, search, indexing, or RAG flows.

## Milestones

| Item | Status | Completion Standard | Evidence |
|---|---|---|---|
| Visual display-list primitives | Complete initial | Page/frame geometry plus text, rectangle, image-placeholder, and unsupported-command nodes. | `lib/src/render/visual_primitives.dart`; `test/render_engine_test.dart`. |
| Visual projection | Complete initial | `DocumentIr.toVisualDocument()` collects `RawVisualBlock`s without leaking heavy visual metadata into semantic output. | `lib/src/render/visual_document.dart`; `test/render_engine_test.dart`. |
| SVG visual renderer | Complete initial | Pure-Dart escaped SVG output for display-list previews. | `lib/src/render/visual_renderer.dart`; `test/render_engine_test.dart`. |
| PDF page geometry | Complete initial | MediaBox/CropBox dimensions, including inherited page-tree boxes, are exposed as visual pages. | `lib/src/parsers/pdf/pdf_visual.dart`; `test/render_engine_test.dart`. |
| PDF simple text layer | Complete initial | Basic `Tf`, `Td`, `Tm`, `Tj`, `TJ`, quote operators produce positioned text commands using existing font decoding. | `test/render_engine_test.dart`. |
| PDF simple rectangles | Complete initial | `re` plus fill/stroke operators produce rectangle commands. | `test/render_engine_test.dart`; `buildVisualShapePdf()`. |
| PDF image placeholders | Complete initial | Inline images and image XObjects surface placeholders instead of corrupting text/operator parsing. | `test/render_engine_test.dart`; `buildInlineImagePdf()`. |
| PDF graphics-state transforms | Not started | Correct CTM/text matrix handling for `cm`, scaling, rotation, nested graphics state, and form XObjects. | Future PDF visual fixtures. |
| PDF clipping/path/shading/masks | Not started | Clip paths, arbitrary paths, shadings, transparency, masks, blend modes represented or rendered. | Future conformance corpus. |
| PDF font glyph outlines/rasterization | Not started | Embedded/CID font glyph shapes render accurately without native libraries. | Future dedicated package/suite. |
| PDF image codec decode | Not started | DCT, JPX, CCITT, JBIG2 and color spaces decode or fail closed with diagnostics. | Future image fixture suite. |
| DICOM pixel decode | Not started | Uncompressed baseline grayscale/RGB pixel data decodes to renderable frames with window/level metadata. | Future DICOM pixel fixtures. |
| NITF pixel/tile decode | Not started | NITF image segments decode/lazily tile with safe resource limits. | Future NITF imagery fixtures. |
| Flutter canvas adapter | Not started | Separate Flutter layer maps display-list commands to `CustomPainter`, selection/search overlay, and lazy pages. | Flutter widget tests/screenshots. |
| Jaspr visual adapter | Not started | Separate Jaspr/web layer consumes SVG or typed display-list components safely. | Jaspr smoke test. |

## Current Fidelity Contract

The engine can now emit a faithful-rendering substrate: page geometry plus a
bounded display list. PDF pages with simple positioned text can render to SVG.
Image-bearing binary formats expose placeholders when dimensions are known.

This is not yet a full pixel rasterizer. Unsupported visual PDF operators and
undecoded image codecs must remain visible in diagnostics until implemented and
fixture-proven.
