import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:meta/meta.dart';

import '../../core/parse_exception.dart';

/// Raw DICOM image parameters and pixel payload, independent of any renderer.
///
/// [DicomParser.readImage] returns this object for one DICOM instance. Keep it
/// in memory only as long as needed: native pixel data can be large, and
/// rendered artifacts may contain protected health information.
@immutable
final class DicomImageData {
  const DicomImageData({
    required this.rows,
    required this.columns,
    required this.numberOfFrames,
    required this.bitsAllocated,
    required this.bitsStored,
    required this.highBit,
    required this.pixelRepresentation,
    required this.samplesPerPixel,
    required this.photometricInterpretation,
    required this.planarConfiguration,
    required this.transferSyntaxUid,
    required this.endian,
    this.transferSyntaxName,
    this.pixelData,
    this.compressedFrames,
    this.rescaleSlope = 1.0,
    this.rescaleIntercept = 0.0,
    this.windowCenter,
    this.windowWidth,
    this.voiLutFunction,
    this.pixelSpacing,
    this.pixelPaddingValue,
  });

  final int rows;
  final int columns;
  final int numberOfFrames;
  final int bitsAllocated;
  final int bitsStored;
  final int highBit;
  final int pixelRepresentation;
  final int samplesPerPixel;
  final String photometricInterpretation;
  final int planarConfiguration;
  final String transferSyntaxUid;
  final String? transferSyntaxName;
  final Endian endian;

  /// Native (uncompressed) pixel bytes. Null for encapsulated pixel data.
  final Uint8List? pixelData;

  /// Encapsulated frames after basic-offset-table/fragment assembly.
  final List<Uint8List>? compressedFrames;

  final double rescaleSlope;
  final double rescaleIntercept;
  final double? windowCenter;
  final double? windowWidth;
  final String? voiLutFunction;
  final String? pixelSpacing;
  final int? pixelPaddingValue;

  bool get isEncapsulated => compressedFrames != null;

  bool get hasPixelData =>
      pixelData != null || (compressedFrames?.isNotEmpty ?? false);

  bool get isRle => transferSyntaxUid == '1.2.840.10008.1.2.5';

  bool get isJpegBaseline => transferSyntaxUid == '1.2.840.10008.1.2.4.50';

  bool get isJpeg => transferSyntaxUid.startsWith('1.2.840.10008.1.2.4.');

  int get bytesPerSample => bitsAllocated ~/ 8;

  /// DICOM YBR_FULL_422 packs two pixels into four bytes.
  int get bytesPerPixel => photometricInterpretation == 'YBR_FULL_422'
      ? 2
      : samplesPerPixel * bytesPerSample;

  int get frameLengthBytes => rows * columns * bytesPerPixel;

  /// Number of usable frames. Native data is bounded by the bytes actually
  /// present, so a bogus Number of Frames value cannot trigger over-reads.
  int get frameCount {
    final compressed = compressedFrames;
    if (compressed != null) return compressed.length;
    final data = pixelData;
    if (data == null || frameLengthBytes <= 0) return 0;
    final available = data.length ~/ frameLengthBytes;
    final declared = numberOfFrames <= 0 ? 1 : numberOfFrames;
    return available < declared ? available : declared;
  }
}

/// Decoded RGBA pixels plus the window actually applied.
@immutable
final class DicomDecodedFrame {
  const DicomDecodedFrame({
    required this.width,
    required this.height,
    required this.rgba,
    required this.frameIndex,
    required this.frameCount,
    required this.photometricInterpretation,
    this.windowCenter,
    this.windowWidth,
    this.inverted = false,
  });

  final int width;
  final int height;
  final Uint8List rgba;
  final int frameIndex;
  final int frameCount;
  final String photometricInterpretation;
  final double? windowCenter;
  final double? windowWidth;
  final bool inverted;

