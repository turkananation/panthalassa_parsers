import 'dart:convert';

import 'viewer_document.dart';

/// Renders a [ViewerDocument] as a single self-contained HTML file.
///
/// The output embeds CSS, JavaScript, and image assets directly, so it can be
/// opened from `file://` without a web server. All document text is escaped;
/// [ViewerHtmlSection] is the only path for pre-rendered HTML.
final class ViewerHtmlRenderer {
  const ViewerHtmlRenderer();

  String render(ViewerDocument document) {
    final out = StringBuffer()
      ..writeln('<!doctype html>')
      ..writeln('<html lang="en">')
      ..writeln('<head>')
      ..writeln('<meta charset="utf-8">')
      ..writeln(
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
      )
      ..writeln('<meta name="generator" content="panthalassa">')
      ..writeln('<title>${_escape(document.title)}</title>')
      ..writeln('<style>$_style</style>')
      ..writeln('</head>')
      ..writeln('<body>')
      ..writeln('<header class="app-header">')
      ..writeln('<div class="titles">')
      ..writeln('<h1>${_escape(document.title)}</h1>');
    if (document.subtitle != null && document.subtitle!.isNotEmpty) {
      out.writeln('<p class="subtitle">${_escape(document.subtitle!)}</p>');
    }
    out
      ..writeln('</div>')
      ..writeln(
        '<span class="format-badge">${_escape(document.formatLabel)}</span>',
      )
      ..writeln('</header>')
      ..writeln('<main class="layout">');

    if (document.facts.isNotEmpty) {
      out
        ..writeln('<aside class="sidebar">')
        ..writeln('<section class="panel">')
        ..writeln('<div class="panel-head"><h2>Details</h2></div>')
        ..writeln('<dl class="facts">');
      for (final entry in document.facts.entries) {
        out
          ..writeln('<dt>${_escape(entry.key)}</dt>')
          ..writeln('<dd>${_escape(entry.value)}</dd>');
      }
      out
        ..writeln('</dl>')
        ..writeln('</section>')
        ..writeln('</aside>');
    }

    out.writeln('<div class="content">');
    for (final notice in document.notices) {
      out.writeln(_notice(notice));
    }
    var tableIndex = 0;
    for (final section in document.sections) {
      switch (section) {
        case ViewerTableSection():
          _writeTable(out, section, tableIndex++);
        case ViewerImageSection():
          _writeImage(out, document, section);
        case ViewerTextSection():
          _writeText(out, section);
        case ViewerHtmlSection():
          out.writeln('<section class="panel">');
          _writeSectionHeader(out, section.title);
          out
            ..writeln('<div class="panel-body rendered-document">')
            ..writeln(section.html)
            ..writeln('</div>')
            ..writeln('</section>');
      }
    }
    out
      ..writeln('</div>')
      ..writeln('</main>');
    if (document.footer != null && document.footer!.isNotEmpty) {
      out.writeln(
        '<footer class="footer">${_escape(document.footer!)}</footer>',
      );
    }
    out
      ..writeln(
        '<div id="viewer-lightbox" class="lightbox" hidden>'
        '<img id="viewer-lightbox-image" alt=""></div>',
      )
      ..writeln('<script>$_script</script>')
      ..writeln('</body>')
      ..writeln('</html>');
    return out.toString();
  }

  void _writeSectionHeader(StringBuffer out, String? title) {
    if (title == null || title.isEmpty) return;
    out.writeln('<div class="panel-head"><h2>${_escape(title)}</h2></div>');
  }

