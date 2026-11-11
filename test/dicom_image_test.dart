import 'dart:typed_data';

import 'package:panthalassa_parsers/panthalassa_parsers.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

List<int> _le16(int value) {
  final unsigned = value & 0xFFFF;
  return [unsigned & 0xFF, (unsigned >> 8) & 0xFF];
}

List<int> _le16Values(List<int> values) => [
  for (final value in values) ..._le16(value),
];

void main() {
  const parser = DicomParser();
  const decoder = DicomPixelDecoder(maxDimension: null);

  group('DicomParser.readImage', () {
    test('returns null when Pixel Data is absent', () {
      expect(parser.readImage(buildMinimalDicom()), isNull);
    });

    test('captures native 8-bit rows, columns, and photometric metadata', () {
      final image = parser.readImage(
        buildDicomImage(
          rows: 2,
          columns: 2,
          pixelBytes: [0, 64, 128, 255],
          windowCenter: 128,
          windowWidth: 256,
        ),
      );

      expect(image, isNotNull);
      expect(image!.rows, 2);
      expect(image.columns, 2);
      expect(image.bitsAllocated, 8);
      expect(image.bitsStored, 8);
      expect(image.photometricInterpretation, 'MONOCHROME2');
      expect(image.windowCenter, 128);
      expect(image.windowWidth, 256);
      expect(image.pixelData, isNotNull);
      expect(image.isEncapsulated, isFalse);
      expect(image.frameCount, 1);
    });

    test('reads implicit VR little endian pixel data', () {
      final image = parser.readImage(
        buildDicomImage(
          rows: 1,
          columns: 2,
          pixelBytes: [0, 255],
          implicitVr: true,
          windowCenter: 128,
          windowWidth: 256,
        ),
      )!;

      expect(image.transferSyntaxUid, '1.2.840.10008.1.2');
      expect(image.endian, Endian.little);
      expect(_grays(decoder.decode(image).rgba), [0, 255]);
    });

    test('reads explicit VR big endian pixel data', () {
      final image = parser.readImage(
        buildDicomImage(
          rows: 1,
          columns: 2,
          pixelBytes: [0, 0, 0, 255],
          bitsAllocated: 16,
          endian: Endian.big,
          windowCenter: 128,
          windowWidth: 256,
        ),
      )!;

      expect(image.transferSyntaxUid, '1.2.840.10008.1.2.2');
      expect(image.endian, Endian.big);
      expect(_grays(decoder.decode(image).rgba), [0, 255]);
    });

    test('inflates deflated explicit VR datasets before reading pixels', () {
      final image = parser.readImage(
        buildDicomImage(
          rows: 1,
          columns: 2,
          pixelBytes: [0, 255],
          deflated: true,
          windowCenter: 128,
          windowWidth: 256,
        ),
      )!;

      expect(image.transferSyntaxUid, '1.2.840.10008.1.2.1.99');
      expect(_grays(decoder.decode(image).rgba), [0, 255]);
    });

    test('accepts a non-standard zlib wrapper on a deflated dataset', () {
      final image = parser.readImage(
        buildDicomImage(
          rows: 1,
          columns: 2,
          pixelBytes: [0, 255],
          deflated: true,
          zlibWrapped: true,
          windowCenter: 128,
          windowWidth: 256,
        ),
      )!;

      expect(image.transferSyntaxUid, '1.2.840.10008.1.2.1.99');
      expect(_grays(decoder.decode(image).rgba), [0, 255]);
    });

    test('captures encapsulated fragments without decoding them', () {
      final image = parser.readImage(
        buildEncapsulatedDicomImage(
          rows: 1,
          columns: 2,
          frame: [1, 2, 3, 4],
          transferSyntax: '1.2.840.10008.1.2.4.90',
        ),
      );

      expect(image, isNotNull);
      expect(image!.isEncapsulated, isTrue);
      expect(image.pixelData, isNull);
      expect(image.compressedFrames, hasLength(1));
    });
  });

  group('DicomPixelDecoder monochrome', () {
    test('applies linear window/level and preserves pixel order', () {
      final image = parser.readImage(
        buildDicomImage(
          rows: 2,
          columns: 2,
          pixelBytes: [0, 64, 128, 255],
          windowCenter: 128,
          windowWidth: 256,
        ),
      )!;

      final frame = decoder.decode(image);
      expect(frame.width, 2);
      expect(frame.height, 2);
      expect(frame.rgba.length, 16);
      expect(_grays(frame.rgba), [0, 64, 128, 255]);
      expect(frame.windowCenter, 128);
      expect(frame.windowWidth, 256);
    });

    test('auto-windows when no window tags are present', () {
      final image = parser.readImage(
        buildDicomImage(rows: 1, columns: 4, pixelBytes: [10, 20, 30, 40]),
      )!;

      final frame = decoder.decode(image);
      expect(_grays(frame.rgba), [0, 88, 176, 255]);
      expect(frame.windowCenter, 25);
      expect(frame.windowWidth, 30);
    });

    test('supports signed 16-bit values and rescale slope/intercept', () {
      final raw = _le16Values([-1000, -1, 0, 1000]);
      final image = parser.readImage(
        buildDicomImage(
          rows: 1,
          columns: 4,
          pixelBytes: raw,
          bitsAllocated: 16,
          pixelRepresentation: 1,
          windowCenter: 0,
          windowWidth: 2000,
        ),
      )!;

      expect(image.pixelRepresentation, 1);
      final frame = decoder.decode(image);
      final grays = _grays(frame.rgba);
      expect(grays.first, 0);
      expect(grays.last, 255);
      expect(grays[1], inInclusiveRange(120, 135));
      expect(grays[2], inInclusiveRange(125, 140));

      final rescaled = parser.readImage(
        buildDicomImage(
          rows: 1,
          columns: 2,
          pixelBytes: _le16Values([0, 1000]),
          bitsAllocated: 16,
          pixelRepresentation: 1,
          rescaleSlope: 2,
          rescaleIntercept: -1000,
          windowCenter: 0,
          windowWidth: 2000,
        ),
      )!;
      expect(_grays(decoder.decode(rescaled).rgba), [0, 255]);
    });

    test('reads 16-bit big-endian samples through the endian parameter', () {
      final image = DicomImageData(
        rows: 1,
        columns: 2,
        numberOfFrames: 1,
        bitsAllocated: 16,
        bitsStored: 16,
        highBit: 15,
        pixelRepresentation: 0,
        samplesPerPixel: 1,
        photometricInterpretation: 'MONOCHROME2',
        planarConfiguration: 0,
        transferSyntaxUid: '1.2.840.10008.1.2.2',
        endian: Endian.big,
        pixelData: Uint8List.fromList([0, 0, 0, 255]),
        windowCenter: 128,
        windowWidth: 256,
      );

      expect(_grays(decoder.decode(image).rgba), [0, 255]);
    });

    test('inverts MONOCHROME1 and honours the invert option', () {
      final mono1 = parser.readImage(
        buildDicomImage(
          rows: 1,
          columns: 2,
          pixelBytes: [0, 255],
          photometricInterpretation: 'MONOCHROME1',
          windowCenter: 128,
          windowWidth: 256,
        ),
      )!;
      expect(_grays(decoder.decode(mono1).rgba), [255, 0]);
      expect(_grays(decoder.decode(mono1, invert: true).rgba), [0, 255]);
    });

    test('encodes the decoded frame as a PNG', () {
      final image = parser.readImage(
        buildDicomImage(rows: 1, columns: 1, pixelBytes: [128]),
      )!;
      final png = decoder.decode(image).encodePng();
      expect(png.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    });
  });

  group('DicomPixelDecoder colour', () {
    test('decodes interleaved RGB', () {
      final image = parser.readImage(
        buildDicomImage(
          rows: 1,
          columns: 2,
          pixelBytes: [255, 0, 0, 0, 255, 0],
          samplesPerPixel: 3,
          photometricInterpretation: 'RGB',
        ),
      )!;

      final frame = decoder.decode(image);
      expect(_pixels(frame.rgba), [
        [255, 0, 0, 255],
        [0, 255, 0, 255],
      ]);
    });

    test('decodes planar RGB', () {
      final image = parser.readImage(
        buildDicomImage(
          rows: 1,
          columns: 2,
          pixelBytes: [255, 0, 0, 255, 0, 0],
          samplesPerPixel: 3,
          photometricInterpretation: 'RGB',
          planarConfiguration: 1,
        ),
      )!;

      expect(_pixels(decoder.decode(image).rgba), [
        [255, 0, 0, 255],
        [0, 255, 0, 255],
      ]);
    });

    test('expands YBR_FULL_422 pairs into RGBA', () {
      final image = parser.readImage(
        buildDicomImage(
          rows: 1,
          columns: 2,
          pixelBytes: [76, 150, 85, 255],
          samplesPerPixel: 3,
          photometricInterpretation: 'YBR_FULL_422',
        ),
      )!;

      final pixels = _pixels(decoder.decode(image).rgba);
      expect(pixels, hasLength(2));
      expect(pixels[0][0], greaterThan(200));
      expect(pixels[0][3], 255);
      expect(pixels[1][3], 255);
    });
  });

  group('DicomPixelDecoder compressed', () {
    test('decodes an RLE lossless frame', () {
      final image = parser.readImage(buildDicomRleImage())!;

      expect(image.isRle, isTrue);
      expect(image.frameCount, 1);
      final frame = decoder.decode(image, windowCenter: 128, windowWidth: 256);
      expect(_grays(frame.rgba), [0, 85, 170, 255]);
    });

    test('decodes a JPEG baseline frame and keeps alpha opaque', () {
      final image = parser.readImage(buildDicomJpegImage())!;

      expect(image.isJpegBaseline, isTrue);
      final frame = decoder.decode(image);
      expect(frame.width, 2);
      expect(frame.height, 2);
      expect(frame.rgba.length, 16);
      for (var i = 3; i < frame.rgba.length; i += 4) {
        expect(frame.rgba[i], 255);
      }
    });

    test('rejects unsupported encapsulated transfer syntaxes', () {
      final image = parser.readImage(
        buildEncapsulatedDicomImage(
          rows: 1,
          columns: 1,
          frame: [1, 2, 3, 4],
          transferSyntax: '1.2.840.10008.1.2.4.90',
        ),
      )!;

      expect(
        () => decoder.decode(image),
        throwsA(isA<UnsupportedFeatureException>()),
      );
    });

    test('rejects unsupported bits allocated', () {
      final image = DicomImageData(
        rows: 1,
        columns: 1,
        numberOfFrames: 1,
        bitsAllocated: 32,
        bitsStored: 32,
        highBit: 31,
        pixelRepresentation: 0,
        samplesPerPixel: 1,
        photometricInterpretation: 'MONOCHROME2',
        planarConfiguration: 0,
        transferSyntaxUid: '1.2.840.10008.1.2.1',
        endian: Endian.little,
        pixelData: Uint8List(4),
      );

      expect(
        () => decoder.decode(image),
        throwsA(isA<UnsupportedFeatureException>()),
      );
    });

    test('rejects a frame index beyond the available frames', () {
      final image = parser.readImage(
        buildDicomImage(rows: 1, columns: 1, pixelBytes: [0]),
      )!;

      expect(
        () => decoder.decode(image, frame: 1),
        throwsA(isA<MalformedDocumentException>()),
      );
    });

    test('rejects frames above the configured input pixel cap', () {
      final image = DicomImageData(
        rows: 100,
        columns: 100,
        numberOfFrames: 1,
        bitsAllocated: 8,
        bitsStored: 8,
        highBit: 7,
        pixelRepresentation: 0,
        samplesPerPixel: 1,
        photometricInterpretation: 'MONOCHROME2',
        planarConfiguration: 0,
        transferSyntaxUid: '1.2.840.10008.1.2.1',
        endian: Endian.little,
        pixelData: Uint8List(100 * 100),
      );

      expect(
        () => const DicomPixelDecoder(
          maxDimension: null,
          maxInputPixels: 10,
        ).decode(image),
        throwsA(isA<UnsupportedFeatureException>()),
      );
    });
  });
}

List<int> _grays(Uint8List rgba) => [
  for (var i = 0; i < rgba.length; i += 4) rgba[i],
];

List<List<int>> _pixels(Uint8List rgba) => [
  for (var i = 0; i < rgba.length; i += 4) rgba.sublist(i, i + 4),
];