  /// Encodes the RGBA buffer as an 8-bit PNG for HTML/Flutter consumers.
  Uint8List encodePng() {
    try {
      final image = img.Image.fromBytes(
        width: width,
        height: height,
        bytes: rgba.buffer,
        numChannels: 4,
      );
      return img.encodePng(image);
    } on Object catch (error) {
      throw MalformedDocumentException('PNG encoding failed: $error');
    }
  }
}

/// Pure-Dart DICOM pixel decoder for uncompressed, RLE, and JPEG-baseline data.
///
/// JPEG-LS, JPEG 2000, and JPEG lossless are not decoded by `package:image`;
/// those transfer syntaxes surface as [UnsupportedFeatureException] so callers
/// can fall back to metadata-only viewing or an external viewer.
final class DicomPixelDecoder {
  const DicomPixelDecoder({
    this.maxDimension = 2048,
    this.maxInputPixels = 16 * 1024 * 1024,
  });

  /// Longest output edge before nearest-neighbour downsampling. Set to null to
  /// retain the original dimensions.
  final int? maxDimension;

  /// Largest declared frame (Rows x Columns) that will be decoded. This bounds
  /// memory for accidentally enormous whole-slide/pathology instances before
  /// any pixel buffer is allocated. Set to null to disable the guard.
  final int? maxInputPixels;

  DicomDecodedFrame decode(
    DicomImageData image, {
    int frame = 0,
    double? windowCenter,
    double? windowWidth,
    bool invert = false,
  }) {
    final count = image.frameCount;
    if (count <= 0) {
      throw const MalformedDocumentException('DICOM image has no pixel data');
    }
    if (frame < 0 || frame >= count) {
      throw MalformedDocumentException(
        'requested DICOM frame ${frame + 1} but only $count frame(s) '
        'are available',
      );
    }
    final inputPixels = image.rows * image.columns;
    final cap = maxInputPixels;
    if (cap != null && cap > 0 && inputPixels > cap) {
      throw UnsupportedFeatureException(
        'DICOM frame ${image.columns} x ${image.rows} exceeds the '
        '$cap-pixel decode limit',
      );
    }

    final compressed = image.compressedFrames;
    if (compressed != null) {
      final data = compressed[frame];
      if (image.isRle) {
        return _decodeNative(
          image,
          _decodeRleFrame(image, data),
          frame: frame,
          frameCount: count,
          windowCenter: windowCenter,
          windowWidth: windowWidth,
          invert: invert,
          endian: Endian.little,
          planarConfiguration: 0,
        );
      }
      if (image.isJpegBaseline) {
        return _decodeJpeg(
          image,
          data,
          frame: frame,
          frameCount: count,
          invert: invert,
        );
      }
      throw UnsupportedFeatureException(
        'DICOM transfer syntax ${image.transferSyntaxUid}'
        '${image.transferSyntaxName == null ? '' : ' (${image.transferSyntaxName})'}'
        ' is not supported for pixel rendering',
      );
    }

    final data = image.pixelData;
    if (data == null) {
      throw const MalformedDocumentException('DICOM image has no pixel data');
    }
    final start = frame * image.frameLengthBytes;
    final end = start + image.frameLengthBytes;
    if (end > data.length) {
      throw const MalformedDocumentException(
        'DICOM pixel data is shorter than the declared frame size',
      );
    }
    return _decodeNative(
      image,
      Uint8List.sublistView(data, start, end),
      frame: frame,
      frameCount: count,
      windowCenter: windowCenter,
      windowWidth: windowWidth,
      invert: invert,
      endian: image.endian,
      planarConfiguration: image.planarConfiguration,
    );
  }

