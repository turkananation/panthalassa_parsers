import '../core/document_format.dart';
import 'document_ir.dart';

/// Common renderer contract. Adapters for Flutter, Jaspr, or other UI systems
/// should consume [DocumentIr] through this kind of visitor boundary.
abstract interface class DocumentRenderer<T> {
  T render(
    DocumentIr document, {
    RenderOptions options = const RenderOptions(),
  });
}

/// Options shared by semantic renderers.
final class RenderOptions {
  const RenderOptions({this.includeMetadata = true, this.headingBaseLevel = 1});

  final bool includeMetadata;
  final int headingBaseLevel;
}

/// Plain-text renderer for CLI, indexing, and lowest-common-denominator UI.
final class TextDocumentRenderer implements DocumentRenderer<String> {
  const TextDocumentRenderer();

  @override
  String render(
    DocumentIr document, {
    RenderOptions options = const RenderOptions(),
  }) {
    final out = StringBuffer();
    for (final block in document.body) {
      if (!options.includeMetadata &&
          block is FieldGroupBlock &&
          block.name == 'Metadata') {
        continue;
      }
      _writeBlock(out, block, indent: 0);
    }
    return out.toString().trimRight();
  }

  void _writeBlock(StringBuffer out, DocBlock block, {required int indent}) {
    final pad = ' ' * indent;
    switch (block) {
      case HeadingBlock():
        out.writeln('$pad${_inlineText(block.text)}');
      case ParagraphBlock():
        out.writeln('$pad${_inlineText(block.text)}');
        out.writeln();
      case KeyValueBlock():
        out.writeln('$pad${block.key}: ${_inlineText(block.value)}');
      case FieldGroupBlock():
        out.writeln('$pad${block.name}');
        for (final child in block.children) {
          _writeBlock(out, child, indent: indent + 2);
        }
        out.writeln();
      case ListBlock():
        for (var i = 0; i < block.items.length; i++) {
          out.writeln('$pad${block.ordered ? '${i + 1}.' : '-'}');
          for (final child in block.items[i]) {
            _writeBlock(out, child, indent: indent + 2);
          }
        }
      case TableBlock():
        for (final row in block.rows) {
          out.writeln(row.map((c) => _blocksText(c.blocks)).join('\t'));
        }
      case CodeBlock():
        out.writeln('$pad${block.text}');
      case FigureBlock():
        out.writeln(
          '$pad[figure ${block.media.id}] ${_inlineText(block.caption)}',
        );
      case RawVisualBlock():
        out.writeln(
          '$pad[visual ${block.geometry.width}x${block.geometry.height}]',
        );
    }
  }

  String _blocksText(List<DocBlock> blocks) {
    final out = StringBuffer();
    for (final block in blocks) {
      _writeBlock(out, block, indent: 0);
    }
    return out.toString().trim();
  }
}

/// Markdown renderer for RAG, review, and lightweight export.
final class MarkdownDocumentRenderer implements DocumentRenderer<String> {
  const MarkdownDocumentRenderer();

  @override
  String render(
    DocumentIr document, {
    RenderOptions options = const RenderOptions(),
  }) {
    final out = StringBuffer();
    for (final block in document.body) {
      if (!options.includeMetadata &&
          block is FieldGroupBlock &&
          block.name == 'Metadata') {
        continue;
      }
      _writeBlock(out, block, options);
    }
    return out.toString().trimRight();
  }

  void _writeBlock(StringBuffer out, DocBlock block, RenderOptions options) {
    switch (block) {
      case HeadingBlock():
        final level = (block.level + options.headingBaseLevel - 1).clamp(1, 6);
        out.writeln('${'#' * level} ${_inlineText(block.text)}\n');
      case ParagraphBlock():
        out.writeln('${_inlineText(block.text)}\n');
      case KeyValueBlock():
        out.writeln(
          '- **${_escapeMarkdown(block.key)}:** ${_inlineText(block.value)}',
        );
      case FieldGroupBlock():
        out.writeln('## ${_escapeMarkdown(block.name)}');
        for (final child in block.children) {
          _writeBlock(out, child, options);
        }
        out.writeln();
      case ListBlock():
        for (var i = 0; i < block.items.length; i++) {
          final marker = block.ordered ? '${i + 1}.' : '-';
          out.writeln(marker);
          for (final child in block.items[i]) {
            _writeBlock(out, child, options);
          }
        }
      case TableBlock():
        for (final row in block.rows) {
          out.writeln(
            '| ${row.map((c) => _blocksText(c.blocks)).join(' | ')} |',
          );
        }
        out.writeln();
      case CodeBlock():
        out.writeln('```${block.language ?? ''}\n${block.text}\n```\n');
      case FigureBlock():
        out.writeln('![${_inlineText(block.caption)}](${block.media.id})\n');
      case RawVisualBlock():
        out.writeln(
          '> Visual block ${block.geometry.width}x${block.geometry.height}\n',
        );
    }
  }

  String _blocksText(List<DocBlock> blocks) =>
      const TextDocumentRenderer().render(
        DocumentIr(
          sourceFormat: DocumentFormat.unknown,
          metadata: const {},
          body: blocks,
        ),
      );
}

/// Escaped HTML renderer suitable for server-side UI adapters, including Jaspr.
final class HtmlDocumentRenderer implements DocumentRenderer<String> {
  const HtmlDocumentRenderer();

