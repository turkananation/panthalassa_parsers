/// Small shared formatting helpers for viewer builders.
library;

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
