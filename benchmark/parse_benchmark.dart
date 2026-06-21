// ignore_for_file: avoid_print

import 'package:panthalassa_parsers/panthalassa_parsers.dart';

import '../test/support/fixtures.dart';

Future<void> main() async {
  final registry = ParserRegistry.standard();
  final cases = {
    'pdf-flate': buildSimplePdf(compress: true),
    'dicom-sequence': buildDicomWithSequenceAndMultiValues(),
    'mpeg-ts-klv': buildMpegTsWithKlv(),
    'nitf-segments': buildNitfWithSegments(),
  };

  for (final entry in cases.entries) {
    final sync = Stopwatch()..start();
    for (var i = 0; i < 100; i++) {
      registry.parse(entry.value);
    }
    sync.stop();

    final isolate = Stopwatch()..start();
    await registry.parseInIsolate(entry.value);
    isolate.stop();

    print(
      '${entry.key}: sync100=${sync.elapsedMicroseconds}us '
      'isolate1=${isolate.elapsedMicroseconds}us '
      'bytes=${entry.value.length}',
    );
  }
}