  DicomDecodedFrame _decodeNative(
    DicomImageData image,
    Uint8List raw, {
    required int frame,
    required int frameCount,
    required double? windowCenter,
    required double? windowWidth,
    required bool invert,
    required Endian endian,
    required int planarConfiguration,
  }) {
    _validate(image);
    final photometric = image.photometricInterpretation.toUpperCase();
    if (photometric == 'PALETTE COLOR') {
      throw const UnsupportedFeatureException(
        'DICOM PALETTE COLOR pixel data is not supported',
      );
    }
    if (photometric == 'MONOCHROME1' || photometric == 'MONOCHROME2') {
      return _decodeMonochrome(
        image,
        raw,
        frame: frame,
        frameCount: frameCount,
        windowCenter: windowCenter,
        windowWidth: windowWidth,
        invert: invert,
        endian: endian,
      );
    }
    if (photometric == 'RGB' ||
        photometric == 'YBR_FULL' ||
        photometric == 'YBR_FULL_422') {
      return _decodeColor(
        image,
        raw,
        frame: frame,
        frameCount: frameCount,
        invert: invert,
        endian: endian,
        planarConfiguration: planarConfiguration,
      );
    }
    throw UnsupportedFeatureException(
      'DICOM photometric interpretation ${image.photometricInterpretation} '
      'is not supported',
    );
  }

  void _validate(DicomImageData image) {
    if (image.rows <= 0 || image.columns <= 0) {
      throw const MalformedDocumentException(
        'DICOM image has invalid Rows or Columns',
      );
    }
    if (image.bitsAllocated != 8 && image.bitsAllocated != 16) {
      throw UnsupportedFeatureException(
        'DICOM Bits Allocated ${image.bitsAllocated} is not supported',
      );
    }
    if (image.bitsStored < 1 || image.bitsStored > image.bitsAllocated) {
      throw MalformedDocumentException(
        'DICOM Bits Stored ${image.bitsStored} is outside Bits Allocated '
        '${image.bitsAllocated}',
      );
    }
    if (image.highBit + 1 < image.bitsStored ||
        image.highBit >= image.bitsAllocated) {
      throw MalformedDocumentException(
        'DICOM High Bit ${image.highBit} is invalid for Bits Stored '
        '${image.bitsStored}',
      );
    }
    if (image.pixelRepresentation != 0 && image.pixelRepresentation != 1) {
      throw MalformedDocumentException(
        'DICOM Pixel Representation ${image.pixelRepresentation} is invalid',
      );
    }
    if (image.samplesPerPixel != 1 && image.samplesPerPixel != 3) {
      throw UnsupportedFeatureException(
        'DICOM Samples per Pixel ${image.samplesPerPixel} is not supported',
      );
    }
  }

  DicomDecodedFrame _decodeMonochrome(
    DicomImageData image,
    Uint8List raw, {
    required int frame,
    required int frameCount,
    required double? windowCenter,
    required double? windowWidth,
    required bool invert,
    required Endian endian,
  }) {
    final pixelCount = image.rows * image.columns;
    final bps = image.bytesPerSample;
    if (raw.length < pixelCount * bps) {
      throw const MalformedDocumentException(
        'DICOM pixel data is shorter than Rows x Columns',
      );
    }

    final values = Float64List(pixelCount);
    final byteData = ByteData.sublistView(raw);
    final shift = image.highBit + 1 - image.bitsStored;
    final mask = (1 << image.bitsStored) - 1;
    final signBit = 1 << (image.bitsStored - 1);
    final signModulus = 1 << image.bitsStored;

    for (var i = 0; i < pixelCount; i++) {
      final offset = i * bps;
      var stored = bps == 1 ? raw[offset] : byteData.getUint16(offset, endian);
      if (shift > 0) stored >>= shift;
      stored &= mask;
      if (image.pixelRepresentation == 1 && (stored & signBit) != 0) {
        stored -= signModulus;
      }
      values[i] = stored * image.rescaleSlope + image.rescaleIntercept;
    }

    final auto = _autoWindow(values);
    final center = windowCenter ?? image.windowCenter ?? auto.$1;
    var width = windowWidth ?? image.windowWidth ?? auto.$2;
    if (width <= 0) width = auto.$2;
    if (width <= 0) width = 1;
    final function = (image.voiLutFunction ?? 'LINEAR').toUpperCase();
    final monochrome1 =
        image.photometricInterpretation.toUpperCase() == 'MONOCHROME1';

    final rgba = Uint8List(pixelCount * 4);
    for (var i = 0; i < pixelCount; i++) {
      var gray = _windowValue(values[i], center, width, function);
      if (monochrome1) gray = 255 - gray;
      if (invert) gray = 255 - gray;
      final offset = i * 4;
      rgba[offset] = gray;
      rgba[offset + 1] = gray;
      rgba[offset + 2] = gray;
      rgba[offset + 3] = 255;
    }

    return _frame(
      image,
      rgba,
      frame: frame,
      frameCount: frameCount,
      windowCenter: center,
      windowWidth: width,
      inverted: monochrome1 != invert,
    );
  }

