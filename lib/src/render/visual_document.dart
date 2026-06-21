import 'document_ir.dart';
import 'visual_primitives.dart';

/// Projects the semantic DIR into the faithful visual display-list model.
extension DocumentIrVisualProjection on DocumentIr {
  VisualDocument toVisualDocument() {
    final pages = <VisualPage>[];
    for (final block in body) {
      if (block is RawVisualBlock) {
        pages.add(
          VisualPage(
            geometry: block.geometry,
            commands: block.commands,
            description: block.description,
            semanticText: block.semanticText,
            sourceId: block.sourceId,
          ),
        );
      }
    }
    return VisualDocument(
      sourceFormat: sourceFormat,
      contentId: contentId,
      metadata: metadata,
      pages: pages,
    );
  }
}
