import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../core/content_hasher.dart';
import '../core/document_format.dart';
import '../core/document_parser.dart';
import '../core/parse_result.dart';
import 'xml_support.dart';

/// Parser for HL7 FHIR XML resources.
///
/// Recognises a document as FHIR when it is well-formed XML whose root is in the
/// FHIR namespace, or whose root element is a known FHIR resource type. Generic
/// non-FHIR XML is intentionally *not* claimed, so this parser cannot shadow a
/// more specific format whose payload merely contains angle brackets.
final class XmlFhirParser implements DocumentParser {
  const XmlFhirParser();

  static const _fhirNamespace = 'http://hl7.org/fhir';

  /// A representative slice of FHIR R4/R5 resource roots. Extend as needed; the
  /// namespace check covers resources omitted here.
  static const _knownResources = {
    'Bundle',
    'Patient',
    'Observation',
    'Condition',
    'Encounter',
    'Procedure',
    'MedicationRequest',
    'DiagnosticReport',
    'Immunization',
    'AllergyIntolerance',
    'Composition',
    'DocumentReference',
    'Organization',
    'Practitioner',
    'CarePlan',
    'Coverage',
    'Claim',
  };

  @override
  DocumentFormat get format => DocumentFormat.fhirXml;

  @override
  bool canParse(Uint8List bytes) {
    final prefix = XmlSupport.peek(bytes, 2048);
    if (prefix == null || !XmlSupport.looksXml(prefix)) return false;
    if (prefix.contains(_fhirNamespace)) return true;
    final root = XmlSupport.firstElementName(prefix);
    return root != null && _knownResources.contains(root);
  }

  @override
  ParseResult parse(Uint8List bytes, {required ContentHasher hasher}) {
    final doc = XmlSupport.parse(bytes);
    final root = doc.rootElement;
    final resourceType = root.localName;
    final id = root.findElements('id').firstOrNull?.getAttribute('value');
    final profile = root
        .findElements('meta')
        .firstOrNull
        ?.findElements('profile')
        .firstOrNull
        ?.getAttribute('value');

    final warnings = <ParseWarning>[];
    if (root.getAttribute('xmlns')?.contains(_fhirNamespace) != true &&
        !_knownResources.contains(resourceType)) {
      warnings.add(
        const ParseWarning(
          'fhir.namespace_absent',
          'root is not in the FHIR namespace; classification is heuristic',
        ),
      );
    }

    return ParseResult(
      documentId: hasher.idFor(bytes),
      format: format,
      byteLength: bytes.length,
      metadata: {
        'resourceType': resourceType,
        'id': ?id,
        'profile': ?profile,
        'entryCount': root.findAllElements('entry').length,
      },
      text: _orNull(XmlSupport.extractText(root)),
      warnings: warnings,
    );
  }

  String? _orNull(String s) => s.isEmpty ? null : s;
}
