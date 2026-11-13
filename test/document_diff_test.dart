import 'package:panthalassa_parsers/panthalassa_parsers.dart';
import 'package:test/test.dart';

void main() {
  test('identical texts produce no changed rows', () {
    final diff = DocumentDiff.fromTexts('alpha\nbeta', 'alpha\nbeta');
    expect(diff.hasChanges, isFalse);
    expect(diff.oldLineCount, 2);
    expect(diff.newLineCount, 2);
    expect(diff.rows, hasLength(2));
    expect(
      diff.rows.every((row) => row.left?.kind == DiffKind.unchanged),
      isTrue,
    );
  });

  test('marks inserted and removed lines with line numbers', () {
    final diff = DocumentDiff.fromTexts('one\ntwo\nthree', 'one\nthree\nfour');
    expect(diff.hasChanges, isTrue);

    final removed = diff.rows
        .where((row) => row.left?.kind == DiffKind.removed)
        .map((row) => row.left!.text)
        .toList();
    final added = diff.rows
        .where((row) => row.right?.kind == DiffKind.added)
        .map((row) => row.right!.text)
        .toList();
    expect(removed, ['two']);
    expect(added, ['four']);
    expect(
      diff.rows.firstWhere((row) => row.left?.text == 'two').left!.lineNumber,
      2,
    );
    expect(
      diff.rows
          .firstWhere((row) => row.right?.text == 'four')
          .right!
          .lineNumber,
      3,
    );
  });

  test('pairs replaced lines side by side', () {
    final diff = DocumentDiff.fromTexts('before', 'after');
    final changed = diff.rows.single;
    expect(changed.left?.kind, DiffKind.removed);
    expect(changed.right?.kind, DiffKind.added);
    expect(changed.left?.text, 'before');
    expect(changed.right?.text, 'after');
  });

  test('empty documents compare cleanly', () {
    final diff = DocumentDiff.fromTexts('', '');
    expect(diff.rows, isEmpty);
    expect(diff.hasChanges, isFalse);
    expect(diff.truncated, isFalse);
  });

  test('large comparisons fall back to positional matching', () {
    final before = List.generate(30, (index) => 'line $index').join('\n');
    final after = List.generate(25, (index) => 'line $index').join('\n');
    final diff = DocumentDiff.fromTexts(before, after, maxLines: 10);
    expect(diff.truncated, isTrue);
    expect(diff.hasChanges, isTrue);
    expect(diff.oldLineCount, 30);
    expect(diff.newLineCount, 25);
  });

  test('compares DocumentIr through the text renderer', () {
    const before = DocumentIr(
      sourceFormat: DocumentFormat.unknown,
      metadata: {},
      body: [
        ParagraphBlock([TextRun('old body')]),
      ],
    );
    const after = DocumentIr(
      sourceFormat: DocumentFormat.unknown,
      metadata: {},
      body: [
        ParagraphBlock([TextRun('new body')]),
      ],
    );
    final diff = DocumentDiff.between(before, after);
    expect(diff.hasChanges, isTrue);
    expect(diff.rows.any((row) => row.left?.text == 'old body'), isTrue);
    expect(diff.rows.any((row) => row.right?.text == 'new body'), isTrue);
  });
}
