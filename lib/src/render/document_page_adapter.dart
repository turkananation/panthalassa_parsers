import 'dart:convert';

import 'document_diff.dart';
import 'document_ir.dart';
import 'document_renderer.dart';
import 'visual_primitives.dart';
import 'visual_renderer.dart';

/// Renders a [DocumentIr] (semantic content) together with an optional
/// [VisualDocument] (faithful display-list pages) into one self-contained HTML
/// page.
///
/// The output is framework-free and web-safe: all CSS and JavaScript are
/// embedded inline, so the page opens from `file://` without a server. It
/// includes responsive light/dark/system themes, a persistent collapsible
/// outline, live find-in-page across semantic and visual content, language-aware
/// code highlighting, a zoomable visual-page lightbox with SVG/PNG export,
/// collapsible sections, optional attachment previews, and an optional
/// side-by-side version diff.
final class DocumentPageAdapter {
  const DocumentPageAdapter();

  /// Attachments larger than this are never inlined as data URIs.
  static const int maxInlineAttachmentBytes = 8 * 1024 * 1024;

  /// Maximum attachment text preview length.
  static const int maxAttachmentTextChars = 200 * 1024;

  static const Set<String> _imageTypes = {
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
    'image/avif',
    'image/svg+xml',
  };

  /// Renders [ir] with an optional [visual] projection into a single HTML
  /// document.
  ///
  /// [options] control semantic rendering. [compareWith] adds a side-by-side
  /// comparison against an earlier version of the same document.
  String render({
    required DocumentIr ir,
    VisualDocument? visual,
    RenderOptions options = const RenderOptions(),
    DocumentIr? compareWith,
    String compareLabel = 'Previous version',
  }) {
    final semantic = const HtmlDocumentRenderer().render(
      ir,
      options: RenderOptions(
        // The adapter owns the metadata card when the result has metadata;
        // otherwise keep a hand-built IR's own Metadata field group.
        includeMetadata: ir.metadata.isEmpty && options.includeMetadata,
        headingBaseLevel: options.headingBaseLevel,
        collapsibleSections: true,
      ),
    );
    final title = _pageTitle(ir);
    final fullId = ir.contentId ?? '-';
    final shortId = fullId.length > 16 ? fullId.substring(0, 16) : fullId;
    final diff = compareWith == null
        ? null
        : DocumentDiff.between(compareWith, ir);
    return '''
<!doctype html>
<html lang="en" data-theme="system">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="generator" content="panthalassa">
<meta name="color-scheme" content="light dark">
<title>${_escapeHtml(title)}</title>
<script>$_themeBootScript</script>
<style>$_pageStyle</style>
</head>
<body>
<a class="skip-link" href="#content">Skip to content</a>
<header class="doc-header">
  <div class="header-inner">
    <a class="brand" href="#content">panthalassa</a>
    <div class="title-wrap">
      <div class="panthalassa-title" title="${_escapeHtml(title)}">${_escapeHtml(title)}</div>
      <div class="doc-meta">
        <span class="format-chip">${_escapeHtml(ir.sourceFormat.name)}</span>
        <span class="doc-id-badge" title="${_escapeHtml(fullId)}">
          <span class="doc-id-label">id</span>
          <span class="doc-id-value">${_escapeHtml(shortId)}${fullId.length > 16 ? '…' : ''}</span>
        </span>
      </div>
    </div>
    <div class="header-actions">
      <button type="button" class="icon-btn" id="search-toggle" aria-label="Search document (Ctrl+F)" aria-controls="find-bar" aria-expanded="false" title="Search (Ctrl+F)">🔍</button>
      <button type="button" class="icon-btn toc-toggle-btn" id="toc-toggle" aria-label="Contents" aria-controls="doc-toc" aria-expanded="false" title="Contents">☰</button>
      <button type="button" class="icon-btn" id="theme-toggle" aria-label="Toggle theme" title="Toggle theme">
        <span class="theme-icon">🌓</span>
      </button>
      <button type="button" class="action-btn" id="copy-id" aria-label="Copy document id" title="Copy document id">
        <span class="copy-icon">📋</span><span class="btn-label">Copy id</span>
      </button>
      <button type="button" class="action-btn" id="print-btn" aria-label="Print or save as PDF" title="Print or save as PDF">
        <span class="print-icon">🖨️</span><span class="btn-label">Print / PDF</span>
      </button>
    </div>
  </div>
  <div class="find-bar" id="find-bar" hidden>
    <div class="find-inner">
      <input id="find-input" type="search" placeholder="Search document…" aria-label="Search document" autocomplete="off" spellcheck="false">
      <span class="find-count" id="find-count" role="status" aria-live="polite"></span>
      <button type="button" class="icon-btn" id="find-prev" aria-label="Previous match" title="Previous match (Shift+Enter)">↑</button>
      <button type="button" class="icon-btn" id="find-next" aria-label="Next match" title="Next match (Enter)">↓</button>
      <button type="button" class="icon-btn" id="find-close" aria-label="Close search" title="Close (Esc)">✕</button>
    </div>
  </div>
</header>
<div class="doc-layout">
  <nav class="doc-toc" id="doc-toc" aria-label="Table of contents">
    <div class="toc-head">
      <h3 class="toc-title">Contents</h3>
      <div class="toc-actions">
        <button type="button" class="mini-btn" id="toc-collapse-all" aria-label="Collapse all" title="Collapse all">−</button>
        <button type="button" class="mini-btn" id="toc-expand-all" aria-label="Expand all" title="Expand all">+</button>
      </div>
    </div>
    <ul class="toc-list" id="toc-list"></ul>
  </nav>
  <div class="toc-backdrop" id="toc-backdrop" hidden></div>
  <main id="content" class="doc-body" tabindex="-1">
    ${_metadataCard(ir.metadata, options.includeMetadata)}
    $semantic
    ${_attachmentsBlock(ir.attachments)}
    ${diff == null ? '' : _diffBlock(diff, compareLabel)}
    ${_visualBlock(visual)}
  </main>
</div>
<footer class="doc-footer">
  <div class="footer-inner">
    <span class="footer-text">${_escapeHtml(ir.sourceFormat.name)} · documentId ${_escapeHtml(fullId)}</span>
    <span class="footer-divider">·</span>
    <span class="footer-text">Generated by panthalassa</span>
  </div>
</footer>
<button type="button" class="back-to-top" id="back-to-top" aria-label="Back to top" title="Back to top">
  <span class="btt-icon">↑</span>
</button>
<div class="lightbox" id="lightbox" role="dialog" aria-modal="true" aria-label="Visual page viewer" hidden>
  <div class="lightbox-toolbar">
    <span class="lightbox-label" id="lightbox-label">Visual page</span>
    <button type="button" class="mini-btn" id="zoom-out" aria-label="Zoom out" title="Zoom out">−</button>
    <span class="zoom-level" id="zoom-level">100%</span>
    <button type="button" class="mini-btn" id="zoom-in" aria-label="Zoom in" title="Zoom in">+</button>
    <button type="button" class="mini-btn" id="zoom-reset" title="Fit to screen">Fit</button>
    <button type="button" class="mini-btn" id="lightbox-svg" title="Download SVG">SVG</button>
    <button type="button" class="mini-btn" id="lightbox-png" title="Download PNG">PNG</button>
    <button type="button" class="mini-btn" id="lightbox-close" aria-label="Close viewer" title="Close (Esc)">✕</button>
  </div>
  <div class="lightbox-stage" id="lightbox-stage">
    <div class="lightbox-canvas" id="lightbox-canvas"></div>
  </div>
  <p class="lightbox-hint">Scroll or pinch to zoom · drag to pan · Esc to close</p>
</div>
<script>$_pageScript</script>
</body>
</html>
''';
  }

  String _pageTitle(DocumentIr ir) {
    for (final block in ir.body) {
      if (block is HeadingBlock && block.text.isNotEmpty) {
        return block.text
            .map((i) {
              if (i is TextRun) return i.text;
              return '';
            })
            .join()
            .trimRight();
      }
    }
    return 'panthalassa document';
  }

  String _metadataCard(Map<String, Object?> metadata, bool include) {
    if (!include || metadata.isEmpty) return '';
    final rows = <String>[];
    for (final entry in metadata.entries) {
      if (entry.key == 'visualPages') continue;
      final value = _metadataValue(entry.value);
      if (value.isEmpty) continue;
      rows.add(
        '<div class="meta-row">'
        '<span class="meta-key">${_escapeHtml(_humanizeKey(entry.key))}</span>'
        '<span class="meta-value">${_escapeHtml(value)}</span>'
        '</div>',
      );
    }
    if (rows.isEmpty) return '';
    return '''
<details class="doc-metadata" id="document-metadata" data-section-id="document-metadata" open>
  <summary class="metadata-summary"><h2 class="metadata-title" data-toc="false">Document details</h2></summary>
  <div class="meta-grid">${rows.join()}</div>
</details>
''';
  }

