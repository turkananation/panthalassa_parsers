import 'dart:convert';

import 'package:xml/xml.dart';

import '../core/document_format.dart';
import '../core/parse_result.dart';
import 'viewer_document.dart';
import 'viewer_support.dart';

/// Source viewer for generic JSON, XML, and NIEM documents.
///
/// The original payload is pretty-printed and HTML-escaped. This is a safer and
/// more complete default than flattening structured data into paragraphs, and
/// it does not execute scripts or resolve external entity references.
final class StructuredSourceViewBuilder implements ViewBuilder {
  const StructuredSourceViewBuilder();

  static const int maxSourceChars = 2 * 1024 * 1024;

  @override
  String get id => 'structured';

  @override
  bool supports(ParseResult result) =>
      result.format == DocumentFormat.json ||
      result.format == DocumentFormat.xml ||
      result.format == DocumentFormat.niem;

  @override
  ViewerDocument build(ViewerRequest request) {
    final result = request.result;
    final title = viewerTitle(request);
    final notices = viewerWarnings(result);
    var source = _prettySource(result, request.bytes);
    if (source.isEmpty) {
      source = result.text ?? 'No source text could be decoded.';
    }
    if (source.length > maxSourceChars) {
      source = source.substring(0, maxSourceChars);
      notices.add(
        ViewerNotice(
          'Source preview truncated at ${formatViewerBytes(maxSourceChars)}.',
          level: ViewerNoticeLevel.warning,
        ),
      );
    }

    final root = viewerString(result.metadata['rootElement']);
    final rootType = viewerString(result.metadata['rootType']);
    final keys = viewerValue(result.metadata['topLevelKeys']);
    final elementCount = viewerInt(result.metadata['elementCount']);
    final recordCount = viewerInt(result.metadata['recordCount']);
    return ViewerDocument(
      title: title,
      formatLabel: result.format.label,
      subtitle: [?rootType ?? root, result.format.label].join(' · '),
      facts: {
        ...viewerBaseFacts(request),
        'Format': result.format.label,
        'Root element': ?root,
        'Root type': ?rootType,
        if (keys.isNotEmpty) 'Top-level keys': keys,
        if (elementCount != null) 'Elements': '$elementCount',
        if (recordCount != null) 'Records': '$recordCount',
      },
      sections: [
        ViewerTextSection(
          title: 'Formatted source',
          text: source,
          monospace: true,
        ),
      ],
      notices: notices,
      footer: 'Panthalassa structured-source viewer',
    );
  }

  String _prettySource(ParseResult result, List<int> bytes) {
    final raw = utf8.decode(bytes, allowMalformed: true).trim();
    if (raw.isEmpty) return '';
    try {
      if (result.format == DocumentFormat.xml ||
          result.format == DocumentFormat.niem && raw.startsWith('<')) {
        return XmlDocument.parse(raw).toXmlString(pretty: true, indent: '  ');
      }
      if (result.format == DocumentFormat.json ||
          result.format == DocumentFormat.niem) {
        return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
      }
    } on Object {
      // Fall back to the original payload when the source is not strict enough
      // for the pretty-printer. The parser already decided the format.
    }
    return raw;
  }
}
