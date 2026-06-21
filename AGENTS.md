# panthalassa_parsers Agent Instructions

This package is the pure-Dart document intake layer for Panthalassa. It detects
document formats, extracts text and metadata, and mints content-addressed parse
results for the vault pipeline.

## Read First

For any non-trivial change, read these before editing:

- `CLAUDE.md` for architecture, invariants, supported formats, and package rules.
- `CONTINUATION.md` for current backlog, known limitations, and resume context.
- `README.md` and `CHANGELOG.md` when behavior, public API, examples, or status
  claims change.

## Context7

Use the `ctx7` CLI to fetch current documentation whenever the task asks about a
library, framework, SDK, API, CLI tool, or cloud service.

1. Resolve the library first:
   `npx ctx7@latest library <name> "<user's full question>"`
2. Pick the best `/org/project` match by exact name, relevance, snippet count,
   source reputation, and benchmark score.
3. Fetch docs:
   `npx ctx7@latest docs <libraryId> "<user's full question>"`

Do not run more than three Context7 commands for one question. If Context7 fails
with quota, ask the user to run `npx ctx7@latest login` or set
`CONTEXT7_API_KEY`; do not silently fall back to stale knowledge.

## Non-Negotiable Invariants

- Keep `lib/` pure Dart and web-safe. Do not import `dart:io` from production
  parser code.
- Use `PqBytes.sha256` through the package content hasher path for document
  identity. Never use `Object.hashCode` for content identity.
- Parsers must be stateless and isolate-safe. Prefer `const` parsers and no
  mutable parser fields.
- `canParse` and format `matches` checks must be cheap and non-throwing.
- Preserve detection order: strong binary magic before permissive text/XML/JSON
  heuristics.
- Parser failures must surface as `ParseException` subtypes. Do not let raw
  `RangeError`, `FormatException`, XML/archive errors, or crypto errors escape.
- Use `ByteReader` or equivalent bounds-checked logic for binary formats.

## Fixture And Test Policy

- Prefer auditable in-code fixtures under `test/support/fixtures.dart`.
- Use files under `test/fixtures/` only for real conformance inputs that cannot
  be represented clearly in code, such as externally generated encrypted PDFs.
- Add or update tests for every parser behavior change.
- Run, at minimum:
  `dart analyze`
  `dart test`
- When changing a single parser, also run its focused test file first.

## Development Notes

- Work from `panthalassa_parsers/` for package commands.
- Keep public exports in `lib/panthalassa_parsers.dart` synchronized with new
  public APIs.
- Keep docs honest about parser depth. Do not overstate PDF rendering, DICOM
  pixel decode, NITF bodies, STANAG body decode, or cryptographic assurance.
- Parser code may support the vault, but this package does no sealing,
  signing, key custody, networking, or server policy itself.
