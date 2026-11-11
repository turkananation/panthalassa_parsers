import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'document_format.dart';
import 'document_parser.dart';
import 'structured_artifacts.dart';

/// Result of detection with confidence and evidence.
@immutable
final class DetectionResult {
  const DetectionResult({
    required this.format,
    required this.confidence,
    this.evidence = const [],
  });

  final DocumentFormat format;

  /// 0.0–1.0. `1.0` means strong magic/grammar evidence; hint-only matches use
  /// a high but slightly lower score and carry `hint-match` evidence so callers
  /// can still distinguish them from content-only recognition.
  final double confidence;

  final List<String> evidence;

  bool get isConfident => confidence >= 0.8;

  Map<String, Object?> toJson() => {
    'format': format.name,
    'confidence': confidence,
    'evidence': evidence,
  };
}

/// Resolves a [DocumentFormat] from raw bytes.
///
/// Order is load-bearing: parsers with strong binary magic numbers are
/// consulted before text heuristics, so that, for example, a PDF whose body
/// happens to contain XML, or a DICOM file with ASCII in its dataset, is never
/// misclassified by a permissive text sniffer. The registry constructs the
/// detector with parsers already in that priority order.
final class FormatDetector {
  const FormatDetector(this._ordered);

  final List<DocumentParser> _ordered;

  /// Returns the format of the first parser that recognises [bytes], or
  /// [DocumentFormat.unknown] if none do.
  DocumentFormat detect(Uint8List bytes) => detectDetailed(bytes).format;

  /// Hint-aware detection.
  DocumentFormat detectWithHints(Uint8List bytes, DocumentHints hints) =>
      detectDetailed(bytes, hints: hints).format;

  /// Returns the best match plus confidence and evidence.
  ///
  /// Parsers earlier in the registry are considered stronger evidence. The
  /// first recogniser wins; hint-aware recognisers (CSV, Markdown) only fire
  /// when their hint requirement is satisfied.
  DetectionResult detectDetailed(Uint8List bytes, {DocumentHints? hints}) {
    final h = hints ?? const DocumentHints();
    final hasHints = h.filename != null || h.mimeType != null;
    for (var i = 0; i < _ordered.length; i++) {
      final parser = _ordered[i];
      if (!parserMatches(parser, bytes, h)) continue;
      // Markdown/CSV deliberately decline content-only detection. When a hint
      // is the only reason the parser matched, report that as strong evidence
      // rather than the much lower positional heuristic score.
      final contentMatch = parser.canParse(bytes);
      final hintOnly = hasHints && !contentMatch;
      // Binary magic at the front of the registry is near-certain. Later
      // heuristic parsers are less certain and decline proportionally.
      final confidence = hintOnly
          ? 0.9
          : i < 4
          ? 1.0
          : (0.95 - (i * 0.02)).clamp(0.55, 0.95);
      return DetectionResult(
        format: parser.format,
        confidence: confidence,
        evidence: [
          'parser:${parser.runtimeType}',
          if (hintOnly) 'hint-match',
          if (h.filename != null) 'filename:${h.filename}',
          if (h.mimeType != null) 'mimeType:${h.mimeType}',
        ],
      );
    }
    return const DetectionResult(
      format: DocumentFormat.unknown,
      confidence: 0,
      evidence: ['no parser matched'],
    );
  }
}