  void _writeTable(StringBuffer out, ViewerTableSection section, int index) {
    final id = 'viewer-table-$index';
    var columnCount = section.columns.length;
    if (columnCount == 0 && section.rows.isNotEmpty) {
      columnCount = section.rows.first.length;
    }
    final total = section.totalRowCount ?? section.rows.length;
    out
      ..writeln('<section class="panel table-panel">')
      ..writeln('<div class="panel-head">');
    if (section.title != null && section.title!.isNotEmpty) {
      out.writeln('<h2>${_escape(section.title!)}</h2>');
    }
    if (section.filterable) {
      out.writeln(
        '<div class="table-tools">'
        '<input type="search" placeholder="Filter rows…" '
        'aria-label="Filter table rows" data-filter="$id">'
        '<span class="row-count" data-count-for="$id">'
        '$total rows</span>'
        '</div>',
      );
    }
    out.writeln('</div>');

    if (section.rows.isEmpty) {
      out
        ..writeln('<p class="empty">No rows to display.</p>')
        ..writeln('</section>');
      return;
    }

    out
      ..writeln('<div class="table-scroll">')
      ..writeln(
        '<table id="$id" data-filterable="true" data-total="$total" '
        'data-truncated="${section.truncated}">',
      )
      ..writeln('<thead><tr>');
    for (var i = 0; i < columnCount; i++) {
      final name = i < section.columns.length
          ? section.columns[i]
          : 'Column ${i + 1}';
      out.writeln('<th scope="col">${_escape(name)}</th>');
    }
    out
      ..writeln('</tr></thead>')
      ..writeln('<tbody>');
    for (final row in section.rows) {
      out.writeln('<tr>');
      for (var i = 0; i < columnCount; i++) {
        out.writeln('<td>${_escape(i < row.length ? row[i] : '')}</td>');
      }
      out.writeln('</tr>');
    }
    out
      ..writeln('</tbody>')
      ..writeln('</table>')
      ..writeln('</div>');
    if (section.truncated) {
      out.writeln(
        '<p class="hint">Showing the first ${section.rows.length} of '
        '$total rows. Re-run with <code>--all-rows</code> to render every row.'
        '</p>',
      );
    }
    if (section.caption != null && section.caption!.isNotEmpty) {
      out.writeln(
        '<p class="section-caption">${_escape(section.caption!)}</p>',
      );
    }
    out.writeln('</section>');
  }

  void _writeImage(
    StringBuffer out,
    ViewerDocument document,
    ViewerImageSection section,
  ) {
    final asset = document.assets[section.assetName];
    out.writeln('<section class="panel image-panel">');
    out.writeln('<div class="panel-head">');
    if (section.title != null && section.title!.isNotEmpty) {
      out.writeln('<h2>${_escape(section.title!)}</h2>');
    }
    if (section.width != null && section.height != null) {
      out.writeln(
        '<span class="image-meta">${section.width} × ${section.height} px</span>',
      );
    }
    out.writeln('</div>');
    if (asset == null) {
      out
        ..writeln('<p class="empty">Image asset is missing.</p>')
        ..writeln('</section>');
      return;
    }
    final dataUri =
        'data:${asset.mimeType};base64,${base64Encode(asset.bytes)}';
    final alt = section.alt ?? section.title ?? asset.name;
    out
      ..writeln('<figure>')
      ..write('<img src="$dataUri" alt="${_escape(alt)}"')
      ..write(' loading="lazy"');
    if (section.width != null) out.write(' width="${section.width}"');
    if (section.height != null) out.write(' height="${section.height}"');
    if (section.zoomable) out.write(' data-zoom="true"');
    out.writeln('>');
    if (section.caption != null && section.caption!.isNotEmpty) {
      out.writeln('<figcaption>${_escape(section.caption!)}</figcaption>');
    }
    out
      ..writeln('</figure>')
      ..writeln('</section>');
  }

  void _writeText(StringBuffer out, ViewerTextSection section) {
    out.writeln('<section class="panel">');
    _writeSectionHeader(out, section.title);
    out
      ..writeln(
        '<pre class="text-block${section.monospace ? ' mono' : ''}">'
        '${_escape(section.text)}</pre>',
      )
      ..writeln('</section>');
  }

  String _notice(ViewerNotice notice) {
    final level = switch (notice.level) {
      ViewerNoticeLevel.info => 'info',
      ViewerNoticeLevel.warning => 'warning',
      ViewerNoticeLevel.error => 'error',
    };
    return '<div class="notice notice-$level">${_escape(notice.message)}</div>';
  }
}

String _escape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

