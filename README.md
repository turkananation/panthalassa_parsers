# panthalassa_parsers

Pure-Dart, zero-FFI parsers for structured, binary, and composite document
formats. Produces content-addressed, isolate-safe results for the Panthalassa
Vault. No native dependencies, no `dart:io` — runs on server, Flutter, and web.

## Supported formats

| Format | Detection | Output |
|---|---|---|
| FHIR/XML | FHIR namespace / known resource root | resourceType, id, profile, text |
| UN/EDIFACT | `UNA`/`UNB` prefix | interchange header, message types, segments |
| STEP (ISO 10303-21) | `ISO-10303-21;` token | schema, header, entity-instance index |
| USMTF (MIL-STD-6040) | set-terminated lines + known set IDs | MSGID, set list, text |
| DICOM (PS3.10) | 128-byte preamble + `DICM` | transfer syntax, curated attributes |
| NITF 2.1 / NSIF | `NITF`/`NSIF` + version | file header, image-segment table |
| STANAG family | per-standard sub-parsers (see below) | matched standard + its fields |
| PDF | `%PDF-` marker | per-page text, page count, Info metadata |
| ODF (ODT/ODS/ODP) | ZIP magic + `mimetype` member | paragraphs, document class, meta |

The STANAG family covers **4607** (GMTI, binary), **4609** (motion imagery /
MPEG-2 TS + MISB KLV presence), **4676** (NITS tracking, XML), **4774**
(confidentiality label, XML), and **4778** (metadata binding, XML); the matched
standard is reported in `metadata['standard']`. STANAG 4545 (NSIF) is handled by
the NITF parser.

## Quickstart

```dart
import 'dart:io';
import 'package:panthalassa_parsers/panthalassa_parsers.dart';

Future<void> main(List<String> args) async {
  final bytes = await File(args.first).readAsBytes();
  final registry = ParserRegistry.standard();

  final format = registry.detect(bytes);          // cheap detection
  final result = await registry.parseInIsolate(bytes); // offload CPU work

  print('${result.format.label}  id=${result.documentId}');
  print(result.metadata);
  if (result.hasText) print(result.text);
}
```

Synchronous `registry.parse(bytes)` is available for small inputs. Inject a
custom `ContentHasher` (e.g. backed by the vault's `PqBytes.sha256`) via
`ParserRegistry.standard(hasher: ...)` to keep one hash implementation across the
stack — the default `Sha256ContentHasher` is byte-identical.

## Errors

Every failure is a sealed `ParseException`: `UnsupportedFormatException`,
`MalformedDocumentException`, `TruncatedDocumentException`,
`TextDecodingException`, `UnsupportedFeatureException`. Switch on them
exhaustively.

## Status & limitations

The framework and the FHIR/XML, EDIFACT, STEP, USMTF, and ODF parsers are
complete for common cases. DICOM, NITF, STANAG 4607, and PDF are structurally
complete with documented extension points (full DICOM dictionary, NITF segment
bodies, STANAG segment decode, and PDF object-streams/encryption/extra filters).
See `CONTINUATION.md` for the backlog. This package performs no cryptography and
makes no cryptographic claims.

## Develop

```bash
dart pub get && dart analyze && dart test
```
