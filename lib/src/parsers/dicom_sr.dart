import '../core/parse_options.dart';
import '../core/parse_result.dart';
import '../core/structured_artifacts.dart';

/// Format a DICOM tag as `(GGGG,EEEE)`.
String dicomTagHex(int tag) =>
    '(${(tag >> 16).toRadixString(16).padLeft(4, '0').toUpperCase()},'
    '${(tag & 0xFFFF).toRadixString(16).padLeft(4, '0').toUpperCase()})';

/// Normalised DICOM Structured Report content extracted from a ContentSequence.
final class DicomStructuredReport {
  const DicomStructuredReport({
    required this.text,
    required this.outline,
    required this.blocks,
    required this.tables,
    required this.tree,
  });

  final String? text;
  final List<OutlineEntry> outline;
  final List<TextBlock> blocks;
  final List<DocumentTable> tables;
  final List<Map<String, Object?>> tree;
}

/// Extracts the SR content tree from parsed DICOM attributes.
///
/// Attribute maps use the same shape as [DicomParser]'s `attributes` output:
/// `{'tag': '(0040,A730)', 'vr': 'SQ', 'items': [...]}`. Returns `null` when
/// no ContentSequence is present.
DicomStructuredReport? extractDicomStructuredReport(
  List<Map<String, Object?>> attributes,
  ParseOptions options,
  List<ParseWarning> warnings,
) {
  final content = _findAttribute(attributes, 0x0040A730);
  if (content == null) return null;
  final items = content['items'];
  if (items is! List || items.isEmpty) return null;

  final tree = <Map<String, Object?>>[];
  final lines = <String>[];
  final outline = <OutlineEntry>[];
  final blocks = <TextBlock>[];
  final rows = <List<String>>[];
  var nodes = 0;
  var truncated = false;
  final maxNodes = options.limits.maxSegments;

  void walk(
    Map<String, Object?> item,
    int depth,
    List<Map<String, Object?>> siblings,
  ) {
    if (nodes >= maxNodes || depth > 16) {
      truncated = true;
      return;
    }
    nodes++;
    final itemAttributes = _itemAttributes(item);
    final concept = _codeMeaning(itemAttributes, 0x0040A043);
    final valueType = _stringValue(itemAttributes, 0x0040A040);
    final relationship = _stringValue(itemAttributes, 0x0040A010);
    final value = _contentValue(itemAttributes);
    final label = concept ?? value ?? 'Content item';

    if (concept != null && value == null) {
      final level = (depth + 1).clamp(1, 6);
      outline.add(OutlineEntry(title: concept, level: level));
      blocks.add(
        TextBlock(spans: [TextSpan(concept)], style: 'heading', level: level),
      );
      lines.add(concept);
    } else if (value != null) {
      final text = concept == null ? value : '$concept: $value';
      lines.add(text);
      blocks.add(TextBlock(spans: [TextSpan(text)], style: 'paragraph'));
    }
    rows.add([
      label,
      relationship ?? '',
      valueType ?? '',
      value ?? '',
      _codeMeaning(itemAttributes, 0x004008EA) ?? '',
    ]);

    final children = <Map<String, Object?>>[];
    final nested = _findAttribute(itemAttributes, 0x0040A730);
    if (nested != null) {
      final nestedItems = nested['items'];
      if (nestedItems is List) {
        for (final child in nestedItems) {
          if (child is Map<String, Object?>) {
            walk(child, depth + 1, children);
          }
        }
      }
    }
    siblings.add({
      'concept': ?concept,
      'relationship': ?relationship,
      'valueType': ?valueType,
      'value': ?value,
      'children': children,
    });
  }

  for (final item in items) {
    if (item is Map<String, Object?>) {
      walk(item, 0, tree);
    }
  }

  if (nodes == 0) return null;
  if (truncated) {
    warnings.add(
      ParseWarning(
        'dicom.sr_limit',
        'structured report content exceeded $maxNodes nodes',
      ),
    );
  }

  var text = lines.join('\n');
  if (text.length > options.limits.maxTextCharacters) {
    text = text.substring(0, options.limits.maxTextCharacters);
    warnings.add(
      ParseWarning(
        'dicom.sr_text_truncated',
        'structured report text exceeded '
            '${options.limits.maxTextCharacters} characters',
      ),
    );
  }

  final tables = <DocumentTable>[];
  if (options.includeTables && rows.isNotEmpty) {
    tables.add(
      DocumentTable(
        name: 'structured-report',
        rows: [
          ['concept', 'relationship', 'valueType', 'value', 'units'],
          ...rows.take(options.limits.maxTableRows),
        ],
      ),
    );
  }

  return DicomStructuredReport(
    text: text.isEmpty ? null : text,
    outline: outline,
    blocks: blocks,
    tables: tables,
    tree: tree,
  );
}

List<Map<String, Object?>> _itemAttributes(Map<String, Object?> item) {
  final attributes = item['attributes'];
  if (attributes is List) {
    return [
      for (final value in attributes)
        if (value is Map<String, Object?>) value,
    ];
  }
  return const [];
}

Map<String, Object?>? _findAttribute(
  List<Map<String, Object?>> attributes,
  int tag,
) {
  final hex = dicomTagHex(tag);
  for (final attribute in attributes) {
    if (attribute['tag'] == hex) return attribute;
  }
  return null;
}

String? _stringValue(List<Map<String, Object?>> attributes, int tag) {
  final value = _findAttribute(attributes, tag)?['value'];
  if (value is String && value.trim().isNotEmpty) return value.trim();
  if (value is num) return '$value';
  if (value is List) {
    for (final item in value) {
      if (item is String && item.trim().isNotEmpty) return item.trim();
      if (item is num) return '$item';
    }
  }
  return null;
}

String? _codeMeaning(List<Map<String, Object?>> attributes, int tag) {
  final sequence = _findAttribute(attributes, tag);
  if (sequence == null) return null;
  final items = sequence['items'];
  if (items is! List) return null;
  for (final item in items) {
    if (item is! Map<String, Object?>) continue;
    final meaning = _stringValue(_itemAttributes(item), 0x00080104);
    if (meaning != null) return meaning;
  }
  return null;
}

String? _contentValue(List<Map<String, Object?>> attributes) {
  for (final tag in const [
    0x0040A160, // TextValue
    0x0040A123, // PersonName
    0x0040A120, // DateTime
    0x0040A124, // UID
    0x0040A30A, // NumericValue
  ]) {
    final value = _stringValue(attributes, tag);
    if (value == null) continue;
    if (tag == 0x0040A30A) {
      final units = _codeMeaning(attributes, 0x004008EA);
      return units == null ? value : '$value $units';
    }
    return value;
  }
  return _codeMeaning(attributes, 0x0040A168);
}
