import 'package:meta/meta.dart';

import '../core/document_format.dart';
import '../core/parse_result.dart';
import 'visual_primitives.dart';

/// Base class for the Panthalassa Document Intermediate Representation.
sealed class DocNode {
  const DocNode();
}

/// Format-agnostic semantic representation consumed by renderers and adapters.
@immutable
final class DocumentIr extends DocNode {
  const DocumentIr({
    required this.sourceFormat,
    required this.metadata,
    required this.body,
    this.attachments = const [],
    this.signatures = const [],
    this.contentId,
  });

  /// Builds a conservative semantic document from the current lossy parse API.
  factory DocumentIr.fromParseResult(ParseResult result) {
    final body = <DocBlock>[];
    if (result.metadata.isNotEmpty) {
      body.add(
        FieldGroupBlock(
          name: 'Metadata',
          children: [
            for (final entry in _semanticMetadata(result.metadata))
              KeyValueBlock(
                key: entry.key,
                value: [TextRun(_metadataValue(entry.value))],
              ),
          ],
        ),
      );
    }
    body.addAll(_visualBlocks(result));
    final text = result.text?.trim();
    if (text != null && text.isNotEmpty) {
      for (final paragraph in text.split(RegExp(r'\n{2,}'))) {
        final trimmed = paragraph.trim();
        if (trimmed.isNotEmpty) {
          body.add(ParagraphBlock([TextRun(trimmed)]));
        }
      }
    }
    return DocumentIr(
      sourceFormat: result.format,
      metadata: result.metadata,
      body: body,
      attachments: _attachments(result.metadata),
      contentId: result.documentId,
    );
  }

  final DocumentFormat sourceFormat;
  final Map<String, Object?> metadata;
  final List<DocBlock> body;
  final List<Attachment> attachments;
  final List<SignatureInfo> signatures;
  final String? contentId;
}

sealed class DocBlock extends DocNode {
  const DocBlock();
}

final class HeadingBlock extends DocBlock {
  const HeadingBlock({required this.level, required this.text});
  final int level;
  final List<DocInline> text;
}

final class ParagraphBlock extends DocBlock {
  const ParagraphBlock(this.text);
  final List<DocInline> text;
}

final class TableBlock extends DocBlock {
  const TableBlock(this.rows);
  final List<List<TableCell>> rows;
}

final class TableCell extends DocNode {
  const TableCell(this.blocks, {this.header = false});
  final List<DocBlock> blocks;
  final bool header;
}

final class ListBlock extends DocBlock {
  const ListBlock({required this.ordered, required this.items});
  final bool ordered;
  final List<List<DocBlock>> items;
}

final class KeyValueBlock extends DocBlock {
  const KeyValueBlock({required this.key, required this.value});
  final String key;
  final List<DocInline> value;
}

final class FieldGroupBlock extends DocBlock {
  const FieldGroupBlock({required this.name, required this.children});
  final String name;
  final List<DocBlock> children;
}

final class CodeBlock extends DocBlock {
  const CodeBlock({this.language, required this.text});
  final String? language;
  final String text;
}

final class FigureBlock extends DocBlock {
  const FigureBlock({required this.media, this.caption = const []});
  final MediaRef media;
  final List<DocInline> caption;
}

final class RawVisualBlock extends DocBlock {
  const RawVisualBlock({
    required this.geometry,
    this.commands = const [],
    this.description,
    this.semanticText,
    this.sourceId,
  });

  final PageGeometry geometry;
  final List<VisualCommand> commands;
  final String? description;
  final String? semanticText;
  final String? sourceId;
}

sealed class DocInline extends DocNode {
  const DocInline();
}

final class TextRun extends DocInline {
  const TextRun(this.text, {this.marks = const {}});
  final String text;
  final Set<TextMark> marks;
}

final class LinkSpan extends DocInline {
  const LinkSpan({required this.href, required this.text});
  final String href;
  final List<DocInline> text;
}

