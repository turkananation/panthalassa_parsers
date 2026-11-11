/// Small shared formatting helpers for viewer builders.
library;

import '../core/parse_result.dart';
import '../core/structured_artifacts.dart';
import 'viewer_document.dart';

/// Converts a result's warnings (bounded to 8) into viewer notices.
///
/// All builders use the same warning ceiling and label format so the warning
/// surface is consistent across formats.
List<ViewerNotice> viewerWarnings(ParseResult result) => [
      for (final warning in result.warnings.take(8))
        ViewerNotice(
          '${warning.code}: ${warning.message}',
          level: ViewerNoticeLevel.warning,
        ),
    ];

/// Title shared by every viewer: the explicit option title or the source
/// filename basename.
String viewerTitle(ViewerRequest request) =>
    request.options.title ?? viewerBasename(request.filename);

/// Base facts shown by every viewer: size and document id.
Map<String, String> viewerBaseFacts(ViewerRequest request) => {
      'Size': formatViewerBytes(request.bytes.length),
      'Document ID': request.result.documentId,
    };

/// Human byte count with binary units.
String formatViewerBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100
      ? 0
      : value >= 10
      ? 1
      : 2;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// Final path component for viewer titles, accepting `/` and `\`.
String viewerBasename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final trimmed = normalized.endsWith('/')
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
  final slash = trimmed.lastIndexOf('/');
  return slash < 0 ? trimmed : trimmed.substring(slash + 1);
}

/// First non-empty string in a scalar or list value.
String? viewerString(Object? value) {
  if (value == null) return null;
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  if (value is num || value is bool) return '$value';
  if (value is Iterable) {
    for (final item in value) {
      final parsed = viewerString(item);
      if (parsed != null) return parsed;
    }
  }
  return null;
}

/// Renders a metadata value compactly for a facts panel.
String viewerValue(Object? value) {
  final scalar = viewerString(value);
  if (scalar != null) return scalar;
  if (value is Iterable) {
    return value.map(viewerValue).where((v) => v.isNotEmpty).join(', ');
  }
  if (value is Map) {
    return value.entries
        .map((entry) => '${entry.key}: ${viewerValue(entry.value)}')
        .join('; ');
  }
  return '';
}

int? viewerInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

/// Converts a parser table into the viewer's bounded, filterable grid.
ViewerTableSection viewerTableSection(
  DocumentTable table,
  ViewerOptions options, {
  String? fallbackTitle,
}) {
  final allRows = table.rows;
  final header = allRows.isNotEmpty ? allRows.first : const <String>[];
  final data = allRows.length > 1 ? allRows.sublist(1) : const <List<String>>[];
  var columnCount = header.length;
  for (final row in data) {
    if (row.length > columnCount) columnCount = row.length;
  }
  final columns = [
    for (var i = 0; i < columnCount; i++)
      _columnName(i < header.length ? header[i] : '', i),
  ];
  final limit = options.allRows || options.rowLimit <= 0
      ? null
      : options.rowLimit;
  final shown = limit == null || limit >= data.length ? data.length : limit;
  final name = table.name?.trim() ?? '';
  return ViewerTableSection(
    title: name.isEmpty ? fallbackTitle : name,
    columns: columns,
    rows: [
      for (final row in data.take(shown))
        [for (var i = 0; i < columnCount; i++) i < row.length ? row[i] : ''],
    ],
    caption: table.caption,
    totalRowCount: data.length,
    truncated: shown < data.length,
    filterable: true,
  );
}

/// Metadata rows suitable for a side table; visual page payloads are skipped.
List<List<String>> viewerMetadataRows(
  Map<String, Object?> metadata, {
  int maxRows = 200,
}) {
  final rows = <List<String>>[];
  for (final entry in metadata.entries) {
    if (entry.key == 'visualPages' || rows.length >= maxRows) continue;
    final value = viewerValue(entry.value);
    if (value.isEmpty) continue;
    rows.add([entry.key, value]);
  }
  return rows;
}

String _columnName(String value, int index) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? 'Column ${index + 1}' : trimmed;
}
