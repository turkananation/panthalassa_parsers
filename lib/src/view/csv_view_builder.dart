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
    final table = result.tables.isEmpty ? null : result.tables.first;
    final tabSeparated = result.metadata['isTabSeparated'] == true;
    final format = tabSeparated ? 'TSV' : 'CSV';
    final title = options.title ?? viewerBasename(request.filename);
    final notices = <ViewerNotice>[
      for (final warning in result.warnings.take(8))
        ViewerNotice(
          '${warning.code}: ${warning.message}',
          level: ViewerNoticeLevel.warning,
        ),
    ];

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
        facts: _facts(request, format, 0, 0),
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
    final facts = _facts(request, format, dataRowCount, columnCount);

    return ViewerDocument(
      title: title,
      formatLabel: format,
      subtitle:
          '$format table · $dataRowCount '
          'row${dataRowCount == 1 ? '' : 's'} × $columnCount '
          'column${columnCount == 1 ? '' : 's'}',
      facts: facts,
      sections: [section],
      notices: notices,
      footer: 'Panthalassa CSV/TSV viewer',
    );
  }

  Map<String, String> _facts(
    ViewerRequest request,
    String format,
    int rowCount,
    int columnCount,
  ) {
    final result = request.result;
    return {
      'Format': format,
      'Rows': '$rowCount',
      'Columns': '$columnCount',
      'Delimiter': result.metadata['isTabSeparated'] == true ? 'tab' : ',',
      'Size': formatViewerBytes(request.bytes.length),
      'Document ID': result.documentId,
    };
  }
}