  DicomDecodedFrame _decodeColor(
    DicomImageData image,
    Uint8List raw, {
    required int frame,
    required int frameCount,
    required bool invert,
    required Endian endian,
    required int planarConfiguration,
  }) {
    if (image.samplesPerPixel != 3) {
      throw UnsupportedFeatureException(
        'DICOM color image has ${image.samplesPerPixel} samples per pixel',
      );
    }
    final photometric = image.photometricInterpretation.toUpperCase();
    final pixelCount = image.rows * image.columns;
    final bps = image.bytesPerSample;
    final byteData = ByteData.sublistView(raw);
    final shift = image.highBit + 1 - image.bitsStored;
    final mask = (1 << image.bitsStored) - 1;
    final maxValue = (1 << image.bitsStored) - 1;
    final scale = 255.0 / maxValue;
    final rgba = Uint8List(pixelCount * 4);

    int readStored(int offset) {
      var value = bps == 1 ? raw[offset] : byteData.getUint16(offset, endian);
      if (shift > 0) value >>= shift;
      return value & mask;
    }

    if (photometric == 'YBR_FULL_422') {
      if (bps != 1) {
        throw const UnsupportedFeatureException(
          '16-bit YBR_FULL_422 pixel data is not supported',
        );
      }
      final packedLength = ((pixelCount + 1) ~/ 2) * 4;
      if (raw.length < packedLength) {
        throw const MalformedDocumentException(
          'DICOM YBR_FULL_422 pixel data is truncated',
        );
      }
      for (var i = 0; i < pixelCount; i += 2) {
        final offset = i * 2;
        final y1 = _toByte(raw[offset] * scale);
        final y2 = _toByte(raw[offset + 1] * scale);
        final cb = _toByte(raw[offset + 2] * scale);
        final cr = _toByte(raw[offset + 3] * scale);
        _writeYbr(rgba, i, y1, cb, cr, invert);
        if (i + 1 < pixelCount) {
          _writeYbr(rgba, i + 1, y2, cb, cr, invert);
        }
      }
      return _frame(
        image,
        rgba,
        frame: frame,
        frameCount: frameCount,
        inverted: invert,
      );
    }

    if (planarConfiguration != 0 && planarConfiguration != 1) {
      throw UnsupportedFeatureException(
        'DICOM Planar Configuration $planarConfiguration is not supported',
      );
    }
    final planeStride = pixelCount * bps;
    final needed = planarConfiguration == 1
        ? planeStride * 3
        : pixelCount * bps * 3;
    if (raw.length < needed) {
      throw const MalformedDocumentException(
        'DICOM color pixel data is truncated',
      );
    }

    for (var i = 0; i < pixelCount; i++) {
      final int red;
      final int green;
      final int blue;
      if (planarConfiguration == 1) {
        red = readStored(i * bps);
        green = readStored(planeStride + i * bps);
        blue = readStored(planeStride * 2 + i * bps);
      } else {
        final offset = i * bps * 3;
        red = readStored(offset);
        green = readStored(offset + bps);
        blue = readStored(offset + bps * 2);
      }
      final r = _toByte(red * scale);
      final g = _toByte(green * scale);
      final b = _toByte(blue * scale);
      if (photometric == 'YBR_FULL') {
        _writeYbr(rgba, i, r, g, b, invert);
      } else {
        _writeRgb(rgba, i, r, g, b, invert);
      }
    }

    return _frame(
      image,
      rgba,
      frame: frame,
      frameCount: frameCount,
      inverted: invert,
    );
  }