final class ReferenceSpan extends DocInline {
  const ReferenceSpan(this.target);
  final String target;
}

enum TextMark { bold, italic, underline, code }

@immutable
final class Attachment {
  const Attachment({this.name, this.mediaType, this.size});
  final String? name;
  final String? mediaType;
  final int? size;
}

@immutable
final class SignatureInfo {
  const SignatureInfo({
    required this.role,
    required this.signer,
    this.verified,
  });
  final String role;
  final String signer;
  final bool? verified;
}

@immutable
final class MediaRef {
  const MediaRef({required this.id, this.mediaType, this.description});
  final String id;
  final String? mediaType;
  final String? description;
}

String _metadataValue(Object? value) {
  if (value == null) return '';
  if (value is String || value is num || value is bool) return '$value';
  if (value is Iterable) return value.map(_metadataValue).join(', ');
  if (value is Map) {
    return value.entries
        .map((e) => '${e.key}: ${_metadataValue(e.value)}')
        .join('; ');
  }
  return '$value';
}

Iterable<MapEntry<String, Object?>> _semanticMetadata(
  Map<String, Object?> metadata,
) => metadata.entries.where((entry) => entry.key != 'visualPages');

List<RawVisualBlock> _visualBlocks(ParseResult result) {
  final blocks = <RawVisualBlock>[];
  final visualPages = result.metadata['visualPages'];
  if (visualPages is Iterable) {
    for (final page in visualPages) {
      final block = _visualBlockFromMap(page);
      if (block != null) blocks.add(block);
    }
  }

  if (blocks.isNotEmpty) return blocks;

  if (result.format == DocumentFormat.nitf) {
    final images = result.metadata['images'];
    if (images is Iterable) {
      for (final image in images) {
        final map = _objectMap(image);
        if (map == null) continue;
        final columns = _doubleValue(map['columns']);
        final rows = _doubleValue(map['rows']);
        if (columns == null || rows == null || columns <= 0 || rows <= 0) {
          continue;
        }
        final imageId = '${map['imageId'] ?? 'nitf-image-${blocks.length}'}';
        blocks.add(
          RawVisualBlock(
            geometry: PageGeometry(
              width: columns,
              height: rows,
              pageIndex: blocks.length,
              coordinateSpace: VisualCoordinateSpace.screen,
            ),
            commands: [
              VisualImageCommand(
                sourceId: imageId,
                x: 0,
                y: 0,
                width: columns,
                height: rows,
                mediaType: 'image/nitf',
                description: '${map['title'] ?? imageId}',
              ),
            ],
            description: 'NITF image $imageId',
            sourceId: imageId,
          ),
        );
      }
    }
  }

  if (result.format == DocumentFormat.dicom) {
    final columns = _doubleValue(result.metadata['columns']);
    final rows = _doubleValue(result.metadata['rows']);
    if (columns != null && rows != null && columns > 0 && rows > 0) {
      final sourceId =
          '${result.metadata['sopInstanceUid'] ?? 'dicom-frame-0'}';
      blocks.add(
        RawVisualBlock(
          geometry: PageGeometry(
            width: columns,
            height: rows,
            pageIndex: 0,
            coordinateSpace: VisualCoordinateSpace.screen,
          ),
          commands: [
            VisualImageCommand(
              sourceId: sourceId,
              x: 0,
              y: 0,
              width: columns,
              height: rows,
              mediaType: 'application/dicom',
              description: 'DICOM frame',
            ),
          ],
          description: 'DICOM frame',
          sourceId: sourceId,
        ),
      );
    }
  }

  return blocks;
}

