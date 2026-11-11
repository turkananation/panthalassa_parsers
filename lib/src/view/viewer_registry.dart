import '../core/parse_result.dart';
import 'csv_view_builder.dart';
import 'dicom_view_builder.dart';
import 'document_view_builder.dart';
import 'viewer_document.dart';

/// Selects the first matching [ViewBuilder], falling back to a semantic HTML
/// document view. Add new formats here rather than branching in the CLI.
final class ViewerRegistry {
  ViewerRegistry({required List<ViewBuilder> builders, required this.fallback})
    : _builders = List.unmodifiable(builders);

  /// Registry used by `panthalassa view`.
  factory ViewerRegistry.standard() => ViewerRegistry(
    builders: const [CsvViewBuilder(), DicomViewBuilder()],
    fallback: const DocumentViewBuilder(),
  );

  final List<ViewBuilder> _builders;
  final ViewBuilder fallback;

  ViewBuilder builderFor(ParseResult result) {
    for (final builder in _builders) {
      if (builder.supports(result)) return builder;
    }
    return fallback;
  }

  ViewerDocument build(ViewerRequest request) =>
      builderFor(request.result).build(request);
}
