# Parse Issue Codes

Panthalassa parser diagnostics expose stable machine-readable codes for UI-side
localization. Keep parser messages short, English, and payload-free; product
surfaces should localize by code rather than matching message strings.

## Exception Classes

Exceptions are stable by type:

- `UnsupportedFormatException`
- `MalformedDocumentException`
- `TruncatedDocumentException`
- `TextDecodingException`
- `UnsupportedFeatureException`

## Warning Code Prefixes

- `dicom.*` — DICOM transfer syntax, sequence, truncation, delimiter, and
  encapsulation warnings.
- `nitf.*` — NITF segment table, length, and bounds warnings.
- `pdf.*` — PDF page extraction, embedded file, text-layer, and decode warnings.
- `stanag4607.*` — GMTI segment body and segment-size warnings.
- `stanag4609.*` — motion-imagery KLV presence/decode warnings.
- `stanag5516.*` — Link 16 framed-message warnings.
- `stanag7023.*` — NPIF header and segment-index warnings.

## Localization Contract

1. Treat `ParseWarning.code` and exception runtime type as the stable lookup key.
2. Treat `message` as a fallback developer-facing English string.
3. Do not include document payload bytes, PHI/PII, secrets, or classified content
   in any warning or exception message.
4. Add new prefixes here when adding a parser family or warning category.
