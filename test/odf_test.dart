import 'package:panthalassa_parsers/panthalassa_parsers.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final registry = ParserRegistry.standard();

  test('detects ODF via mimetype member and extracts paragraph text', () {
    final r = registry.parse(buildMinimalOdf(paragraph: 'Civic ledger entry'));
    expect(r.format, DocumentFormat.odf);
    expect(r.metadata['documentClass'], 'text');
    expect(r.text, contains('Civic ledger entry'));
    expect(r.metadata['paragraphCount'], 1);
  });
}
