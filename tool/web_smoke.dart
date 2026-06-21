import 'dart:convert';
import 'dart:typed_data';

import 'package:panthalassa_parsers/panthalassa_parsers.dart';

void main() {
  final registry = ParserRegistry.standard();
  final bytes = Uint8List.fromList(utf8.encode('{"hello":"web"}'));
  final result = registry.parse(bytes);
  if (result.format != DocumentFormat.json || result.documentId.length != 64) {
    throw StateError('web smoke parse failed');
  }
}
