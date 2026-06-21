/// The document formats this package can detect and parse.
enum DocumentFormat {
  fhirXml('FHIR/XML', FormatCategory.structured),
  fhirJson('FHIR/JSON', FormatCategory.structured),
  hl7v2('HL7 v2.x', FormatCategory.positional),
  cda('HL7 CDA (v3)', FormatCategory.structured),
  verifiableCredential('W3C Verifiable Credential', FormatCategory.structured),
  niem('NIEM', FormatCategory.structured),
  iso20022('ISO 20022', FormatCategory.structured),
  usmtf('USMTF', FormatCategory.positional),
  edifact('UN/EDIFACT', FormatCategory.positional),
  x12('ANSI X12', FormatCategory.positional),
  step('STEP ISO 10303-21', FormatCategory.structured),
  dicom('DICOM PS3.10', FormatCategory.binary),
  nitf('NITF 2.1', FormatCategory.binary),
  stanag('STANAG', FormatCategory.composite),
  pdf('PDF', FormatCategory.composite),
  odf('OpenDocument', FormatCategory.composite),
  json('JSON', FormatCategory.structured),
  xml('XML', FormatCategory.structured),
  unknown('Unknown', FormatCategory.unknown);

  const DocumentFormat(this.label, this.category);

  /// Human-readable label, e.g. for UI and logs.
  final String label;

  /// Broad structural family of the format.
  final FormatCategory category;
}

/// Broad structural family of a [DocumentFormat], used to choose a parsing
/// strategy and to reason about which detectors may safely run before others.
enum FormatCategory { structured, positional, binary, composite, unknown }
