import '../core/document_format.dart';
import '../core/parse_result.dart';
import 'viewer_document.dart';
import 'viewer_support.dart';

/// CSV/TSV viewer: native tables become an HTML grid with sticky headers and
/// client-side filtering. This is the simplest real layout surface in the
/// package and is intentionally the reference implementation for future table
/// renderers.
final class CsvViewBuilder implements ViewBuilder {
  const CsvViewBuilder();

  @override
  String get id => 'csv';

  @override
  bool supports(ParseResult result) => result.format == DocumentFormat.csv;

  @override
  ViewerDocument build(ViewerRequest request) {
    final result = request.result;
    final options = request.options;
    final title = viewerTitle(request);
    final notices = viewerWarnings(result);
    final table = result.tables.isEmpty ? null : result.tables.first;
    final tabSeparated = result.metadata['isTabSeparated'] == true;
    final format = tabSeparated ? 'TSV' : 'CSV';

    if (table == null) {
      notices.add(
        const ViewerNotice(
          'No table was produced for this CSV/TSV input; showing extracted '
          'text instead. Re-run with --tables to enable table extraction.',
          level: ViewerNoticeLevel.warning,
        ),
      );
      return ViewerDocument(
        title: title,
        formatLabel: format,
        subtitle: 'Text fallback',
        facts: {
          ...viewerBaseFacts(request),
          'Format': format,
          'Rows': '0',
          'Columns': '0',
          'Delimiter': result.metadata['isTabSeparated'] == true ? 'tab' : ',',
        },
        sections: [
          ViewerTextSection(
            title: 'Extracted text',
            text: result.text ?? 'The parser produced no text or table data.',
            monospace: true,
          ),
        ],
        notices: notices,
        footer: 'Panthalassa CSV/TSV viewer',
      );
    }

    final section = viewerTableSection(table, options, fallbackTitle: 'Data');
    final dataRowCount = section.totalRowCount ?? 0;
    final columnCount = section.columns.length;

    return ViewerDocument(
      title: title,
      formatLabel: format,
      subtitle:
          '$format table · $dataRowCount '
          'row${dataRowCount == 1 ? '' : 's'} × $columnCount '
          'column${columnCount == 1 ? '' : 's'}',
      facts: {
        ...viewerBaseFacts(request),
        'Format': format,
        'Rows': '$dataRowCount',
        'Columns': '$columnCount',
        'Delimiter': result.metadata['isTabSeparated'] == true ? 'tab' : ',',
      },
      sections: [section],
      notices: notices,
      footer: 'Panthalassa CSV/TSV viewer',
    );
  }
}
