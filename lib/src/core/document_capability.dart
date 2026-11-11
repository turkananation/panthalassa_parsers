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
    DocumentFormat.dicom => const {
      DocumentCapability.text,
      DocumentCapability.metadata,
      DocumentCapability.structure,
      DocumentCapability.tables,
      DocumentCapability.attachments,
      DocumentCapability.media,
    },
    DocumentFormat.nitf => const {
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
      DocumentCapability.tables,
      DocumentCapability.attachments,
    },
    DocumentFormat.docx || DocumentFormat.xlsx || DocumentFormat.pptx => const {
      DocumentCapability.text,
      DocumentCapability.metadata,
      DocumentCapability.structure,
      DocumentCapability.tables,
      DocumentCapability.attachments,
    },
    DocumentFormat.fhirJson ||
    DocumentFormat.fhirXml ||
    DocumentFormat.hl7v2 ||
    DocumentFormat.verifiableCredential ||
    DocumentFormat.niem ||
    DocumentFormat.edifact ||
    DocumentFormat.x12 ||
    DocumentFormat.eml => const {
      DocumentCapability.text,
      DocumentCapability.metadata,
      DocumentCapability.structure,
    },
    DocumentFormat.cda => const {
      DocumentCapability.text,
      DocumentCapability.metadata,
      DocumentCapability.structure,
      DocumentCapability.tables,
      DocumentCapability.attachments,
    },
    DocumentFormat.iso20022 => const {
      DocumentCapability.text,
      DocumentCapability.metadata,
      DocumentCapability.structure,
      DocumentCapability.tables,
    },
    DocumentFormat.html => const {
      DocumentCapability.text,
      DocumentCapability.metadata,
      DocumentCapability.structure,
      DocumentCapability.tables,
    },
    DocumentFormat.image => const {
      DocumentCapability.metadata,
      DocumentCapability.media,
    },
    DocumentFormat.epub => const {
      DocumentCapability.text,
      DocumentCapability.metadata,
      DocumentCapability.structure,
      DocumentCapability.tables,
      DocumentCapability.attachments,
      DocumentCapability.media,
    },
    DocumentFormat.markdown => const {
      DocumentCapability.text,
      DocumentCapability.metadata,
      DocumentCapability.structure,
      DocumentCapability.tables,
    },
    DocumentFormat.csv => const {
      DocumentCapability.text,
      DocumentCapability.metadata,
      DocumentCapability.structure,
      DocumentCapability.tables,
    },
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