const String _style = r'''
:root {
  color-scheme: light dark;
  --bg: #eef2f6;
  --panel: #ffffff;
  --panel-2: #f7f9fc;
  --text: #17202a;
  --muted: #5b6775;
  --line: #d7e0e8;
  --accent: #0f6b8f;
  --accent-soft: #e7f3f8;
  --warn-bg: #fff8e1;
  --warn-line: #d9a83b;
  --err-bg: #fdecec;
  --err-line: #cc5f5f;
  --info-bg: #eef7fb;
  --info-line: #8cc5dc;
  --shadow: 0 1px 2px rgba(15, 23, 42, .05);
  --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0e151c;
    --panel: #151f29;
    --panel-2: #1b2733;
    --text: #e6edf3;
    --muted: #9aa8b6;
    --line: #2a3a49;
    --accent: #5cc8e8;
    --accent-soft: #163442;
    --warn-bg: #3a2f13;
    --warn-line: #c79a36;
    --err-bg: #3a1d1d;
    --err-line: #d47777;
    --info-bg: #122b36;
    --info-line: #3b829e;
    --shadow: 0 1px 2px rgba(0, 0, 0, .25);
  }
}
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }
body {
  font: 15px/1.5 system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI",
    Roboto, "Helvetica Neue", Arial, sans-serif;
  background: var(--bg);
  color: var(--text);
  -webkit-font-smoothing: antialiased;
}
.app-header {
  position: sticky;
  top: 0;
  z-index: 20;
  display: flex;
  align-items: center;
  gap: 16px;
  padding: 14px 22px;
  background: var(--panel);
  border-bottom: 1px solid var(--line);
  box-shadow: var(--shadow);
}
.titles { min-width: 0; flex: 1; }
.app-header h1 {
  margin: 0;
  font-size: 19px;
  line-height: 1.25;
  overflow-wrap: anywhere;
}
.subtitle {
  margin: 3px 0 0;
  color: var(--muted);
  font-size: 13px;
}
.format-badge {
  flex: none;
  border: 1px solid var(--line);
  background: var(--accent-soft);
  color: var(--accent);
  border-radius: 999px;
  padding: 4px 10px;
  font-size: 12px;
  font-weight: 600;
  letter-spacing: .02em;
}
.layout {
  display: grid;
  grid-template-columns: minmax(230px, 310px) minmax(0, 1fr);
  gap: 18px;
  align-items: start;
  max-width: 1560px;
  margin: 0 auto;
  padding: 18px 22px 40px;
}
.sidebar {
  position: sticky;
  top: 78px;
  max-height: calc(100vh - 96px);
  overflow: auto;
}
.content { min-width: 0; display: flex; flex-direction: column; gap: 16px; }
.panel {
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 10px;
  box-shadow: var(--shadow);
  overflow: hidden;
}
.panel-head {
  display: flex;
  align-items: center;
  gap: 12px;
  flex-wrap: wrap;
  padding: 11px 16px;
  border-bottom: 1px solid var(--line);
  background: var(--panel-2);
}
.panel-head h2 { margin: 0; font-size: 14px; letter-spacing: .01em; }
.panel-body { padding: 16px; }
.facts {
  display: grid;
  grid-template-columns: minmax(88px, 40%) minmax(0, 1fr);
  gap: 7px 12px;
  margin: 0;
  padding: 14px 16px;
}
.facts dt {
  color: var(--muted);
  font-size: 11px;
  letter-spacing: .05em;
  text-transform: uppercase;
  padding-top: 2px;
}
.facts dd { margin: 0; overflow-wrap: anywhere; white-space: pre-wrap; }
.table-tools { display: flex; align-items: center; gap: 10px; margin-left: auto; }
input[type="search"] {
  width: min(240px, 46vw);
  border: 1px solid var(--line);
  background: var(--panel);
  color: var(--text);
  border-radius: 7px;
  padding: 7px 9px;
  font: inherit;
  font-size: 13px;
}
input[type="search"]:focus {
  outline: 2px solid var(--accent);
  outline-offset: 1px;
}
.row-count, .image-meta {
  color: var(--muted);
  font-size: 12px;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}
.table-scroll { max-height: 72vh; overflow: auto; }
table {
  width: 100%;
  border-collapse: separate;
  border-spacing: 0;
  font-variant-numeric: tabular-nums;
}
thead th {
  position: sticky;
  top: 0;
  z-index: 2;
  background: var(--panel-2);
  border-bottom: 1px solid var(--line);
  color: var(--muted);
  font-size: 11px;
  letter-spacing: .05em;
  text-align: left;
  text-transform: uppercase;
  padding: 9px 12px;
  white-space: nowrap;
}
tbody td {
  border-bottom: 1px solid var(--line);
  padding: 8px 12px;
  vertical-align: top;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
}
tbody tr:nth-child(even) { background: var(--panel-2); }
tbody tr:hover { background: var(--accent-soft); }
tbody tr[hidden] { display: none; }
.empty { margin: 0; padding: 18px 16px; color: var(--muted); }
.hint {
  margin: 0;
  padding: 10px 16px 12px;
  color: var(--muted);
  font-size: 12px;
  border-top: 1px solid var(--line);
}
.section-caption {
  margin: 0;
  padding: 10px 16px 14px;
  color: var(--muted);
  font-size: 13px;
}
.image-panel figure { margin: 0; padding: 16px; text-align: center; }
.image-panel img {
  display: block;
  max-width: 100%;
  height: auto;
  margin: 0 auto;
  border-radius: 6px;
  background: var(--panel-2);
  cursor: zoom-in;
}
.image-panel figcaption {
  margin-top: 9px;
  color: var(--muted);
  font-size: 12px;
}
.text-block {
  margin: 0;
  padding: 16px;
  overflow: auto;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  font: 13px/1.55 var(--mono);
  background: var(--panel);
}
.text-block.mono { font-family: var(--mono); }
.rendered-document { overflow-wrap: anywhere; }
.rendered-document h1, .rendered-document h2, .rendered-document h3,
.rendered-document h4, .rendered-document h5, .rendered-document h6 {
  margin: 1.1em 0 .45em;
  line-height: 1.3;
}
.rendered-document h1:first-child, .rendered-document h2:first-child,
.rendered-document h3:first-child { margin-top: 0; }
.rendered-document p { margin: .65em 0; }
.rendered-document table {
  display: block;
  overflow: auto;
  width: max-content;
  min-width: 100%;
  margin: 1em 0;
  border-collapse: collapse;
}
.rendered-document th, .rendered-document td {
  border: 1px solid var(--line);
  padding: 6px 9px;
  text-align: left;
  vertical-align: top;
}
.rendered-document dt { font-weight: 600; }
.rendered-document dd { margin: 0 0 .5em 1.25em; }
.rendered-document code, .rendered-document pre {
  font-family: var(--mono);
  font-size: .92em;
}
.rendered-document pre {
  background: var(--panel-2);
  border: 1px solid var(--line);
  border-radius: 8px;
  padding: 12px;
  overflow: auto;
}
.notice {
  border: 1px solid;
  border-radius: 8px;
  padding: 10px 12px;
  font-size: 13px;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
}
.notice-info { background: var(--info-bg); border-color: var(--info-line); }
.notice-warning { background: var(--warn-bg); border-color: var(--warn-line); }
.notice-error { background: var(--err-bg); border-color: var(--err-line); }
.footer {
  padding: 0 22px 30px;
  color: var(--muted);
  font-size: 12px;
  text-align: center;
}
.lightbox {
  position: fixed;
  inset: 0;
  z-index: 100;
  display: grid;
  place-items: center;
  padding: 22px;
  background: rgba(5, 10, 15, .92);
  cursor: zoom-out;
}
.lightbox[hidden] { display: none; }
.lightbox img {
  max-width: 100%;
  max-height: 100%;
  border-radius: 4px;
  background: #000;
}
@media (max-width: 900px) {
  .layout { grid-template-columns: 1fr; padding: 14px; }
  .sidebar { position: static; max-height: none; }
  .app-header { padding: 12px 14px; }
}
@media print {
  .app-header { position: static; box-shadow: none; }
  .sidebar, .table-tools, .hint { display: none; }
  .layout { display: block; padding: 0; }
  .panel { break-inside: avoid; box-shadow: none; }
  .table-scroll { max-height: none; overflow: visible; }
  thead th { position: static; }
}
''';

