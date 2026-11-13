import '../core/document_format.dart';
import '../core/parse_result.dart';
import 'viewer_document.dart';
import 'viewer_support.dart';

/// Workbook viewer for XLSX and ODS spreadsheets.
///
/// Each parser table becomes a filterable sheet section, reusing the same grid
/// and client-side filtering as the CSV/TSV viewer.
final class SpreadsheetViewBuilder implements ViewBuilder {
  const SpreadsheetViewBuilder();

  @override
  String get id => 'spreadsheet';

  @override
  bool supports(ParseResult result) {
    if (result.tables.isEmpty) return false;
    if (result.format == DocumentFormat.xlsx) return true;
    return result.format == DocumentFormat.odf &&
        result.metadata['documentClass'] == 'spreadsheet';
  }

  @override
  ViewerDocument build(ViewerRequest request) {
    final result = request.result;
    final title = viewerTitle(request);
    final formatLabel = result.format == DocumentFormat.odf
        ? 'ODS spreadsheet'
        : result.format.label;
    final sections = <ViewerSection>[
      for (var i = 0; i < result.tables.length; i++)
        viewerTableSection(
          result.tables[i],
          request.options,
          fallbackTitle: 'Sheet ${i + 1}',
        ),
    ];
    var rowCount = 0;
    for (final section in sections.whereType<ViewerTableSection>()) {
      rowCount += section.totalRowCount ?? section.rows.length;
    }
    return ViewerDocument(
      title: title,
      formatLabel: formatLabel,
      subtitle:
          '$formatLabel · ${sections.length} '
          'sheet${sections.length == 1 ? '' : 's'} · $rowCount data '
          'row${rowCount == 1 ? '' : 's'}',
      facts: {
        ...viewerBaseFacts(request),
        'Format': formatLabel,
        'Sheets': '${sections.length}',
        'Rows': '$rowCount',
      },
      sections: sections,
      notices: viewerWarnings(result),
      footer: 'Panthalassa spreadsheet viewer',
    );
  }
}