  DicomDecodedFrame _decodeJpeg(
    DicomImageData image,
    Uint8List data, {
    required int frame,
    required int frameCount,
    required bool invert,
  }) {
    final decoded = img.decodeJpg(data);
    if (decoded == null) {
      throw const MalformedDocumentException(
        'DICOM JPEG pixel data could not be decoded',
      );
    }
    final rgba = decoded.getBytes(order: img.ChannelOrder.rgba);
    if (rgba.length != decoded.width * decoded.height * 4) {
      throw const MalformedDocumentException(
        'DICOM JPEG pixel data could not be expanded to RGBA',
      );
    }
    final monochrome1 =
        image.photometricInterpretation.toUpperCase() == 'MONOCHROME1';
    if (monochrome1 || invert) {
      for (var i = 0; i < rgba.length; i += 4) {
        rgba[i] = 255 - rgba[i];
        rgba[i + 1] = 255 - rgba[i + 1];
        rgba[i + 2] = 255 - rgba[i + 2];
      }
    }
    return _frame(
      image,
      rgba,
      frame: frame,
      frameCount: frameCount,
      width: decoded.width,
      height: decoded.height,
      inverted: monochrome1 != invert,
    );
  }

  DicomDecodedFrame _frame(
    DicomImageData image,
    Uint8List rgba, {
    required int frame,
    required int frameCount,
    int? width,
    int? height,
    double? windowCenter,
    double? windowWidth,
    required bool inverted,
  }) {
    var outputWidth = width ?? image.columns;
    var outputHeight = height ?? image.rows;
    var output = rgba;
    final cap = maxDimension;
    if (cap != null && cap > 0) {
      final longest = outputWidth > outputHeight ? outputWidth : outputHeight;
      if (longest > cap) {
        final scale = cap / longest;
        final resizedWidth = math.max(1, (outputWidth * scale).round());
        final resizedHeight = math.max(1, (outputHeight * scale).round());
        output = _resizeRgba(
          output,
          outputWidth,
          outputHeight,
          resizedWidth,
          resizedHeight,
        );
        outputWidth = resizedWidth;
        outputHeight = resizedHeight;
      }
    }
    return DicomDecodedFrame(
      width: outputWidth,
      height: outputHeight,
      rgba: output,
      frameIndex: frame,
      frameCount: frameCount,
      photometricInterpretation: image.photometricInterpretation,
      windowCenter: windowCenter,
      windowWidth: windowWidth,
      inverted: inverted,
    );
  }

  Uint8List _decodeRleFrame(DicomImageData image, Uint8List frame) {
    if (frame.length < 64) {
      throw const MalformedDocumentException('DICOM RLE frame is too short');
    }
    final photometric = image.photometricInterpretation.toUpperCase();
    if (photometric == 'YBR_FULL_422') {
      throw const UnsupportedFeatureException(
        'RLE-compressed YBR_FULL_422 pixel data is not supported',
      );
    }
    final bps = image.bytesPerSample;
    final segmentCount = bps * image.samplesPerPixel;
    if (segmentCount > 15) {
      throw UnsupportedFeatureException(
        'DICOM RLE frame declares $segmentCount segments',
      );
    }
    final header = ByteData.sublistView(frame);
    final offsets = List<int>.generate(
      16,
      (i) => header.getUint32(i * 4, Endian.little),
    );
    final pixelCount = image.rows * image.columns;
    final segments = <Uint8List>[];
    for (var i = 0; i < segmentCount; i++) {
      final start = offsets[i];
      final end = i + 1 < segmentCount ? offsets[i + 1] : frame.length;
      if (start < 64 || start >= end || end > frame.length) {
        throw const MalformedDocumentException(
          'DICOM RLE segment offsets are invalid',
        );
      }
      segments.add(
        _unpackBits(Uint8List.sublistView(frame, start, end), pixelCount),
      );
    }

    final out = Uint8List(pixelCount * image.samplesPerPixel * bps);
    var segment = 0;
    for (var sample = 0; sample < image.samplesPerPixel; sample++) {
      for (var byteIndex = bps - 1; byteIndex >= 0; byteIndex--) {
        final data = segments[segment++];
        for (var i = 0; i < pixelCount; i++) {
          final pixel = i * image.samplesPerPixel + sample;
          out[pixel * bps + byteIndex] = data[i];
        }
      }
    }
    return out;
  }