  String _humanizeKey(String key) {
    final spaced = key
        .replaceAll('_', ' ')
        .replaceAllMapped(RegExp(r'(?<=[a-z0-9])([A-Z])'), (m) => ' ${m[1]}');
    if (spaced.isEmpty) return key;
    return spaced[0].toUpperCase() + spaced.substring(1);
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

  String _attachmentsBlock(List<Attachment> attachments) {
    if (attachments.isEmpty) return '';
    final cards = <String>[];
    for (var index = 0; index < attachments.length; index++) {
      cards.add(_attachmentCard(attachments[index], index));
    }
    return '''
<section class="panthalassa-attachments" aria-label="Attachments">
  <h2 id="attachments">Attachments <span class="count-chip">${attachments.length}</span></h2>
  <p class="section-note">Payloads are previewed only when the parser retained attachment bytes or text.</p>
  <div class="attachments-grid">${cards.join()}</div>
</section>
''';
  }

  String _attachmentCard(Attachment attachment, int index) {
    final name = attachment.name ?? 'attachment-${index + 1}';
    final mime = attachment.mediaType ?? 'application/octet-stream';
    final rawDataUri = _attachmentDataUri(attachment, mime);
    final dataUri = rawDataUri == null ? null : _escapeHtml(rawDataUri);
    final text = attachment.text?.trim();
    final isImage = _imageTypes.contains(mime);
    final isPdf = mime == 'application/pdf';
    final isAudio = mime.startsWith('audio/');
    final isVideo = mime.startsWith('video/');
    final chips = <String>[
      mime,
      if (attachment.size != null) _formatBytes(attachment.size!),
      if (attachment.relationship != null) attachment.relationship!,
      if (attachment.encrypted) 'encrypted',
    ];
    final preview = <String>[];
    if (dataUri != null && isImage) {
      preview.add(
        '<img src="$dataUri" alt="${_escapeHtml(name)}" loading="lazy">',
      );
    } else if (dataUri != null && isAudio) {
      preview.add('<audio controls preload="none" src="$dataUri"></audio>');
    } else if (dataUri != null && isVideo) {
      preview.add('<video controls preload="metadata" src="$dataUri"></video>');
    } else if (dataUri != null && isPdf) {
      preview.add(
        '<details class="attachment-pdf-wrap"><summary>PDF preview</summary>'
        '<object class="attachment-pdf" data="$dataUri" type="application/pdf">'
        '<p>Embedded PDF preview is unavailable in this browser.</p>'
        '</object></details>',
      );
    }
    if (text != null && text.isNotEmpty) {
      preview.add(
        '<details class="attachment-text-wrap"><summary>Text preview</summary>'
        '<pre>${_escapeHtml(_truncateText(text))}</pre></details>',
      );
    }
    if (preview.isEmpty) {
      preview.add(
        '<p class="attachment-empty">${dataUri == null && attachment.bytes?.isNotEmpty == true ? 'Payload retained but too large to inline.' : 'No inline preview is available for this attachment.'}</p>',
      );
    }
    final download = dataUri == null
        ? ''
        : '<a class="mini-btn" href="$dataUri" download="${_escapeHtml(_safeFileName(name))}">Download</a>';
    return '''
<article class="attachment-card">
  <div class="attachment-head">
    <span class="attachment-name">${_escapeHtml(name)}</span>
    <span class="attachment-meta">${_escapeHtml(chips.join(' · '))}</span>
  </div>
  <div class="attachment-preview">${preview.join()}</div>
  <div class="attachment-actions">$download</div>
</article>
''';
  }

  String? _attachmentDataUri(Attachment attachment, String mime) {
    final bytes = attachment.bytes;
    if (bytes == null || bytes.isEmpty) return null;
    if (bytes.length > maxInlineAttachmentBytes) return null;
    final safeMime =
        RegExp(
          r'^[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*$',
        ).hasMatch(mime)
        ? mime
        : 'application/octet-stream';
    return 'data:$safeMime;base64,${base64Encode(bytes)}';
  }

  String _truncateText(String text) {
    if (text.length <= maxAttachmentTextChars) return text;
    return '${text.substring(0, maxAttachmentTextChars)}\n…';
  }

  String _safeFileName(String name) {
    final base = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '-').trim();
    return base.isEmpty ? 'attachment' : base;
  }

  String _diffBlock(DocumentDiff diff, String label) {
    final added = diff.rows
        .where((row) => row.right?.kind == DiffKind.added)
        .length;
    final removed = diff.rows
        .where((row) => row.left?.kind == DiffKind.removed)
        .length;
    final summary = diff.hasChanges
        ? '+$added added · −$removed removed'
        : 'No semantic changes detected.';
    final rows = <String>[
      for (final row in diff.rows)
        '<tr>'
            '${_diffCell(row.left, 'Previous', standard: 'del')}'
            '${_diffCell(row.right, 'Current', standard: 'add')}'
            '</tr>',
    ];
    final truncated = diff.truncated
        ? '<p class="section-note warning">Comparison is large; rows beyond the safety limit were compared positionally.</p>'
        : '';
    return '''
<section class="panthalassa-diff" aria-label="Version comparison">
  <h2 id="version-comparison">Version comparison</h2>
  <p class="section-note"><strong>${_escapeHtml(label)}</strong> → current document · ${_escapeHtml(summary)}</p>
  $truncated
  <div class="diff-scroll">
    <table class="diff-table">
      <thead><tr><th>${_escapeHtml(label)}</th><th>Current document</th></tr></thead>
      <tbody>${rows.join()}</tbody>
    </table>
  </div>
</section>
''';
  }

  String _diffCell(DiffLine? line, String side, {required String standard}) {
    if (line == null) {
      return '<td class="diff-cell diff-blank" data-side="$side" aria-hidden="true"></td>';
    }
    final kind = switch (line.kind) {
      DiffKind.unchanged => 'same',
      DiffKind.added => 'add',
      DiffKind.removed => 'del',
    };
    final sign = switch (line.kind) {
      DiffKind.unchanged => ' ',
      DiffKind.added => '+',
      DiffKind.removed => '−',
    };
    return '<td class="diff-cell diff-$kind" data-side="$side">'
        '<span class="diff-no">${line.lineNumber}</span>'
        '<span class="diff-sign">$sign</span>'
        '<span class="diff-text">${_escapeHtml(line.text)}</span>'
        '</td>';
  }

