import 'dart:convert';
import 'dart:typed_data';

import 'package:panthalassa_parsers/panthalassa_parsers.dart';
import 'package:test/test.dart';

Uint8List _bytes(String s) => Uint8List.fromList(latin1.encode(s));

Uint8List build({bool length = true, String literal = 'Hello World'}) {
  final objects = <String>[];
  objects.add('1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');
  objects.add('2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n');
  objects.add(
    '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] '
    '/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>\nendobj\n',
  );
  final content = 'BT /F1 12 Tf 10 100 Td ($literal) Tj ET\n';
  final len = length ? ' /Length ${content.length}' : '';
  objects.add('4 0 obj\n<<$len >>\nstream\n$content\nendstream\nendobj\n');
  objects.add(
    '5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n',
  );
  final body = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (final o in objects) {
    offsets.add(body.length);
    body.write(o);
  }
  final xref = body.length;
  body.write('xref\n0 ${objects.length + 1}\n');
  body.write('0000000000 65535 f \n');
  for (final off in offsets) {
    body.write('${off.toString().padLeft(10, '0')} 00000 n \n');
  }
  body.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
    'startxref\n$xref\n%%EOF\n',
  );
  return _bytes(body.toString());
}

void main() {
  final registry = ParserRegistry.standard();

  test('literal endstream with /Length', () {
    final r = registry.parse(build(literal: 'Hello endstream World'));
    expect(r.text, contains('Hello endstream World'));
  });

  test('literal endstream without /Length', () {
    final r = registry.parse(
      build(length: false, literal: 'Hello endstream World'),
    );
    expect(r.text, contains('Hello endstream World'));
  });

  test('fake object in stream is not indexed', () {
    final pdf = build(
      literal: 'Before 9 0 obj << /Type /Catalog >> endobj After',
    );
    final r = registry.parse(pdf);
    expect(r.text, contains('Before'));
    expect(r.text, contains('After'));
    expect(r.metadata['pageCount'], 1);
  });

  test('malformed hex is typed and payload-free', () {
    final good = build();
    final s = latin1
        .decode(good)
        .replaceFirst('/Length 39', '/Length 39 /Bad <zz>');
    // Malformed auxiliary values are skipped rather than allowed to escape as
    // raw FormatException/RangeError containing document bytes.
    final r = registry.parse(_bytes(s));
    expect(r.text, isNot(contains('zz')));
    expect(r.warnings.toString(), isNot(contains('zz')));
  });

  test('incremental update with two xref sections reports both pages', () {
    final original = build();
    final originalText = latin1.decode(original);
    final prevXref = int.parse(
      RegExp(r'startxref\s+(\d+)').firstMatch(originalText)!.group(1)!,
    );
    final body = StringBuffer(originalText);
    final newTwo = body.length;
    body.write(
      '2 0 obj\n<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>\nendobj\n',
    );
    final newFive = body.length;
    body.write(
      '5 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] '
      '/Resources << /Font << /F1 6 0 R >> >> /Contents 7 0 R >>\nendobj\n',
    );
    final content = 'BT /F1 12 Tf 10 100 Td (Page Two) Tj ET\n';
    final newSeven = body.length;
    body.write(
      '7 0 obj\n<< /Length ${content.length} >>\nstream\n$content\nendstream\nendobj\n',
    );
    final newSix = body.length;
    body.write(
      '6 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n',
    );
    final xref = body.length;
    body.write('xref\n2 1\n');
    body.write('${newTwo.toString().padLeft(10, '0')} 00000 n \n');
    body.write('5 3\n');
    for (final off in [newFive, newSix, newSeven]) {
      body.write('${off.toString().padLeft(10, '0')} 00000 n \n');
    }
    body.write(
      'trailer\n<< /Size 8 /Root 1 0 R /Prev $prevXref >>\n'
      'startxref\n$xref\n%%EOF\n',
    );
    final r = registry.parse(_bytes(body.toString()));
    expect(r.metadata['pageCount'], 2);
    expect(r.text, contains('Hello World'));
    expect(r.text, contains('Page Two'));
  });
}
