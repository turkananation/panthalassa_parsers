import 'document_format.dart';
import 'document_parser.dart';

/// Honest capability flags for parser and renderer planning.
enum DocumentCapability {
  text,
  metadata,
  structure,
  tables,
  attachments,
  media,
  signatures,
  roundTrip,
  streaming,
}

extension DocumentParserCapabilities on DocumentParser {
  /// Conservative built-in capability declaration by format.
  Set<DocumentCapability> get capabilities => switch (format) {
    DocumentFormat.pdf => const {
      DocumentCapability.text,
      DocumentCapability.metadata,
      DocumentCapability.attachments,
    },
    DocumentFormat.dicom || DocumentFormat.nitf => const {
      DocumentCapability.metadata,
      DocumentCapability.structure,
      DocumentCapability.media,
    },
    DocumentFormat.stanag => const {
      DocumentCapability.metadata,
      DocumentCapability.structure,
      DocumentCapability.media,
    },
    DocumentFormat.odf => const {
      DocumentCapability.text,
      DocumentCapability.metadata,
      DocumentCapability.structure,
    },
    DocumentFormat.fhirJson ||
    DocumentFormat.fhirXml ||
    DocumentFormat.hl7v2 ||
    DocumentFormat.cda ||
    DocumentFormat.verifiableCredential ||
    DocumentFormat.niem ||
    DocumentFormat.iso20022 ||
    DocumentFormat.edifact ||
    DocumentFormat.x12 ||
    DocumentFormat.step ||
    DocumentFormat.usmtf ||
    DocumentFormat.json ||
    DocumentFormat.xml => const {
      DocumentCapability.text,
      DocumentCapability.metadata,
      DocumentCapability.structure,
    },
    _ => const {},
  };
}