  String _visualBlock(VisualDocument? visual) {
    if (visual == null || visual.isEmpty) return '';
    final pages = <String>[];
    var index = 0;
    for (final page in visual.pages) {
      index++;
      final pageSvg = const SvgVisualRenderer().render(
        VisualDocument(
          sourceFormat: visual.sourceFormat,
          pages: [page],
          contentId: visual.contentId,
          metadata: visual.metadata,
        ),
      );
      final pageLabel = page.geometry.pageIndex != null
          ? 'Page ${page.geometry.pageIndex! + 1}'
          : 'Page $index';
      pages.add(
        '<div class="visual-page-card" data-page-index="$index" data-page-label="${_escapeHtml(pageLabel)}">'
        '<div class="visual-page-head">'
        '<span class="visual-page-label">${_escapeHtml(pageLabel)}</span>'
        '<span class="visual-page-size">${page.geometry.width.toInt()}×${page.geometry.height.toInt()}</span>'
        '<span class="visual-page-actions">'
        '<button type="button" class="mini-btn" data-visual-svg title="Download SVG">SVG</button>'
        '<button type="button" class="mini-btn" data-visual-png title="Download PNG">PNG</button>'
        '</span>'
        '</div>'
        '<div class="visual-frame" role="button" tabindex="0" aria-label="Open ${_escapeHtml(pageLabel)} in the zoom viewer">'
        '$pageSvg'
        '<span class="visual-zoom-hint">Click to zoom</span>'
        '</div>'
        '</div>',
      );
    }
    return '''
<section class="panthalassa-visuals" aria-label="Visual pages">
  <h2 id="visual-pages">Visual pages <span class="count-chip">${visual.pages.length}</span></h2>
  <div class="visual-grid">${pages.join()}</div>
</section>
''';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['B', 'KiB', 'MiB', 'GiB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final digits = value >= 100
        ? 0
        : value >= 10
        ? 1
        : 2;
    return '${value.toStringAsFixed(digits)} ${units[unit]}';
  }

  String _escapeHtml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');

  static const _themeBootScript = r'''
(() => {
  try {
    const stored = localStorage.getItem('panthalassa-theme');
    const mode = ['light', 'dark', 'system'].includes(stored) ? stored : 'system';
    const dark = mode === 'dark' || (mode === 'system' && window.matchMedia('(prefers-color-scheme: dark)').matches);
    document.documentElement.setAttribute('data-theme', dark ? 'dark' : 'light');
  } catch (e) { /* file:// sandbox */ }
})();
''';

  static const _pageStyle = r'''
/* ==========================================================================
   Design tokens
   ========================================================================== */
:root {
  --color-bg: #ffffff;
  --color-bg-alt: #f8fafc;
  --color-text: #0f172a;
  --color-text-muted: #64748b;
  --color-text-subtle: #94a3b8;
  --color-border: #e2e8f0;
  --color-border-weak: #f1f5f9;
  --color-accent: #2563eb;
  --color-accent-hover: #1d4ed8;
  --color-accent-soft: #eff6ff;
  --color-success: #059669;
  --color-success-soft: #ecfdf5;
  --color-warning: #d97706;
  --color-warning-soft: #fef3c7;
  --color-danger: #dc2626;
  --color-danger-soft: #fef2f2;
  --color-code-bg: #f1f5f9;
  --color-code-text: #0f172a;
  --color-shadow: 0 1px 3px 0 rgb(0 0 0 / 0.1), 0 1px 2px -1px rgb(0 0 0 / 0.1);
  --color-shadow-md: 0 4px 6px -1px rgb(0 0 0 / 0.1), 0 2px 4px -2px rgb(0 0 0 / 0.1);
  --tok-comment: #64748b;
  --tok-keyword: #7c3aed;
  --tok-string: #047857;
  --tok-number: #b45309;
  --tok-key: #1d4ed8;
  --tok-tag: #be123c;
  --tok-attr: #7c3aed;
  --tok-meta: #64748b;
  --tok-punct: #64748b;
  --radius-sm: 6px;
  --radius-md: 10px;
  --radius-lg: 14px;
  --transition: 150ms cubic-bezier(0.4, 0, 0.2, 1);
  --font-sans: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont,
    "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  --font-mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas,
    "Liberation Mono", "Courier New", monospace;
  --container-width: 1000px;
  --header-height: 4.25rem;
}

:root[data-theme="dark"] {
  --color-bg: #0b0f19;
  --color-bg-alt: #111827;
  --color-text: #f1f5f9;
  --color-text-muted: #94a3b8;
  --color-text-subtle: #64748b;
  --color-border: #334155;
  --color-border-weak: #1e293b;
  --color-accent: #3b82f6;
  --color-accent-hover: #60a5fa;
  --color-accent-soft: #172554;
  --color-success: #34d399;
  --color-success-soft: #064e3b;
  --color-warning: #fbbf24;
  --color-warning-soft: #713f12;
  --color-danger: #f87171;
  --color-danger-soft: #7f1d1d;
  --color-code-bg: #1e293b;
  --color-code-text: #e2e8f0;
  --color-shadow: 0 1px 3px 0 rgb(0 0 0 / 0.5), 0 1px 2px -1px rgb(0 0 0 / 0.6);
  --color-shadow-md: 0 4px 6px -1px rgb(0 0 0 / 0.4), 0 2px 4px -2px rgb(0 0 0 / 0.5);
  --tok-comment: #94a3b8;
  --tok-keyword: #c4b5fd;
  --tok-string: #6ee7b7;
  --tok-number: #fbbf24;
  --tok-key: #93c5fd;
  --tok-tag: #fda4af;
  --tok-attr: #c4b5fd;
  --tok-meta: #94a3b8;
  --tok-punct: #94a3b8;
}

@media (prefers-color-scheme: dark) {
  :root[data-theme="system"] {
    --color-bg: #0b0f19;
    --color-bg-alt: #111827;
    --color-text: #f1f5f9;
    --color-text-muted: #94a3b8;
    --color-text-subtle: #64748b;
    --color-border: #334155;
    --color-border-weak: #1e293b;
    --color-accent: #3b82f6;
    --color-accent-hover: #60a5fa;
    --color-accent-soft: #172554;
    --color-success: #34d399;
    --color-success-soft: #064e3b;
    --color-warning: #fbbf24;
    --color-warning-soft: #713f12;
    --color-danger: #f87171;
    --color-danger-soft: #7f1d1d;
    --color-code-bg: #1e293b;
    --color-code-text: #e2e8f0;
    --tok-comment: #94a3b8;
    --tok-keyword: #c4b5fd;
    --tok-string: #6ee7b7;
    --tok-number: #fbbf24;
    --tok-key: #93c5fd;
    --tok-tag: #fda4af;
    --tok-attr: #c4b5fd;
    --tok-meta: #94a3b8;
    --tok-punct: #94a3b8;
  }
}

/* ==========================================================================
   Reset & base
   ========================================================================== */
*, *::before, *::after { box-sizing: border-box; }
[hidden] { display: none !important; }
html {
  scroll-behavior: smooth;
  font-size: 16px;
  scroll-padding-top: calc(var(--header-height) + 1rem);
}
body {
  margin: 0;
  color: var(--color-text);
  background: var(--color-bg);
  font-family: var(--font-sans);
  line-height: 1.6;
  transition: background-color 0.3s ease, color 0.3s ease;
}
body.lightbox-open { overflow: hidden; }
a { color: var(--color-accent); text-decoration: none; border-bottom: 1px solid transparent; transition: border-color var(--transition); }
a:hover { color: var(--color-accent-hover); border-bottom-color: var(--color-accent-hover); }
:focus-visible { outline: 3px solid var(--color-accent); outline-offset: 2px; border-radius: 4px; }
.skip-link { position: absolute; left: -9999px; top: auto; width: 1px; height: 1px; overflow: hidden; z-index: -1; }
.skip-link:focus {
  position: fixed; top: 1rem; left: 1rem; width: auto; height: auto;
  padding: 0.5rem 1rem; background: var(--color-accent); color: #fff;
  border-radius: var(--radius-sm); z-index: 10000; text-decoration: none; overflow: visible;
}

/* ==========================================================================
   Typography & content
   ========================================================================== */
h1, h2, h3, h4, h5, h6 {
  color: var(--color-text); font-weight: 700; line-height: 1.25;
  margin-top: 0; margin-bottom: 0.75rem; letter-spacing: -0.01em;
}
h1 { font-size: 2rem; }
h2 { font-size: 1.5rem; }
h3 { font-size: 1.25rem; }
h4 { font-size: 1.1rem; }
p { margin: 0 0 1rem 0; }
ul, ol { margin: 0 0 1rem 1.25rem; padding: 0; }
li { margin-bottom: 0.35rem; }
strong { color: var(--color-text); }
em { color: var(--color-text); }
code {
  font-family: var(--font-mono); font-size: 0.875em; background: var(--color-code-bg);
  color: var(--color-code-text); padding: 0.15em 0.35em; border-radius: 4px;
  border: 1px solid var(--color-border-weak);
}
pre {
  position: relative;
  font-family: var(--font-mono); font-size: 0.875rem; background: var(--color-code-bg);
  color: var(--color-code-text); border: 1px solid var(--color-border);
  border-radius: var(--radius-md); padding: 1rem; overflow-x: auto;
  margin: 0 0 1.25rem 0; line-height: 1.5;
}
dl { display: grid; grid-template-columns: minmax(120px, 0.35fr) 1fr; gap: 0.35rem 1rem; margin: 0 0 1rem; }
dt { font-size: 0.82rem; font-weight: 600; color: var(--color-text-muted); overflow-wrap: anywhere; }
dd { margin: 0; font-size: 0.9rem; overflow-wrap: anywhere; }
pre code { background: transparent; padding: 0; border: none; font-size: inherit; color: inherit; }
table { width: 100%; border-collapse: collapse; margin: 0 0 1.25rem 0; background: var(--color-bg-alt); border: 1px solid var(--color-border); border-radius: var(--radius-md); overflow: hidden; }
th, td { text-align: left; padding: 0.75rem 1rem; border-bottom: 1px solid var(--color-border-weak); }
th { background: var(--color-bg-alt); font-weight: 700; font-size: 0.875rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 0.04em; }
tr:nth-child(even) td { background: rgba(0, 0, 0, 0.02); }
tr:hover td { background: rgba(37, 99, 235, 0.04); }
blockquote {
  margin: 1rem 0; padding: 0.85rem 1.25rem; border-left: 4px solid var(--color-accent);
  background: var(--color-bg-alt); color: var(--color-text-muted);
  border-radius: 0 var(--radius-md) var(--radius-md) 0; font-style: italic;
}
.section-note { font-size: 0.85rem; color: var(--color-text-muted); margin: -0.25rem 0 1rem; }
.section-note.warning { color: var(--color-warning); }
.count-chip {
  display: inline-block; font-size: 0.72rem; font-weight: 700; vertical-align: middle;
  padding: 0.1rem 0.5rem; border-radius: 999px; color: var(--color-accent-hover);
  background: var(--color-accent-soft); border: 1px solid color-mix(in srgb, var(--color-accent) 30%, transparent);
}

/* ==========================================================================
   Header & search bar
   ========================================================================== */
.doc-header {
  position: sticky; top: 0; z-index: 60;
  background: color-mix(in srgb, var(--color-bg) 92%, transparent);
  border-bottom: 1px solid var(--color-border);
  backdrop-filter: blur(10px);
  transition: background-color var(--transition);
}
.header-inner {
  max-width: 1280px; margin: 0 auto; padding: 0.7rem 1.25rem;
  display: flex; align-items: center; gap: 1rem; min-height: var(--header-height);
}
.brand {
  font-weight: 800; font-size: 1.15rem; color: var(--color-accent);
  letter-spacing: -0.02em; white-space: nowrap; border: none;
}
.title-wrap { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 0.15rem; }
.panthalassa-title {
  font-size: 1.05rem; font-weight: 700; color: var(--color-text);
  letter-spacing: -0.01em; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
}
.doc-meta { display: flex; align-items: center; gap: 0.5rem; flex-wrap: wrap; }
.format-chip, .doc-id-badge {
  display: inline-flex; align-items: center; gap: 0.3rem; font-size: 0.72rem;
  font-weight: 700; padding: 0.15rem 0.55rem; border-radius: 999px;
  border: 1px solid var(--color-border); background: var(--color-bg-alt);
  color: var(--color-text-muted); white-space: nowrap;
}
.format-chip { color: var(--color-accent-hover); background: var(--color-accent-soft); border-color: color-mix(in srgb, var(--color-accent) 35%, transparent); }
.doc-id-label { color: var(--color-text-subtle); }
.doc-id-value { font-family: var(--font-mono); color: var(--color-text); }
.header-actions { display: flex; align-items: center; gap: 0.4rem; flex-shrink: 0; }
.icon-btn, .action-btn {
  display: inline-flex; align-items: center; justify-content: center; gap: 0.4rem;
  border: 1px solid var(--color-border); background: var(--color-bg);
  color: var(--color-text); cursor: pointer; transition: all var(--transition);
}
.icon-btn { width: 2.15rem; height: 2.15rem; border-radius: var(--radius-md); font-size: 1rem; }
.action-btn { padding: 0.45rem 0.8rem; border-radius: var(--radius-md); font-size: 0.8rem; font-weight: 600; }
.icon-btn:hover, .action-btn:hover { background: var(--color-accent-soft); color: var(--color-accent-hover); border-color: var(--color-accent); transform: translateY(-1px); }
.action-btn.copied { background: var(--color-success-soft); border-color: var(--color-success); color: var(--color-success); }
.find-bar { border-top: 1px solid var(--color-border); background: var(--color-bg-alt); }
.find-inner { max-width: 1280px; margin: 0 auto; padding: 0.55rem 1.25rem; display: flex; align-items: center; gap: 0.45rem; }
.find-inner input {
  flex: 1; min-width: 0; padding: 0.45rem 0.7rem; font: inherit; font-size: 0.9rem;
  color: var(--color-text); background: var(--color-bg); border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
}
.find-inner input:focus { border-color: var(--color-accent); outline: 2px solid color-mix(in srgb, var(--color-accent) 35%, transparent); }
.find-count { min-width: 3.4rem; text-align: center; font-family: var(--font-mono); font-size: 0.75rem; color: var(--color-text-muted); }
mark.search-hit { background: #fde68a; color: #111827; padding: 0 0.05em; border-radius: 2px; }
.search-current { background: #f59e0b; color: #111827; box-shadow: 0 0 0 2px #d97706; border-radius: 2px; }
:root[data-theme="dark"] mark.search-hit { background: #854d0e; color: #fef3c7; }
:root[data-theme="dark"] .search-current { background: #fbbf24; color: #111827; box-shadow: 0 0 0 2px #d97706; }
svg .svg-search-hit { fill: #b45309 !important; font-weight: 700; }
svg .svg-search-hit.search-current { fill: #dc2626 !important; }
:root[data-theme="dark"] svg .svg-search-hit { fill: #fbbf24 !important; }
:root[data-theme="dark"] svg .svg-search-hit.search-current { fill: #f87171 !important; }

/* ==========================================================================
   Layout & collapsible outline
   ========================================================================== */
.doc-layout {
  max-width: 1280px; margin: 0 auto; padding: 0 1rem;
  display: grid; grid-template-columns: minmax(0, 1fr); align-items: start;
}
.doc-body { width: 100%; max-width: 900px; margin: 0 auto; padding: 2rem 0 3rem; min-width: 0; }
.doc-toc { display: none; }
.doc-toc.open {
  display: block; position: fixed; inset: 0 auto 0 0; z-index: 90;
  width: min(320px, 86vw); overflow-y: auto; padding: 1.25rem;
  background: var(--color-bg); border-right: 1px solid var(--color-border);
  box-shadow: var(--color-shadow-md);
}
.toc-backdrop.open { display: block; position: fixed; inset: 0; z-index: 80; background: rgb(0 0 0 / 0.4); }
.toc-head { display: flex; align-items: center; justify-content: space-between; gap: 0.5rem; margin-bottom: 0.75rem; }
.toc-title { font-size: 0.78rem; text-transform: uppercase; letter-spacing: 0.08em; color: var(--color-text-subtle); margin: 0; }
.toc-actions { display: flex; gap: 0.25rem; }
.toc-list, .toc-list ul { list-style: none; margin: 0; padding: 0; font-size: 0.84rem; }
.toc-list ul { margin-left: 0.4rem; padding-left: 0.6rem; border-left: 1px solid var(--color-border-weak); }
.toc-list li { margin: 0; }
.toc-list li.collapsed > ul { display: none; }
.toc-row { display: flex; align-items: center; gap: 0.15rem; }
.toc-row > a {
  flex: 1; display: block; padding: 0.28rem 0.45rem; border-radius: var(--radius-sm);
  color: var(--color-text-muted); border: 1px solid transparent; overflow-wrap: anywhere;
}
.toc-row > a:hover { background: var(--color-bg-alt); color: var(--color-accent); border-color: color-mix(in srgb, var(--color-accent) 22%, transparent); }
.toc-row > a.toc-active { background: var(--color-accent-soft); color: var(--color-accent-hover); border-color: var(--color-accent); font-weight: 600; }
.toc-toggle {
  width: 1.35rem; height: 1.35rem; flex-shrink: 0; border: none; border-radius: 4px;
  background: transparent; color: var(--color-text-subtle); cursor: pointer;
  font-size: 0.7rem; line-height: 1; padding: 0;
}
.toc-toggle:hover { background: var(--color-bg-alt); color: var(--color-accent); }
.toc-toggle .toc-chevron { display: inline-block; transition: transform var(--transition); }
li.collapsed > .toc-row .toc-chevron { transform: rotate(-90deg); }
.mini-btn {
  display: inline-flex; align-items: center; justify-content: center; gap: 0.25rem;
  padding: 0.25rem 0.5rem; border: 1px solid var(--color-border); border-radius: var(--radius-sm);
  background: var(--color-bg); color: var(--color-text-muted); font-size: 0.72rem;
  font-weight: 600; cursor: pointer; transition: all var(--transition); text-decoration: none;
}
.mini-btn:hover { background: var(--color-accent-soft); color: var(--color-accent-hover); border-color: var(--color-accent); }

@media (min-width: 1024px) {
  .doc-layout { grid-template-columns: 250px minmax(0, 1fr); gap: 2.5rem; padding: 0 1.5rem; }
  .doc-toc {
    display: block; position: sticky; top: calc(var(--header-height) + 1rem);
    align-self: start; max-height: calc(100vh - var(--header-height) - 2rem);
    overflow-y: auto; padding: 1rem 0.75rem 2rem 0;
    border-right: 1px solid var(--color-border);
  }
  .toc-toggle-btn { display: none !important; }
  .doc-body { padding: 2rem 0 4rem; }
}

/* ==========================================================================
   Metadata & collapsible sections
   ========================================================================== */
.doc-metadata, .doc-section {
  border: 1px solid var(--color-border); border-radius: var(--radius-lg);
  background: var(--color-bg-alt); overflow: hidden; margin: 0 0 1.5rem;
}
.metadata-summary, .section-summary {
  display: flex; align-items: center; justify-content: space-between; gap: 1rem;
  padding: 0.8rem 1.25rem; cursor: pointer; list-style: none; user-select: none;
}
.metadata-summary::-webkit-details-marker, .section-summary::-webkit-details-marker { display: none; }
.metadata-summary::after, .section-summary::after {
  content: "▾"; color: var(--color-text-subtle); font-size: 0.8rem;
  transition: transform var(--transition); flex-shrink: 0;
}
details:not([open]) > .metadata-summary::after,
details:not([open]) > .section-summary::after { transform: rotate(-90deg); }
.metadata-title { margin: 0; font-size: 0.9rem; text-transform: uppercase; letter-spacing: 0.08em; color: var(--color-text-subtle); }
.section-summary h2 { margin: 0; font-size: 1.15rem; }
.meta-grid {
  display: grid; grid-template-columns: minmax(120px, 0.4fr) 1fr;
  gap: 0.6rem 1.25rem; padding: 0 1.25rem 1.25rem;
}
.meta-row { display: contents; }
.meta-key { font-size: 0.72rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.06em; color: var(--color-text-subtle); overflow-wrap: anywhere; }
.meta-value { font-size: 0.86rem; color: var(--color-text); overflow-wrap: anywhere; }
.section-body { padding: 0 1.25rem 1.25rem; }
.section-body > :last-child { margin-bottom: 0; }
.doc-section > summary h2 { overflow-wrap: anywhere; }

/* ==========================================================================
   Code blocks & syntax tokens
   ========================================================================== */
.code-block { position: relative; margin: 0 0 1.25rem 0; }
pre.has-copy { padding-top: 2.65rem; }
.copy-btn {
  position: absolute; top: 0.45rem; right: 0.55rem; z-index: 2;
  padding: 0.22rem 0.55rem; border-radius: var(--radius-sm); border: 1px solid var(--color-border);
  background: var(--color-bg-alt); color: var(--color-text-muted);
  font-family: var(--font-mono); font-size: 0.68rem; font-weight: 600;
  cursor: pointer; transition: all var(--transition);
}
.copy-btn:hover { background: var(--color-accent); color: #fff; border-color: var(--color-accent); }
.copy-btn.copied { background: var(--color-success); color: #fff; border-color: var(--color-success); }
.tok-comment { color: var(--tok-comment); font-style: italic; }
.tok-keyword { color: var(--tok-keyword); font-weight: 600; }
.tok-string { color: var(--tok-string); }
.tok-number { color: var(--tok-number); }
.tok-key { color: var(--tok-key); font-weight: 600; }
.tok-tag { color: var(--tok-tag); font-weight: 600; }
.tok-attr { color: var(--tok-attr); }
.tok-meta { color: var(--tok-meta); font-style: italic; }
.tok-punct { color: var(--tok-punct); }

/* ==========================================================================
   Attachments
   ========================================================================== */
.attachments-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 1rem; }
.attachment-card {
  display: flex; flex-direction: column; overflow: hidden;
  border: 1px solid var(--color-border); border-radius: var(--radius-md);
  background: var(--color-bg);
}
.attachment-head { display: flex; flex-direction: column; gap: 0.2rem; padding: 0.65rem 0.85rem; background: var(--color-bg-alt); border-bottom: 1px solid var(--color-border); }
.attachment-name { font-weight: 700; font-size: 0.88rem; overflow-wrap: anywhere; }
.attachment-meta { font-family: var(--font-mono); font-size: 0.68rem; color: var(--color-text-muted); overflow-wrap: anywhere; }
.attachment-preview { padding: 0.75rem; }
.attachment-preview img, .attachment-preview video { display: block; max-width: 100%; max-height: 320px; margin: 0 auto; border-radius: var(--radius-sm); }
.attachment-preview audio { width: 100%; }
.attachment-preview pre { max-height: 260px; overflow: auto; margin: 0.4rem 0 0; font-size: 0.72rem; white-space: pre-wrap; overflow-wrap: anywhere; }
.attachment-preview object.attachment-pdf { width: 100%; height: 320px; border: 0; border-radius: var(--radius-sm); }
.attachment-preview summary { cursor: pointer; font-size: 0.78rem; color: var(--color-accent); }
.attachment-empty { margin: 0; font-size: 0.76rem; color: var(--color-text-subtle); }
.attachment-actions { display: flex; flex-wrap: wrap; gap: 0.4rem; margin-top: auto; padding: 0 0.75rem 0.75rem; }
.panthalassa-attachments, .panthalassa-diff, .panthalassa-visuals { margin-top: 2rem; padding-top: 1.5rem; border-top: 1px solid var(--color-border); }

/* ==========================================================================
   Side-by-side diff
   ========================================================================== */
.diff-scroll { overflow-x: auto; border: 1px solid var(--color-border); border-radius: var(--radius-md); }
.diff-table { margin: 0; table-layout: fixed; font-family: var(--font-mono); font-size: 0.76rem; background: var(--color-bg); }
.diff-table th { font-family: var(--font-sans); }
.diff-cell { vertical-align: top; padding: 0.18rem 0.5rem; border-bottom: 1px solid var(--color-border-weak); white-space: pre-wrap; overflow-wrap: anywhere; }
.diff-no { display: inline-block; min-width: 2.3rem; color: var(--color-text-subtle); user-select: none; }
.diff-sign { display: inline-block; width: 0.9rem; color: var(--color-text-subtle); }
.diff-del { background: color-mix(in srgb, var(--color-danger) 12%, transparent); }
.diff-add { background: color-mix(in srgb, var(--color-success) 14%, transparent); }
.diff-blank { background: var(--color-bg-alt); }
.diff-same { background: transparent; }

/* ==========================================================================
   Visual page gallery
   ========================================================================== */
.visuals-title { font-size: 0.9rem; text-transform: uppercase; letter-spacing: 0.08em; color: var(--color-text-subtle); margin: 0 0 1rem; }
.visual-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 1rem; }
.visual-page-card {
  display: flex; flex-direction: column; overflow: hidden;
  border: 1px solid var(--color-border); border-radius: var(--radius-lg);
  background: var(--color-bg);
  transition: transform var(--transition), box-shadow var(--transition), border-color var(--transition);
}
.visual-page-card:hover { transform: translateY(-2px); box-shadow: var(--color-shadow-md); border-color: var(--color-accent); }
.visual-page-head { display: flex; align-items: center; gap: 0.5rem; padding: 0.55rem 0.75rem; background: var(--color-bg-alt); border-bottom: 1px solid var(--color-border); font-size: 0.78rem; }
.visual-page-label { font-weight: 700; color: var(--color-text); }
.visual-page-size { font-family: var(--font-mono); font-size: 0.68rem; color: var(--color-text-muted); background: color-mix(in srgb, var(--color-accent) 10%, transparent); padding: 0.08rem 0.4rem; border-radius: 4px; border: 1px solid color-mix(in srgb, var(--color-accent) 22%, transparent); }
.visual-page-actions { display: flex; gap: 0.25rem; margin-left: auto; }
.visual-frame { position: relative; cursor: zoom-in; background: var(--color-bg-alt); }
.visual-frame:focus-visible { outline: 3px solid var(--color-accent); outline-offset: -3px; }
.visual-frame svg { display: block; width: 100%; height: auto; }
.visual-zoom-hint {
  position: absolute; right: 0.5rem; bottom: 0.5rem; padding: 0.12rem 0.45rem;
  border-radius: 999px; font-size: 0.68rem; color: var(--color-text);
  background: color-mix(in srgb, var(--color-bg) 85%, transparent);
  border: 1px solid var(--color-border); opacity: 0; transition: opacity var(--transition);
}
.visual-page-card:hover .visual-zoom-hint, .visual-frame:focus-visible .visual-zoom-hint { opacity: 1; }

/* ==========================================================================
   Lightbox
   ========================================================================== */
.lightbox { position: fixed; inset: 0; z-index: 200; display: flex; flex-direction: column; background: color-mix(in srgb, var(--color-bg) 96%, transparent); backdrop-filter: blur(6px); }
.lightbox-toolbar { display: flex; align-items: center; flex-wrap: wrap; gap: 0.35rem; padding: 0.55rem 1rem; background: var(--color-bg-alt); border-bottom: 1px solid var(--color-border); }
.lightbox-label { margin-right: auto; font-weight: 700; font-size: 0.9rem; }
.zoom-level { min-width: 3.2rem; text-align: center; font-family: var(--font-mono); font-size: 0.72rem; color: var(--color-text-muted); }
.lightbox-stage { position: relative; flex: 1; display: flex; align-items: center; justify-content: center; overflow: hidden; touch-action: none; cursor: grab; }
.lightbox-stage.dragging { cursor: grabbing; }
.lightbox-canvas { transform-origin: center center; will-change: transform; filter: drop-shadow(0 8px 22px rgb(0 0 0 / 0.28)); }
.lightbox-canvas svg { display: block; }
.lightbox-hint { margin: 0; padding: 0.5rem 1rem; text-align: center; font-size: 0.72rem; color: var(--color-text-muted); border-top: 1px solid var(--color-border); }

/* ==========================================================================
   Footer & back to top
   ========================================================================== */
.doc-footer { margin-top: 2.5rem; padding: 1.25rem 1rem; border-top: 1px solid var(--color-border); background: var(--color-bg-alt); }
.footer-inner { max-width: 1280px; margin: 0 auto; display: flex; flex-wrap: wrap; align-items: center; gap: 0.5rem; font-size: 0.78rem; color: var(--color-text-muted); }
.footer-divider { opacity: 0.5; }
.back-to-top {
  position: fixed; right: 1.25rem; bottom: 1.25rem; z-index: 100;
  width: 2.5rem; height: 2.5rem; border-radius: 50%;
  border: 1px solid var(--color-border); background: var(--color-bg); color: var(--color-text);
  font-size: 1.1rem; cursor: pointer; opacity: 0; transform: translateY(1rem); visibility: hidden;
  transition: opacity var(--transition), transform var(--transition), visibility var(--transition);
  box-shadow: var(--color-shadow); display: flex; align-items: center; justify-content: center;
}
.back-to-top.visible { opacity: 1; transform: translateY(0); visibility: visible; }
.back-to-top:hover { background: var(--color-accent); color: #fff; border-color: var(--color-accent); }

/* ==========================================================================
   Responsive
   ========================================================================== */
@media (max-width: 1023px) {
  .doc-toc { display: none; }
  .doc-toc.open { display: block; }
}
@media (max-width: 720px) {
  .header-inner { flex-wrap: wrap; gap: 0.5rem; }
  .title-wrap { order: 3; flex-basis: 100%; }
  .header-actions { margin-left: auto; }
  .btn-label { display: none; }
  .visual-grid { grid-template-columns: 1fr; }
  .meta-grid { grid-template-columns: 1fr; }
  .meta-key, .meta-value { grid-column: 1 / -1; }
  dl { grid-template-columns: 1fr; gap: 0.1rem; }
  dd { margin-bottom: 0.5rem; }
  .diff-table, .diff-table tbody, .diff-table tr, .diff-table td { display: block; width: 100%; }
  .diff-table thead { display: none; }
  .diff-cell::before { content: attr(data-side); display: block; font-family: var(--font-sans); font-size: 0.62rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.06em; color: var(--color-text-subtle); margin-bottom: 0.05rem; }
  .diff-blank { display: none; }
}
@media (max-width: 480px) {
  .doc-id-badge { display: none; }
  .lightbox-label { flex-basis: 100%; }
}

/* ==========================================================================
   Print
   ========================================================================== */
@media print {
  .doc-header, .doc-toc, .toc-backdrop, .back-to-top, .copy-btn,
  .visual-page-actions, .visual-zoom-hint, .lightbox, .find-bar { display: none !important; }
  .doc-layout { display: block; padding: 0; }
  .doc-body { max-width: none; padding: 0; }
  .visual-grid { display: block; }
  .visual-page-card { break-inside: avoid; page-break-inside: avoid; margin-bottom: 1rem; border: 1px solid #ccc; }
  .doc-metadata, .doc-section, .attachment-card { break-inside: avoid; page-break-inside: avoid; }
  body { background: #fff; color: #000; }
  a { color: #000; text-decoration: none; border: none; }
  pre, code { background: #f5f5f5; color: #000; border-color: #ccc; }
  .doc-section[open] > .section-summary, .doc-metadata[open] > .metadata-summary { border-bottom: 1px solid #ccc; }
}

@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { animation-duration: 0.01ms !important; transition-duration: 0.01ms !important; scroll-behavior: auto !important; }
}
''';

  static const _pageScript = r'''
(() => {
  "use strict";

  const KEY_THEME = 'panthalassa-theme';
  const KEY_TOC = 'panthalassa-toc';
  const KEY_SECTIONS = 'panthalassa-sections';
  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));
  const html = document.documentElement;
  const content = document.getElementById('content');
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  let lightboxOpen = false;

  const store = {
    get(key, fallback) {
      try { return localStorage.getItem(key) ?? fallback; } catch (error) { return fallback; }
    },
    set(key, value) {
      try { localStorage.setItem(key, value); } catch (error) { /* sandboxed */ }
    },
    json(key, fallback) {
      try {
        const parsed = JSON.parse(localStorage.getItem(key) || 'null');
        return parsed && typeof parsed === 'object' ? parsed : fallback;
      } catch (error) { return fallback; }
    },
    setJson(key, value) {
      try { localStorage.setItem(key, JSON.stringify(value)); } catch (error) { /* sandboxed */ }
    }
  };

  async function copyText(text) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch (error) { /* fall through to execCommand */ }
    try {
      const area = document.createElement('textarea');
      area.value = text;
      area.setAttribute('readonly', '');
      area.style.position = 'fixed';
      area.style.opacity = '0';
      document.body.appendChild(area);
      area.select();
      const ok = document.execCommand('copy');
      area.remove();
      return ok;
    } catch (error) { return false; }
  }

  function flashLabel(button, label) {
    if (!button.dataset.original) button.dataset.original = button.innerHTML;
    button.textContent = label;
    button.classList.add('copied');
    setTimeout(() => {
      button.innerHTML = button.dataset.original;
      button.classList.remove('copied');
    }, 1400);
  }

  // ---------------------------------------------------------------- theme
  const THEME_LABELS = { light: '☀️', dark: '🌙', system: '🌓' };
  const themeToggle = document.getElementById('theme-toggle');
  const themeIcon = $('.theme-icon');
  let themeMode = store.get(KEY_THEME, 'system');
  if (!['light', 'dark', 'system'].includes(themeMode)) themeMode = 'system';

  function applyTheme() {
    const resolved = themeMode === 'system'
      ? (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light')
      : themeMode;
    html.setAttribute('data-theme', resolved);
    if (themeIcon) themeIcon.textContent = THEME_LABELS[themeMode] || '🌓';
    if (themeToggle) themeToggle.title = 'Theme: ' + themeMode + ' (' + resolved + ')';
  }
  if (themeToggle) {
    themeToggle.addEventListener('click', () => {
      const order = ['light', 'dark', 'system'];
      themeMode = order[(order.indexOf(themeMode) + 1) % order.length];
      store.set(KEY_THEME, themeMode);
      applyTheme();
    });
  }
  const scheme = window.matchMedia('(prefers-color-scheme: dark)');
  const onScheme = () => { if (themeMode === 'system') applyTheme(); };
  if (scheme.addEventListener) scheme.addEventListener('change', onScheme);
  else if (scheme.addListener) scheme.addListener(onScheme);
  applyTheme();

  // ------------------------------------------------------------- clipboard
  const copyBtn = document.getElementById('copy-id');
  const docIdBadge = $('.doc-id-badge');
  const fullId = docIdBadge ? (docIdBadge.getAttribute('title') || '') : '';
  if (copyBtn) {
    copyBtn.addEventListener('click', async () => {
      if (await copyText(fullId)) flashLabel(copyBtn, 'Copied');
    });
  }

  const printBtn = document.getElementById('print-btn');
  if (printBtn) printBtn.addEventListener('click', () => window.print());

  // --------------------------------------------------------- table of contents
  const toc = document.getElementById('doc-toc');
  const tocList = document.getElementById('toc-list');
  const tocToggle = document.getElementById('toc-toggle');
  const tocBackdrop = document.getElementById('toc-backdrop');
  const headings = content
    ? $$('h1, h2, h3, h4, h5, h6', content).filter(
        (heading) => heading.dataset.toc !== 'false' && !heading.closest('.doc-metadata')
      )
    : [];
  let tocState = store.json(KEY_TOC, {});

  function setTocCollapsed(item, collapsed, persist = true) {
    item.classList.toggle('collapsed', collapsed);
    const row = item.firstElementChild;
    const button = row ? row.querySelector('.toc-toggle') : null;
    if (button) button.setAttribute('aria-expanded', String(!collapsed));
    if (persist && item.dataset.headingId) {
      tocState[item.dataset.headingId] = collapsed ? 'closed' : 'open';
      store.setJson(KEY_TOC, tocState);
    }
  }

  function decorateToc(list) {
    Array.from(list.children).forEach((item) => {
      const sublist = Array.from(item.children).find((child) => child.tagName === 'UL');
      if (!sublist) return;
      if (!sublist.children.length) {
        sublist.remove();
        return;
      }
      const row = item.querySelector('.toc-row');
      if (row) {
        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'toc-toggle';
        button.innerHTML = '<span class="toc-chevron">▾</span>';
        button.setAttribute('aria-label', 'Collapse section');
        button.setAttribute('aria-expanded', 'true');
        button.addEventListener('click', (event) => {
          event.preventDefault();
          event.stopPropagation();
          setTocCollapsed(item, !item.classList.contains('collapsed'));
        });
        row.insertBefore(button, row.firstChild);
      }
      decorateToc(sublist);
    });
  }

  function buildToc() {
    if (!tocList) return;
    const root = document.createDocumentFragment();
    const stack = [{ level: 0, list: root }];
    headings.forEach((heading, index) => {
      if (!heading.id) heading.id = 'heading-' + (index + 1);
      const level = Number(heading.tagName.charAt(1));
      while (stack.length > 1 && level <= stack[stack.length - 1].level) stack.pop();
      const parent = stack[stack.length - 1];
      const item = document.createElement('li');
      item.dataset.headingId = heading.id;
      const row = document.createElement('div');
      row.className = 'toc-row';
      const link = document.createElement('a');
      link.href = '#' + heading.id;
      link.dataset.headingId = heading.id;
      link.textContent = heading.textContent.trim() || heading.id;
      link.addEventListener('click', (event) => {
        event.preventDefault();
        const details = heading.closest('details');
        if (details && !details.open) details.open = true;
        try { if (history.replaceState) history.replaceState(null, '', '#' + heading.id); } catch (error) { /* file:// */ }
        heading.scrollIntoView({ behavior: reduceMotion ? 'auto' : 'smooth', block: 'start' });
        if (window.matchMedia('(max-width: 1023px)').matches) closeToc();
      });
      row.appendChild(link);
      item.appendChild(row);
      parent.list.appendChild(item);
      const sublist = document.createElement('ul');
      item.appendChild(sublist);
      stack.push({ level, list: sublist });
    });
    tocList.appendChild(root);
    decorateToc(tocList);
    $$('li[data-heading-id]', tocList).forEach((item) => {
      if (tocState[item.dataset.headingId] === 'closed' && item.querySelector('.toc-toggle')) {
        setTocCollapsed(item, true, false);
      }
    });
  }

  function openToc() {
    if (!toc) return;
    toc.classList.add('open');
    if (tocBackdrop) tocBackdrop.hidden = false;
    if (tocBackdrop) tocBackdrop.classList.add('open');
    if (tocToggle) tocToggle.setAttribute('aria-expanded', 'true');
  }
  function closeToc() {
    if (!toc) return;
    toc.classList.remove('open');
    if (tocBackdrop) { tocBackdrop.classList.remove('open'); tocBackdrop.hidden = true; }
    if (tocToggle) tocToggle.setAttribute('aria-expanded', 'false');
  }
  if (tocToggle) {
    tocToggle.addEventListener('click', () => {
      if (toc && toc.classList.contains('open')) closeToc(); else openToc();
    });
  }
  if (tocBackdrop) tocBackdrop.addEventListener('click', closeToc);

  const collapseAll = document.getElementById('toc-collapse-all');
  const expandAll = document.getElementById('toc-expand-all');
  if (collapseAll) collapseAll.addEventListener('click', () => {
    $$('#toc-list li[data-heading-id]').forEach((item) => {
      if (item.querySelector('.toc-toggle')) setTocCollapsed(item, true);
    });
  });
  if (expandAll) expandAll.addEventListener('click', () => {
    $$('#toc-list li[data-heading-id]').forEach((item) => {
      if (item.querySelector('.toc-toggle')) setTocCollapsed(item, false);
    });
  });

  function updateActiveToc() {
    if (!tocList) return;
    let activeId = null;
    for (const heading of headings) {
      const rect = heading.getBoundingClientRect();
      if (!heading.getClientRects().length) continue;
      if (rect.top <= 130) activeId = heading.id;
      else break;
    }
    $$('a.toc-active', tocList).forEach((link) => link.classList.remove('toc-active'));
    if (!activeId) return;
    const link = Array.from(tocList.querySelectorAll('a')).find(
      (candidate) => candidate.dataset.headingId === activeId
    );
    if (link) link.classList.add('toc-active');
  }

  // ------------------------------------------------------- persisted sections
  const sectionState = store.json(KEY_SECTIONS, {});
  $$('details[data-section-id]').forEach((details) => {
    const id = details.dataset.sectionId;
    if (sectionState[id] === 'closed') details.open = false;
    details.addEventListener('toggle', () => {
      sectionState[id] = details.open ? 'open' : 'closed';
      store.setJson(KEY_SECTIONS, sectionState);
    });
  });

  // ------------------------------------------------------- syntax highlighting
  const LANG_ALIASES = {
    js: 'javascript', jsx: 'javascript', ts: 'typescript', tsx: 'typescript',
    py: 'python', rb: 'ruby', sh: 'shell', bash: 'shell', zsh: 'shell', fish: 'shell',
    yml: 'yaml', htm: 'markup', html: 'markup', xhtml: 'markup', xml: 'markup', svg: 'markup',
    ps1: 'powershell'
  };
  const KEYWORD_LISTS = {
    json: 'true false null'.split(' '),
    javascript: 'async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield'.split(' '),
    typescript: 'abstract any as assert async await boolean break case catch class const constructor continue declare default delete do else enum export extends false finally for from function get if implements import in infer instanceof interface is keyof let module namespace never new null number object of private protected public readonly require return set static string super switch symbol this throw true try type typeof undefined unique unknown var void while with yield'.split(' '),
    dart: 'abstract as assert async await break case catch class const continue covariant default deferred do dynamic else enum export extends extension external factory false final finally for Function get hide if implements import in interface is late library mixin new null on operator part required rethrow return set show static super switch sync this throw true try typedef var void while with yield'.split(' '),
    python: 'and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield match case'.split(' '),
    ruby: 'alias and begin break case class def defined do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield'.split(' '),
    sql: 'add all alter and any as asc begin between by case cast check column commit constraint create cross current_date current_timestamp database default delete desc distinct drop else end escape exists false fetch foreign from full grant group having in index inner insert into is join key left like limit not null offset on or order outer primary references right rollback row select set table then true union unique update using values view when where with'.split(' '),
    shell: 'case do done elif else esac fi for function if in select then time until while'.split(' '),
    yaml: 'true false null yes no on off'.split(' '),
    css: 'important media supports keyframes import font-face'.split(' '),
    powershell: 'begin break catch class continue data define do dynamicparam else elseif end enum exit filter finally for foreach from function if in param process return switch throw trap try until using var while'.split(' ')
  };
  const KEYWORD_SETS = {};
  Object.keys(KEYWORD_LISTS).forEach((key) => { KEYWORD_SETS[key] = new Set(KEYWORD_LISTS[key]); });

  const LANG_CONFIG = {
    json: { line: [], block: [], strings: ['"'], keywords: KEYWORD_SETS.json },
    javascript: { line: ['//'], block: [['/*', '*/']], strings: ['"', "'", '`'], keywords: KEYWORD_SETS.javascript },
    typescript: { line: ['//'], block: [['/*', '*/']], strings: ['"', "'", '`'], keywords: KEYWORD_SETS.typescript },
    dart: { line: ['//'], block: [['/*', '*/']], strings: ['"', "'"], keywords: KEYWORD_SETS.dart },
    python: { line: ['#'], block: [], strings: ['"', "'"], keywords: KEYWORD_SETS.python, triple: true },
    ruby: { line: ['#'], block: [], strings: ['"', "'"], keywords: KEYWORD_SETS.ruby },
    sql: { line: ['--'], block: [['/*', '*/']], strings: ["'", '"'], keywords: KEYWORD_SETS.sql, caseInsensitive: true },
    shell: { line: ['#'], block: [], strings: ['"', "'"], keywords: KEYWORD_SETS.shell },
    yaml: { line: ['#'], block: [], strings: ['"', "'"], keywords: KEYWORD_SETS.yaml, keyColon: true },
    css: { line: [], block: [['/*', '*/']], strings: ['"', "'"], keywords: KEYWORD_SETS.css, keyColon: true },
    powershell: { line: ['#'], block: [['<#', '#>']], strings: ['"', "'"], keywords: KEYWORD_SETS.powershell }
  };

  function tokenizeGeneric(text, config) {
    const tokens = [];
    const length = text.length;
    let index = 0;
    let plain = '';
    const flush = () => { if (plain) { tokens.push([null, plain]); plain = ''; } };
    const push = (className, value) => { flush(); tokens.push([className, value]); };

    while (index < length) {
      const character = text[index];
      const lineMark = config.line.find((mark) => text.startsWith(mark, index));
      if (lineMark) {
        let end = text.indexOf('\n', index);
        if (end < 0) end = length;
        push('tok-comment', text.slice(index, end));
        index = end;
        continue;
      }
      const blockMark = config.block.find(([open]) => text.startsWith(open, index));
      if (blockMark) {
        const end = text.indexOf(blockMark[1], index + blockMark[0].length);
        const stop = end < 0 ? length : end + blockMark[1].length;
        push('tok-comment', text.slice(index, stop));
        index = stop;
        continue;
      }
      if (config.strings.includes(character)) {
        if (config.triple && text.startsWith(character.repeat(3), index)) {
          const end = text.indexOf(character.repeat(3), index + 3);
          const stop = end < 0 ? length : end + 3;
          push('tok-string', text.slice(index, stop));
          index = stop;
          continue;
        }
        let end = index + 1;
        while (end < length) {
          if (text[end] === '\\') { end += 2; continue; }
          if (text[end] === character) { end++; break; }
          if (character !== '`' && text[end] === '\n') break;
          end++;
        }
        push('tok-string', text.slice(index, end));
        index = end;
        continue;
      }
      if (/[0-9]/.test(character) || (character === '.' && /[0-9]/.test(text[index + 1] || ''))) {
        let end = index + 1;
        while (end < length && /[0-9a-fA-FxX._eE+-]/.test(text[end])) {
          if ((text[end] === '+' || text[end] === '-') && !/[eE]/.test(text[end - 1])) break;
          end++;
        }
        push('tok-number', text.slice(index, end));
        index = end;
        continue;
      }
      if (/[A-Za-z_$]/.test(character)) {
        let end = index + 1;
        while (end < length && /[A-Za-z0-9_$]/.test(text[end])) end++;
        const word = text.slice(index, end);
        const key = config.caseInsensitive ? word.toLowerCase() : word;
        if (config.keywords.has(key)) push('tok-keyword', word);
        else if (config.keyColon && /^\s*:/.test(text.slice(end, end + 12))) push('tok-key', word);
        else plain += word;
        index = end;
        continue;
      }
      if ('{}[](),:;.='.includes(character)) {
        push('tok-punct', character);
        index++;
        continue;
      }
      plain += character;
      index++;
    }
    flush();
    return tokens;
  }

  function tokenizeJson(text) {
    const tokens = [];
    const pattern = /"(?:\\.|[^"\\])*"|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?|\b(?:true|false|null)\b/g;
    let last = 0;
    let match;
    while ((match = pattern.exec(text)) !== null) {
      if (match.index > last) tokens.push([null, text.slice(last, match.index)]);
      const value = match[0];
      if (value.charAt(0) === '"') {
        tokens.push([/^\s*:/.test(text.slice(pattern.lastIndex)) ? 'tok-key' : 'tok-string', value]);
      } else if (value === 'true' || value === 'false' || value === 'null') {
        tokens.push(['tok-keyword', value]);
      } else {
        tokens.push(['tok-number', value]);
      }
      last = pattern.lastIndex;
    }
    if (last < text.length) tokens.push([null, text.slice(last)]);
    return tokens;
  }

  function tokenizeMarkup(text) {
    const tokens = [];
    const pattern = /<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\?[\s\S]*?\?>|<!DOCTYPE[^>]*>|<\/?[A-Za-z][^>]*?>/g;
    let last = 0;
    let match;
    const push = (className, value) => { if (value) tokens.push([className, value]); };
    while ((match = pattern.exec(text)) !== null) {
      push(null, text.slice(last, match.index));
      const tag = match[0];
      if (tag.startsWith('<!--')) push('tok-comment', tag);
      else if (tag.startsWith('<![CDATA[')) push('tok-string', tag);
      else if (tag.startsWith('<?') || /^<!doctype/i.test(tag)) push('tok-meta', tag);
      else {
        const name = /^<(\/?)([A-Za-z][\w:.-]*)/.exec(tag);
        if (!name) push('tok-tag', tag);
        else {
          push('tok-punct', '<' + name[1]);
          push('tok-tag', name[2]);
          const rest = tag.slice(name[0].length);
          const attributes = /([\w:.-]+)(\s*=\s*)("(?:[^"]*)"|'(?:[^']*)'|[^\s>]+)?/g;
          let attribute;
          let consumed = 0;
          while ((attribute = attributes.exec(rest)) !== null) {
            push(null, rest.slice(consumed, attribute.index));
            push('tok-attr', attribute[1]);
            push('tok-punct', attribute[2]);
            if (attribute[3]) push('tok-string', attribute[3]);
            consumed = attribute.index + attribute[0].length;
          }
          push('tok-punct', rest.slice(consumed));
        }
      }
      last = match.index + tag.length;
    }
    push(null, text.slice(last));
    return tokens;
  }

  function highlight(text, language) {
    if (language === 'json') return tokenizeJson(text);
    if (language === 'markup') return tokenizeMarkup(text);
    const config = LANG_CONFIG[language];
    return config ? tokenizeGeneric(text, config) : null;
  }

  function renderTokens(block, tokens) {
    const fragment = document.createDocumentFragment();
    tokens.forEach(([className, value]) => {
      if (!value) return;
      if (!className) {
        fragment.appendChild(document.createTextNode(value));
        return;
      }
      const span = document.createElement('span');
      span.className = className;
      span.textContent = value;
      fragment.appendChild(span);
    });
    block.textContent = '';
    block.appendChild(fragment);
  }

  function detectLanguage(block) {
    const className = Array.from(block.classList).find((name) => name.indexOf('language-') === 0);
    const raw = (block.dataset.lang || (className ? className.slice(9) : '')).toLowerCase();
    const explicit = LANG_ALIASES[raw] || raw;
    if (explicit === 'plain' || explicit === 'text') return 'plain';
    if (LANG_CONFIG[explicit] || explicit === 'markup') return explicit;

    const source = (block.textContent || '').trim();
    if (!source) return 'plain';
    if (/^[\[{]/.test(source)) {
      try { JSON.parse(source); return 'json'; } catch (error) { /* not JSON */ }
    }
    if (/^(<\?xml|<!doctype|<[a-z][\s\S]*>)/i.test(source)) return 'markup';
    if (/^\s*(select|with|insert|update|delete|create|alter|drop)\b/i.test(source)) return 'sql';
    if (/^#!/.test(source)) return 'shell';
    if (/^\s*(def |class |import |from .+ import)/.test(source)) return 'python';
    if (/^\s*(package:|import 'package:|import "package:|void main|final |const )/.test(source)) return 'dart';
    if (/\b(function|const|let|var|require\()\b/.test(source)) return 'javascript';
    if (/^[\w.-]+:\s/m.test(source) && !/[{};]/.test(source)) return 'yaml';
    return 'plain';
  }

  $$('pre code').forEach((block) => {
    const pre = block.parentElement;
    const source = block.textContent || '';
    if (!source.trim()) return;
    if (source.length <= 200000) {
      const tokens = highlight(source, detectLanguage(block));
      if (tokens) renderTokens(block, tokens);
    }
    if (!pre || pre.querySelector('.copy-btn')) return;
    pre.classList.add('has-copy');
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'copy-btn';
    button.textContent = 'Copy';
    button.setAttribute('aria-label', 'Copy code');
    button.addEventListener('click', async () => {
      if (await copyText(source)) flashLabel(button, 'Copied');
    });
    pre.insertBefore(button, pre.firstChild);
  });
  // ---------------------------------------------------------- find in page
  const findBar = document.getElementById('find-bar');
  const findInput = document.getElementById('find-input');
  const findCount = document.getElementById('find-count');
  const findPrev = document.getElementById('find-prev');
  const findNext = document.getElementById('find-next');
  const findClose = document.getElementById('find-close');
  const searchToggle = document.getElementById('search-toggle');
  const SEARCH_SKIP = '.doc-header, .doc-toc, .find-bar, .copy-btn, .visual-page-head, .attachment-head, .attachment-actions, .diff-table thead, script, style, noscript';
  let searchHits = [];
  let searchIndex = -1;
  let searchTimer = null;

  function clearSearchHighlights() {
    $$('mark.search-hit').forEach((mark) => {
      const parent = mark.parentNode;
      if (!parent) return;
      parent.replaceChild(document.createTextNode(mark.textContent || ''), mark);
      parent.normalize();
    });
    $$('.svg-search-hit').forEach((element) => element.classList.remove('svg-search-hit', 'search-current'));
    $$('.search-current').forEach((element) => element.classList.remove('search-current'));
    searchHits = [];
    searchIndex = -1;
  }

  function highlightTextNodes(root, query) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        if (!node.nodeValue || node.nodeValue.toLowerCase().indexOf(query) === -1) {
          return NodeFilter.FILTER_REJECT;
        }
        const parent = node.parentElement;
        if (!parent || parent.closest(SEARCH_SKIP)) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    nodes.forEach((node) => {
      const text = node.nodeValue || '';
      const lower = text.toLowerCase();
      const fragment = document.createDocumentFragment();
      let start = 0;
      let found;
      while ((found = lower.indexOf(query, start)) !== -1) {
        if (found > start) fragment.appendChild(document.createTextNode(text.slice(start, found)));
        const mark = document.createElement('mark');
        mark.className = 'search-hit';
        mark.textContent = text.slice(found, found + query.length);
        fragment.appendChild(mark);
        searchHits.push(mark);
        start = found + query.length;
      }
      if (start < text.length) fragment.appendChild(document.createTextNode(text.slice(start)));
      if (node.parentNode) node.parentNode.replaceChild(fragment, node);
    });
  }

  function highlightSvg(root, query) {
    $$('svg text', root).forEach((element) => {
      if ((element.textContent || '').toLowerCase().indexOf(query) !== -1) {
        element.classList.add('svg-search-hit');
        searchHits.push(element);
      }
    });
  }

  function updateFindCount() {
    if (!findCount) return;
    if (!searchHits.length) {
      findCount.textContent = findInput && findInput.value.trim().length >= 2 ? '0/0' : '';
      return;
    }
    findCount.textContent = (searchIndex + 1) + '/' + searchHits.length;
  }

  function focusSearchHit(index) {
    if (!searchHits.length) {
      updateFindCount();
      return;
    }
    searchIndex = (index + searchHits.length) % searchHits.length;
    $$('.search-current').forEach((element) => element.classList.remove('search-current'));
    const hit = searchHits[searchIndex];
    hit.classList.add('search-current');
    const details = hit.closest ? hit.closest('details') : null;
    if (details && !details.open) details.open = true;
    if (hit.scrollIntoView) {
      hit.scrollIntoView({ behavior: reduceMotion ? 'auto' : 'smooth', block: 'center', inline: 'nearest' });
    }
    updateFindCount();
  }

  function runSearch(value) {
    clearSearchHighlights();
    const query = value.trim().toLowerCase();
    if (query.length < 2) {
      updateFindCount();
      return;
    }
    if (content) {
      highlightTextNodes(content, query);
      highlightSvg(content, query);
    }
    if (searchHits.length) focusSearchHit(0);
    else updateFindCount();
  }

  function openFind() {
    if (!findBar) return;
    findBar.hidden = false;
    if (searchToggle) searchToggle.setAttribute('aria-expanded', 'true');
    if (findInput) {
      requestAnimationFrame(() => findInput.focus());
      if (findInput.value.trim().length >= 2) runSearch(findInput.value);
    }
  }

  function closeFind() {
    if (!findBar) return;
    findBar.hidden = true;
    if (searchToggle) searchToggle.setAttribute('aria-expanded', 'false');
    clearSearchHighlights();
    if (findInput) findInput.value = '';
    updateFindCount();
  }

  if (searchToggle) {
    searchToggle.addEventListener('click', () => {
      if (findBar && findBar.hidden) openFind(); else closeFind();
    });
  }
  if (findClose) findClose.addEventListener('click', closeFind);
  if (findPrev) findPrev.addEventListener('click', () => focusSearchHit(searchIndex - 1));
  if (findNext) findNext.addEventListener('click', () => focusSearchHit(searchIndex + 1));
  if (findInput) {
    findInput.addEventListener('input', () => {
      clearTimeout(searchTimer);
      const value = findInput.value;
      searchTimer = setTimeout(() => runSearch(value), value.trim().length ? 180 : 0);
    });
    findInput.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') {
        event.preventDefault();
        focusSearchHit(searchIndex + (event.shiftKey ? -1 : 1));
      } else if (event.key === 'Escape') {
        event.preventDefault();
        closeFind();
      }
    });
  }
  document.addEventListener('keydown', (event) => {
    const key = event.key.toLowerCase();
    if ((event.ctrlKey || event.metaKey) && !event.altKey && key === 'f') {
      event.preventDefault();
      openFind();
    } else if (event.key === 'F3') {
      event.preventDefault();
      focusSearchHit(searchIndex + (event.shiftKey ? -1 : 1));
    } else if (event.key === 'Escape' && !lightboxOpen && findBar && !findBar.hidden) {
      closeFind();
    }
  });
  // ------------------------------------------------------------- visual lightbox
  const lightbox = document.getElementById('lightbox');
  const lightboxStage = document.getElementById('lightbox-stage');
  const lightboxCanvas = document.getElementById('lightbox-canvas');
  const lightboxLabel = document.getElementById('lightbox-label');
  const lightboxClose = document.getElementById('lightbox-close');
  const zoomLevel = document.getElementById('zoom-level');
  const view = { scale: 1, fit: 1, x: 0, y: 0, width: 0, height: 0, svg: null, card: null };
  const pointers = new Map();
  let drag = null;
  let pinch = null;
  let lastFocus = null;

  function applyView() {
    view.scale = Math.min(8, Math.max(0.05, view.scale));
    if (lightboxCanvas) {
      lightboxCanvas.style.transform = 'translate(' + view.x + 'px,' + view.y + 'px) scale(' + view.scale + ')';
    }
    if (zoomLevel) zoomLevel.textContent = Math.round(view.scale * 100) + '%';
  }

  function fitLightbox() {
    if (!lightboxStage) return;
    const rect = lightboxStage.getBoundingClientRect();
    const fit = Math.min(
      (rect.width - 64) / Math.max(1, view.width),
      (rect.height - 64) / Math.max(1, view.height)
    );
    view.fit = Math.max(0.05, Math.min(fit || 1, 2));
    view.scale = view.fit;
    view.x = 0;
    view.y = 0;
    applyView();
  }

  function zoomAt(factor, clientX, clientY) {
    if (!lightboxStage) return;
    const rect = lightboxStage.getBoundingClientRect();
    const px = clientX - (rect.left + rect.width / 2);
    const py = clientY - (rect.top + rect.height / 2);
    const next = Math.min(8, Math.max(0.05, view.scale * factor));
    const factorActual = next / view.scale;
    view.x -= (px - view.x) * (factorActual - 1);
    view.y -= (py - view.y) * (factorActual - 1);
    view.scale = next;
    applyView();
  }

  function zoomCenter(factor) {
    if (!lightboxStage) return;
    const rect = lightboxStage.getBoundingClientRect();
    zoomAt(factor, rect.left + rect.width / 2, rect.top + rect.height / 2);
  }

  function openLightbox(card) {
    if (!lightbox || !lightboxCanvas || !card) return;
    const source = card.querySelector('.visual-frame svg');
    if (!source) return;
    const clone = source.cloneNode(true);
    $$('.svg-search-hit, .search-current', clone).forEach((element) => {
      element.classList.remove('svg-search-hit', 'search-current');
    });
    const box = (source.getAttribute('viewBox') || '').split(/\s+/).map(Number);
    const width = box.length === 4 && box[2] > 0 ? box[2] : 612;
    const height = box.length === 4 && box[3] > 0 ? box[3] : 792;
    clone.setAttribute('width', String(width));
    clone.setAttribute('height', String(height));
    clone.style.maxWidth = 'none';
    clone.style.display = 'block';
    lightboxCanvas.replaceChildren(clone);
    view.width = width;
    view.height = height;
    view.svg = clone;
    view.card = card;
    if (lightboxLabel) {
      lightboxLabel.textContent = (card.dataset.pageLabel || 'Visual page') + ' · ' +
        Math.round(width) + '×' + Math.round(height);
    }
    lastFocus = document.activeElement;
    lightbox.hidden = false;
    lightboxOpen = true;
    document.body.classList.add('lightbox-open');
    requestAnimationFrame(() => {
      fitLightbox();
      if (lightboxClose) lightboxClose.focus();
    });
  }

  function closeLightbox() {
    if (!lightbox || !lightboxOpen) return;
    lightbox.hidden = true;
    lightboxOpen = false;
    document.body.classList.remove('lightbox-open');
    if (lightboxCanvas) lightboxCanvas.replaceChildren();
    view.svg = null;
    view.card = null;
    pointers.clear();
    drag = null;
    pinch = null;
    if (lightboxStage) lightboxStage.classList.remove('dragging');
    if (lastFocus && lastFocus.focus) lastFocus.focus();
  }

  function downloadBlob(blob, filename) {
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement('a');
    anchor.href = url;
    anchor.download = filename;
    document.body.appendChild(anchor);
    anchor.click();
    anchor.remove();
    setTimeout(() => URL.revokeObjectURL(url), 4000);
  }

  function serializedSvg(svg) {
    const clone = svg.cloneNode(true);
    clone.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
    return '<?xml version="1.0" encoding="UTF-8"?>\n' + new XMLSerializer().serializeToString(clone);
  }

  function downloadSvgSource(svg, filename) {
    downloadBlob(new Blob([serializedSvg(svg)], { type: 'image/svg+xml;charset=utf-8' }), filename);
  }

  function downloadPng(svg, filename) {
    const source = serializedSvg(svg);
    const image = new Image();
    image.onload = () => {
      const width = image.width || 1;
      const height = image.height || 1;
      const ratio = Math.min(2, 4096 / Math.max(width, height));
      const canvas = document.createElement('canvas');
      canvas.width = Math.max(1, Math.round(width * ratio));
      canvas.height = Math.max(1, Math.round(height * ratio));
      const context = canvas.getContext('2d');
      if (!context) return;
      context.fillStyle = getComputedStyle(document.body).backgroundColor || '#ffffff';
      context.fillRect(0, 0, canvas.width, canvas.height);
      context.drawImage(image, 0, 0, canvas.width, canvas.height);
      canvas.toBlob((blob) => { if (blob) downloadBlob(blob, filename); }, 'image/png');
    };
    image.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(source);
  }

  function pageFile(card, extension) {
    const raw = card && card.dataset.pageLabel ? card.dataset.pageLabel : 'page';
    const label = raw.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
    return (label || 'page') + '.' + extension;
  }

  $$('.visual-page-card').forEach((card) => {
    const frame = card.querySelector('.visual-frame');
    if (frame) {
      const open = () => openLightbox(card);
      frame.addEventListener('click', open);
      frame.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          open();
        }
      });
    }
    const svgButton = card.querySelector('[data-visual-svg]');
    const pngButton = card.querySelector('[data-visual-png]');
    if (svgButton) {
      svgButton.addEventListener('click', () => {
        const svg = card.querySelector('svg');
        if (svg) downloadSvgSource(svg, pageFile(card, 'svg'));
      });
    }
    if (pngButton) {
      pngButton.addEventListener('click', () => {
        const svg = card.querySelector('svg');
        if (svg) downloadPng(svg, pageFile(card, 'png'));
      });
    }
  });

  const zoomIn = document.getElementById('zoom-in');
  const zoomOut = document.getElementById('zoom-out');
  const zoomReset = document.getElementById('zoom-reset');
  const lightboxSvg = document.getElementById('lightbox-svg');
  const lightboxPng = document.getElementById('lightbox-png');
  if (zoomIn) zoomIn.addEventListener('click', () => zoomCenter(1.25));
  if (zoomOut) zoomOut.addEventListener('click', () => zoomCenter(1 / 1.25));
  if (zoomReset) zoomReset.addEventListener('click', fitLightbox);
  if (lightboxClose) lightboxClose.addEventListener('click', closeLightbox);
  if (lightboxSvg) {
    lightboxSvg.addEventListener('click', () => {
      if (view.svg) downloadSvgSource(view.svg, pageFile(view.card, 'svg'));
    });
  }
  if (lightboxPng) {
    lightboxPng.addEventListener('click', () => {
      if (view.svg) downloadPng(view.svg, pageFile(view.card, 'png'));
    });
  }
  if (lightboxStage) {
    lightboxStage.addEventListener('pointerdown', (event) => {
      if (event.target.closest && event.target.closest('button')) return;
      pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
      if (lightboxStage.setPointerCapture) lightboxStage.setPointerCapture(event.pointerId);
      if (pointers.size === 1) {
        drag = {
          id: event.pointerId,
          x: event.clientX,
          y: event.clientY,
          startX: view.x,
          startY: view.y
        };
      } else if (pointers.size === 2) {
        drag = null;
        const values = Array.from(pointers.values());
        pinch = {
          distance: Math.hypot(values[0].x - values[1].x, values[0].y - values[1].y),
          scale: view.scale,
          x: view.x,
          y: view.y,
          cx: (values[0].x + values[1].x) / 2,
          cy: (values[0].y + values[1].y) / 2
        };
      }
      lightboxStage.classList.add('dragging');
    });
    lightboxStage.addEventListener('pointermove', (event) => {
      if (!pointers.has(event.pointerId)) return;
      pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
      if (pointers.size === 2 && pinch) {
        const values = Array.from(pointers.values());
        const distance = Math.hypot(values[0].x - values[1].x, values[0].y - values[1].y);
        const factor = distance / (pinch.distance || 1);
        const next = Math.min(8, Math.max(0.05, pinch.scale * factor));
        const ratio = next / pinch.scale;
        const rect = lightboxStage.getBoundingClientRect();
        const centerX = rect.left + rect.width / 2;
        const centerY = rect.top + rect.height / 2;
        const cx = (values[0].x + values[1].x) / 2;
        const cy = (values[0].y + values[1].y) / 2;
        view.scale = next;
        view.x = (cx - centerX) - ((pinch.cx - centerX) - pinch.x) * ratio;
        view.y = (cy - centerY) - ((pinch.cy - centerY) - pinch.y) * ratio;
        applyView();
        return;
      }
      if (drag && drag.id === event.pointerId) {
        view.x = drag.startX + (event.clientX - drag.x);
        view.y = drag.startY + (event.clientY - drag.y);
        applyView();
      }
    });
    const endPointer = (event) => {
      pointers.delete(event.pointerId);
      if (pointers.size < 2) pinch = null;
      if (pointers.size === 0) drag = null;
      if (pointers.size === 1) {
        const entry = Array.from(pointers.entries())[0];
        drag = {
          id: entry[0],
          x: entry[1].x,
          y: entry[1].y,
          startX: view.x,
          startY: view.y
        };
      } else if (pointers.size === 0) {
        lightboxStage.classList.remove('dragging');
      }
    };
    lightboxStage.addEventListener('pointerup', endPointer);
    lightboxStage.addEventListener('pointercancel', endPointer);
    lightboxStage.addEventListener('wheel', (event) => {
      if (!lightboxOpen) return;
      event.preventDefault();
      zoomAt(Math.exp(-event.deltaY * 0.0015), event.clientX, event.clientY);
    }, { passive: false });
    lightboxStage.addEventListener('click', (event) => {
      if (event.target === lightboxStage) closeLightbox();
    });
  }
  if (lightbox) {
    lightbox.addEventListener('click', (event) => {
      if (event.target === lightbox) closeLightbox();
    });
  }
  document.addEventListener('keydown', (event) => {
    if (!lightboxOpen) return;
    if (event.key === 'Escape') {
      event.preventDefault();
      closeLightbox();
    } else if (event.key === '+' || event.key === '=') {
      event.preventDefault();
      zoomCenter(1.2);
    } else if (event.key === '-') {
      event.preventDefault();
      zoomCenter(1 / 1.2);
    } else if (event.key === '0') {
      event.preventDefault();
      fitLightbox();
    } else if (event.key.indexOf('Arrow') === 0) {
      event.preventDefault();
      const step = event.shiftKey ? 120 : 40;
      if (event.key === 'ArrowLeft') view.x -= step;
      if (event.key === 'ArrowRight') view.x += step;
      if (event.key === 'ArrowUp') view.y -= step;
      if (event.key === 'ArrowDown') view.y += step;
      applyView();
    }
  });

  // --------------------------------------------------------------- print & init
  let printSnapshot = null;
  window.addEventListener('beforeprint', () => {
    printSnapshot = $$('details:not([open])');
    printSnapshot.forEach((details) => { details.open = true; });
  });
  window.addEventListener('afterprint', () => {
    if (printSnapshot) printSnapshot.forEach((details) => { details.open = false; });
    printSnapshot = null;
  });

  const btt = document.getElementById('back-to-top');
  function updateBackToTop() {
    if (btt) btt.classList.toggle('visible', window.scrollY > 400);
  }
  if (btt) {
    btt.addEventListener('click', () => {
      window.scrollTo({ top: 0, behavior: reduceMotion ? 'auto' : 'smooth' });
    });
  }

  buildToc();
  updateActiveToc();
  updateBackToTop();
  let scrollFrame = false;
  window.addEventListener('scroll', () => {
    if (scrollFrame) return;
    scrollFrame = true;
    requestAnimationFrame(() => {
      updateActiveToc();
      updateBackToTop();
      scrollFrame = false;
    });
  }, { passive: true });
  const desktopQuery = window.matchMedia('(min-width: 1024px)');
  if (desktopQuery.addEventListener) {
    desktopQuery.addEventListener('change', (event) => {
      if (event.matches) closeToc();
    });
  }
})();
''';
}