const String _script = r'''
(function () {
  document.querySelectorAll('table[data-filterable="true"]').forEach(function (table) {
    var input = document.querySelector('input[data-filter="' + table.id + '"]');
    if (!input) return;
    var count = document.querySelector('[data-count-for="' + table.id + '"]');
    var rows = Array.prototype.slice.call(table.tBodies[0].rows);
    var total = table.getAttribute('data-total') || String(rows.length);
    var truncated = table.getAttribute('data-truncated') === 'true';
    var timer = null;
    function update() {
      var query = input.value.trim().toLowerCase();
      var visible = 0;
      rows.forEach(function (row) {
        var match = !query || row.textContent.toLowerCase().indexOf(query) !== -1;
        row.hidden = !match;
        if (match) visible++;
      });
      if (count) {
        var value = truncated ? visible + ' of ' + total : String(visible);
        count.textContent = value + (visible === 1 ? ' row' : ' rows');
      }
    }
    input.addEventListener('input', function () {
      if (timer) clearTimeout(timer);
      timer = setTimeout(update, 80);
    });
    update();
  });

  var lightbox = document.getElementById('viewer-lightbox');
  var lightboxImage = document.getElementById('viewer-lightbox-image');
  if (!lightbox || !lightboxImage) return;
  function close() {
    lightbox.hidden = true;
    lightboxImage.src = '';
  }
  document.querySelectorAll('img[data-zoom="true"]').forEach(function (image) {
    image.addEventListener('click', function () {
      lightboxImage.src = image.src;
      lightboxImage.alt = image.alt || '';
      lightbox.hidden = false;
    });
  });
  lightbox.addEventListener('click', close);
  document.addEventListener('keydown', function (event) {
    if (event.key === 'Escape') close();
  });
})();
''';