RawVisualBlock? _visualBlockFromMap(Object? value) {
  final map = _objectMap(value);
  if (map == null) return null;
  final width = _doubleValue(map['width']);
  final height = _doubleValue(map['height']);
  if (width == null || height == null || width <= 0 || height <= 0) {
    return null;
  }
  final pageIndex = _intValue(map['pageIndex']);
  final commands = <VisualCommand>[];
  final rawCommands = map['commands'];
  if (rawCommands is Iterable) {
    for (final raw in rawCommands) {
      final command = _visualCommand(raw);
      if (command != null) commands.add(command);
    }
  }
  return RawVisualBlock(
    geometry: PageGeometry(
      width: width,
      height: height,
      pageIndex: pageIndex,
      x: _doubleValue(map['x']) ?? 0,
      y: _doubleValue(map['y']) ?? 0,
      coordinateSpace: _coordinateSpace(map['coordinateSpace']),
    ),
    commands: commands,
    description: map['description'] as String?,
    semanticText: map['semanticText'] as String?,
    sourceId: map['sourceId'] as String?,
  );
}

VisualCommand? _visualCommand(Object? value) {
  final map = _objectMap(value);
  if (map == null) return null;
  final type = map['type'];
  switch (type) {
    case 'text':
      final text = map['text'];
      final x = _doubleValue(map['x']);
      final y = _doubleValue(map['y']);
      final fontSize = _doubleValue(map['fontSize']);
      if (text is! String || x == null || y == null || fontSize == null) {
        return null;
      }
      return VisualTextCommand(
        text: text,
        x: x,
        y: y,
        fontSize: fontSize,
        fontName: map['fontName'] as String?,
        fill: _colorValue(map['fill']) ?? const VisualColor.black(),
      );
    case 'rect':
      final x = _doubleValue(map['x']);
      final y = _doubleValue(map['y']);
      final width = _doubleValue(map['width']);
      final height = _doubleValue(map['height']);
      if (x == null || y == null || width == null || height == null) {
        return null;
      }
      return VisualRectCommand(
        x: x,
        y: y,
        width: width,
        height: height,
        fill: _colorValue(map['fill']),
        stroke: _colorValue(map['stroke']),
        strokeWidth: _doubleValue(map['strokeWidth']) ?? 1,
      );
    case 'image':
      final sourceId = map['sourceId'];
      final x = _doubleValue(map['x']);
      final y = _doubleValue(map['y']);
      final width = _doubleValue(map['width']);
      final height = _doubleValue(map['height']);
      if (sourceId is! String ||
          x == null ||
          y == null ||
          width == null ||
          height == null) {
        return null;
      }
      return VisualImageCommand(
        sourceId: sourceId,
        x: x,
        y: y,
        width: width,
        height: height,
        mediaType: map['mediaType'] as String?,
        description: map['description'] as String?,
      );
    case 'unsupported':
      final operatorName = map['operator'];
      if (operatorName is! String) return null;
      return VisualUnsupportedCommand(
        operatorName: operatorName,
        detail: map['detail'] as String?,
      );
  }
  return null;
}

Map<Object?, Object?>? _objectMap(Object? value) {
  if (value is Map<Object?, Object?>) return value;
  if (value is Map) return value.cast<Object?, Object?>();
  return null;
}

double? _doubleValue(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

int? _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

VisualColor? _colorValue(Object? value) {
  if (value is String && RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(value)) {
    return VisualColor(
      r: int.parse(value.substring(1, 3), radix: 16),
      g: int.parse(value.substring(3, 5), radix: 16),
      b: int.parse(value.substring(5, 7), radix: 16),
    );
  }
  if (value is Iterable) {
    final rgb = value.whereType<num>().map((v) => v.toInt()).toList();
    if (rgb.length >= 3) {
      return VisualColor(r: rgb[0], g: rgb[1], b: rgb[2]);
    }
  }
  return null;
}

VisualCoordinateSpace _coordinateSpace(Object? value) => value == 'screen'
    ? VisualCoordinateSpace.screen
    : VisualCoordinateSpace.pdfUserSpace;

List<Attachment> _attachments(Map<String, Object?> metadata) {
  final files = metadata['embeddedFiles'];
  if (files is! Iterable) return const [];
  return [
    for (final file in files)
      if (file is Map)
        Attachment(
          name: file['name'] as String?,
          size: file['size'] is int ? file['size'] as int : null,
        ),
  ];
}
