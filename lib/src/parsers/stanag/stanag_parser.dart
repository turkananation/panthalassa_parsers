import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../core/content_hasher.dart';
import '../../core/document_format.dart';
import '../../core/document_parser.dart';
import '../../core/parse_exception.dart';
import '../../core/parse_result.dart';
import 'stanag_4607_gmti.dart';
import 'stanag_4609_motion_imagery.dart';
import 'stanag_xml.dart';

/// Dispatching parser for the STANAG family.
///
/// "STANAG" is not one format but a family of NATO standardisation agreements,
/// several of which define machine-readable document/data interchange formats.
/// This parser holds an ordered list of [StanagSubParser]s — one per supported
/// standard — and delegates to the first that recognises the input. The detected
/// standard is reported in `metadata['standard']`. Adding a new STANAG standard
/// is a matter of implementing [StanagSubParser] and registering it here; no
/// change to [DocumentFormat] or the top-level registry is required.
///
/// Note: STANAG 4545 (NSIF) is the NATO profile of NITF and is already handled
/// by the NITF parser (which recognises the `NSIF` file header), so it is not
/// duplicated here.
final class StanagParser implements DocumentParser {
  const StanagParser([this._subParsers = _defaults]);

  static const List<StanagSubParser> _defaults = [
    Stanag4607GmtiParser(),          // binary GMTI packet
    Stanag4609MotionImageryParser(), // MPEG-2 TS / MISB KLV
    Stanag4676TrackingParser(),      // NITS tracking (XML/GML)
    Stanag4774LabelParser(),         // confidentiality label (XML)
    Stanag4778BindingParser(),       // metadata binding (XML)
  ];

  final List<StanagSubParser> _subParsers;

  /// The supported standards, in detection-priority order.
  List<String> get supportedStandards =>
      _subParsers.map((s) => s.standard).toList(growable: false);

  @override
  DocumentFormat get format => DocumentFormat.stanag;

  @override
  bool canParse(Uint8List bytes) {
    for (final sub in _subParsers) {
      if (sub.matches(bytes)) return true;
    }
    return false;
  }

  @override
  ParseResult parse(Uint8List bytes, {required ContentHasher hasher}) {
    for (final sub in _subParsers) {
      if (sub.matches(bytes)) {
        final parsed = sub.parse(bytes);
        return ParseResult(
          documentId: hasher.idFor(bytes),
          format: format,
          byteLength: bytes.length,
          metadata: {'standard': sub.standard, ...parsed.metadata},
          text: parsed.text,
          warnings: parsed.warnings,
        );
      }
    }
    throw const UnsupportedFormatException(
      'input did not match any supported STANAG standard',
    );
  }
}

/// Contract for a parser of a single STANAG standard within the family.
///
/// Implementations must be stateless and isolate-safe. [matches] must be cheap
/// and never throw (return `false` on any doubt). [parse] throws a
/// [ParseException] subtype on failure and must wrap third-party errors.
abstract interface class StanagSubParser {
  /// Canonical standard label, e.g. `'STANAG 4607'`.
  String get standard;

  /// Fast recognition check for this standard.
  bool matches(Uint8List bytes);

  /// Parses [bytes]; the dispatcher supplies the content id and overall format.
  StanagParse parse(Uint8List bytes);
}

/// The standard-specific portion of a STANAG parse result.
@immutable
final class StanagParse {
  const StanagParse({
    required this.metadata,
    this.text,
    this.warnings = const [],
  });

  final Map<String, Object?> metadata;
  final String? text;
  final List<ParseWarning> warnings;
}
