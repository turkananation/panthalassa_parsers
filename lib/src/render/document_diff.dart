import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'document_ir.dart';
import 'document_renderer.dart';

/// Classification of one side of a [DiffRow].
enum DiffKind { unchanged, added, removed }

/// One numbered line in a side-by-side diff.
@immutable
final class DiffLine {
  const DiffLine({
    required this.kind,
    required this.text,
    required this.lineNumber,
  });

  final DiffKind kind;
  final String text;
  final int lineNumber;
}

/// A side-by-side row. Missing sides represent pure insertions/deletions.
@immutable
final class DiffRow {
  const DiffRow({this.left, this.right});

  final DiffLine? left;
  final DiffLine? right;

  bool get isChanged =>
      left?.kind == DiffKind.removed || right?.kind == DiffKind.added;
}

/// Line-level comparison of two semantic documents.
///
/// The diff is intentionally pure Dart and bounded: very large documents fall
/// back to positional comparison instead of allocating an unbounded LCS table.
@immutable
final class DocumentDiff {
  const DocumentDiff({
    required this.rows,
    required this.oldLineCount,
    required this.newLineCount,
    this.truncated = false,
  });

  final List<DiffRow> rows;
  final int oldLineCount;
  final int newLineCount;
  final bool truncated;

  bool get hasChanges => rows.any((row) => row.isChanged);

  /// Compares [before] and [after] after flattening both through the text
  /// renderer, so only semantic content participates.
  factory DocumentDiff.between(
    DocumentIr before,
    DocumentIr after, {
    int maxLines = 2000,
  }) {
    const renderer = TextDocumentRenderer();
    return DocumentDiff.fromTexts(
      renderer.render(before),
      renderer.render(after),
      maxLines: maxLines,
    );
  }

  /// Compares two plain-text payloads line by line.
  factory DocumentDiff.fromTexts(
    String before,
    String after, {
    int maxLines = 2000,
  }) {
    final left = _lines(before);
    final right = _lines(after);
    if (left.isEmpty && right.isEmpty) {
      return const DocumentDiff(rows: [], oldLineCount: 0, newLineCount: 0);
    }
    if (left.length > maxLines ||
        right.length > maxLines ||
        left.length * right.length > 4_000_000) {
      return DocumentDiff(
        rows: _positional(left, right),
        oldLineCount: left.length,
        newLineCount: right.length,
        truncated: true,
      );
    }
    return DocumentDiff(
      rows: _lcsRows(left, right),
      oldLineCount: left.length,
      newLineCount: right.length,
    );
  }
}

List<String> _lines(String text) {
  if (text.isEmpty) return const [];
  final lines = text.split('\n');
  if (lines.last.isEmpty) lines.removeLast();
  return lines;
}

List<DiffRow> _positional(List<String> left, List<String> right) {
  final rows = <DiffRow>[];
  final count = left.length > right.length ? left.length : right.length;
  for (var index = 0; index < count; index++) {
    final a = index < left.length ? left[index] : null;
    final b = index < right.length ? right[index] : null;
    if (a != null && a == b) {
      rows.add(
        DiffRow(
          left: DiffLine(
            kind: DiffKind.unchanged,
            text: a,
            lineNumber: index + 1,
          ),
          right: DiffLine(
            kind: DiffKind.unchanged,
            text: b!,
            lineNumber: index + 1,
          ),
        ),
      );
      continue;
    }
    rows.add(
      DiffRow(
        left: a == null
            ? null
            : DiffLine(kind: DiffKind.removed, text: a, lineNumber: index + 1),
        right: b == null
            ? null
            : DiffLine(kind: DiffKind.added, text: b, lineNumber: index + 1),
      ),
    );
  }
  return rows;
}

List<DiffRow> _lcsRows(List<String> left, List<String> right) {
  final n = left.length;
  final m = right.length;
  final width = m + 1;
  final table = Uint32List((n + 1) * width);
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      table[i * width + j] = left[i - 1] == right[j - 1]
          ? table[(i - 1) * width + (j - 1)] + 1
          : (table[(i - 1) * width + j] >= table[i * width + (j - 1)]
                ? table[(i - 1) * width + j]
                : table[i * width + (j - 1)]);
    }
  }

  final ops = <_Op>[];
  var i = n;
  var j = m;
  while (i > 0 || j > 0) {
    if (i > 0 && j > 0 && left[i - 1] == right[j - 1]) {
      ops.add(_Op(DiffKind.unchanged, left[i - 1], i, j));
      i--;
      j--;
    } else if (j > 0 &&
        (i == 0 || table[i * width + (j - 1)] >= table[(i - 1) * width + j])) {
      ops.add(_Op(DiffKind.added, right[j - 1], i, j));
      j--;
    } else {
      ops.add(_Op(DiffKind.removed, left[i - 1], i, j));
      i--;
    }
  }
  return _pairRuns(ops.reversed.toList());
}

List<DiffRow> _pairRuns(List<_Op> ops) {
  final rows = <DiffRow>[];
  var index = 0;
  while (index < ops.length) {
    final op = ops[index];
    if (op.kind == DiffKind.unchanged) {
      rows.add(
        DiffRow(
          left: DiffLine(
            kind: DiffKind.unchanged,
            text: op.text,
            lineNumber: op.oldLine,
          ),
          right: DiffLine(
            kind: DiffKind.unchanged,
            text: op.text,
            lineNumber: op.newLine,
          ),
        ),
      );
      index++;
      continue;
    }

    final removed = <_Op>[];
    final added = <_Op>[];
    while (index < ops.length && ops[index].kind != DiffKind.unchanged) {
      final changed = ops[index];
      (changed.kind == DiffKind.removed ? removed : added).add(changed);
      index++;
    }
    final count = removed.length > added.length ? removed.length : added.length;
    for (var offset = 0; offset < count; offset++) {
      rows.add(
        DiffRow(
          left: offset < removed.length
              ? DiffLine(
                  kind: DiffKind.removed,
                  text: removed[offset].text,
                  lineNumber: removed[offset].oldLine,
                )
              : null,
          right: offset < added.length
              ? DiffLine(
                  kind: DiffKind.added,
                  text: added[offset].text,
                  lineNumber: added[offset].newLine,
                )
              : null,
        ),
      );
    }
  }
  return rows;
}

final class _Op {
  const _Op(this.kind, this.text, this.oldLine, this.newLine);
  final DiffKind kind;
  final String text;
  final int oldLine;
  final int newLine;
}