  @override
  String render(
    DocumentIr document, {
    RenderOptions options = const RenderOptions(),
  }) {
    final out = StringBuffer()
      ..write('<article class="panthalassa-document" data-format="')
      ..write(_escapeHtml(document.sourceFormat.name))
      ..write('">');
    for (final block in document.body) {
      if (!options.includeMetadata &&
          block is FieldGroupBlock &&
          block.name == 'Metadata') {
        continue;
      }
      _writeBlock(out, block, options);
    }
    out.write('</article>');
    return out.toString();
  }

  void _writeBlock(StringBuffer out, DocBlock block, RenderOptions options) {
    switch (block) {
      case HeadingBlock():
        final level = (block.level + options.headingBaseLevel - 1).clamp(1, 6);
        out
          ..write('<h$level>')
          ..write(_inlineHtml(block.text))
          ..write('</h$level>');
      case ParagraphBlock():
        out
          ..write('<p>')
          ..write(_inlineHtml(block.text))
          ..write('</p>');
      case KeyValueBlock():
        out
          ..write('<dl><dt>')
          ..write(_escapeHtml(block.key))
          ..write('</dt><dd>')
          ..write(_inlineHtml(block.value))
          ..write('</dd></dl>');
      case FieldGroupBlock():
        out
          ..write('<section><h2>')
          ..write(_escapeHtml(block.name))
          ..write('</h2>');
        for (final child in block.children) {
          _writeBlock(out, child, options);
        }
        out.write('</section>');
      case ListBlock():
        out.write(block.ordered ? '<ol>' : '<ul>');
        for (final item in block.items) {
          out.write('<li>');
          for (final child in item) {
            _writeBlock(out, child, options);
          }
          out.write('</li>');
        }
        out.write(block.ordered ? '</ol>' : '</ul>');
      case TableBlock():
        out.write('<table><tbody>');
        for (final row in block.rows) {
          out.write('<tr>');
          for (final cell in row) {
            out.write(cell.header ? '<th>' : '<td>');
            for (final child in cell.blocks) {
              _writeBlock(out, child, options);
            }
            out.write(cell.header ? '</th>' : '</td>');
          }
          out.write('</tr>');
        }
        out.write('</tbody></table>');
      case CodeBlock():
        out
          ..write('<pre><code>')
          ..write(_escapeHtml(block.text))
          ..write('</code></pre>');
      case FigureBlock():
        out
          ..write('<figure data-media-id="')
          ..write(_escapeHtml(block.media.id))
          ..write('"><figcaption>')
          ..write(_inlineHtml(block.caption))
          ..write('</figcaption></figure>');
      case RawVisualBlock():
        out
          ..write('<div class="panthalassa-visual" data-width="')
          ..write(block.geometry.width)
          ..write('" data-height="')
          ..write(block.geometry.height)
          ..write('">')
          ..write(_escapeHtml(block.description ?? 'Visual block'))
          ..write('</div>');
    }
  }
}

String _inlineText(List<DocInline> inlines) => inlines.map((inline) {
  return switch (inline) {
    TextRun() => inline.text,
    LinkSpan() => _inlineText(inline.text),
    ReferenceSpan() => inline.target,
  };
}).join();

String _inlineHtml(List<DocInline> inlines) => inlines.map((inline) {
  return switch (inline) {
    TextRun() => _markHtml(_escapeHtml(inline.text), inline.marks),
    LinkSpan() =>
      '<a href="${_escapeHtml(inline.href)}">${_inlineHtml(inline.text)}</a>',
    ReferenceSpan() =>
      '<a href="#${_escapeHtml(inline.target)}">'
          '${_escapeHtml(inline.target)}</a>',
  };
}).join();

String _markHtml(String text, Set<TextMark> marks) {
  var out = text;
  if (marks.contains(TextMark.code)) out = '<code>$out</code>';
  if (marks.contains(TextMark.bold)) out = '<strong>$out</strong>';
  if (marks.contains(TextMark.italic)) out = '<em>$out</em>';
  if (marks.contains(TextMark.underline)) out = '<u>$out</u>';
  return out;
}

String _escapeHtml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

String _escapeMarkdown(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll('*', r'\*');