  Uint8List _unpackBits(Uint8List input, int expected) {
    final output = Uint8List(expected);
    var inputIndex = 0;
    var outputIndex = 0;
    while (inputIndex < input.length && outputIndex < expected) {
      final control = input[inputIndex++].toSigned(8);
      if (control >= 0) {
        final count = control + 1;
        for (
          var i = 0;
          i < count && inputIndex < input.length && outputIndex < expected;
          i++
        ) {
          output[outputIndex++] = input[inputIndex++];
        }
      } else if (control != -128) {
        if (inputIndex >= input.length) break;
        final value = input[inputIndex++];
        final count = 1 - control;
        for (var i = 0; i < count && outputIndex < expected; i++) {
          output[outputIndex++] = value;
        }
      }
    }
    if (outputIndex < expected) {
      throw MalformedDocumentException(
        'DICOM RLE segment decoded $outputIndex of $expected bytes',
      );
    }
    return output;
  }

  (double, double) _autoWindow(Float64List values) {
    var min = values[0];
    var max = values[0];
    for (final value in values) {
      if (value < min) min = value;
      if (value > max) max = value;
    }
    if (max <= min) return (min, 1);
    return ((min + max) / 2, max - min);
  }

  int _windowValue(double value, double center, double width, String function) {
    switch (function) {
      case 'LINEAR_EXACT':
        return _toByte(((value - center) / width + 0.5) * 255);
      case 'SIGMOID':
        return _toByte(255 / (1 + math.exp(-4 * (value - center) / width)));
      default:
        if (width <= 1) return value >= center ? 255 : 0;
        final lower = center - 0.5 - (width - 1) / 2;
        final upper = center - 0.5 + (width - 1) / 2;
        if (value <= lower) return 0;
        if (value > upper) return 255;
        return _toByte(((value - (center - 0.5)) / (width - 1) + 0.5) * 255);
    }
  }

  void _writeYbr(
    Uint8List rgba,
    int pixel,
    int y,
    int cb,
    int cr,
    bool invert,
  ) {
    final red = _toByte(y + 1.402 * (cr - 128));
    final green = _toByte(y - 0.344136 * (cb - 128) - 0.714136 * (cr - 128));
    final blue = _toByte(y + 1.772 * (cb - 128));
    _writeRgb(rgba, pixel, red, green, blue, invert);
  }

  void _writeRgb(
    Uint8List rgba,
    int pixel,
    int red,
    int green,
    int blue,
    bool invert,
  ) {
    final offset = pixel * 4;
    rgba[offset] = invert ? 255 - red : red;
    rgba[offset + 1] = invert ? 255 - green : green;
    rgba[offset + 2] = invert ? 255 - blue : blue;
    rgba[offset + 3] = 255;
  }

  Uint8List _resizeRgba(
    Uint8List source,
    int width,
    int height,
    int targetWidth,
    int targetHeight,
  ) {
    final output = Uint8List(targetWidth * targetHeight * 4);
    for (var y = 0; y < targetHeight; y++) {
      final sourceY = y * height ~/ targetHeight;
      for (var x = 0; x < targetWidth; x++) {
        final sourceX = x * width ~/ targetWidth;
        final sourceOffset = (sourceY * width + sourceX) * 4;
        final targetOffset = (y * targetWidth + x) * 4;
        output[targetOffset] = source[sourceOffset];
        output[targetOffset + 1] = source[sourceOffset + 1];
        output[targetOffset + 2] = source[sourceOffset + 2];
        output[targetOffset + 3] = source[sourceOffset + 3];
      }
    }
    return output;
  }

  int _toByte(num value) {
    if (value <= 0) return 0;
    if (value >= 255) return 255;
    return value.round();
  }
}
