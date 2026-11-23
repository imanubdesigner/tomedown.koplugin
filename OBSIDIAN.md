# Obsidian guide: your notes inside the vault

A visual guide to how exported books, reading progress, and index tables look and function inside an Obsidian vault.

For full technical specifications of the generated Markdown, YAML properties, and index tables, see the [File format & specifications](docs/file-format.md) page.

## The book note in Obsidian

Every exported book note is a self-contained Markdown file ready for Obsidian.

<div class="screenshot-placeholder is-wide" role="region" aria-label="Screenshot placeholder: docs-25-book-note-modules-obsidian.webp">
  <div class="sp-top">
    <div class="sp-meta">
      <span class="sp-badge">Obsidian Vault</span>
      <code class="sp-filename">docs-25-book-note-modules-obsidian.webp</code>
    </div>
    <button type="button" class="placeholder-copy-btn" data-copy-filename="docs-25-book-note-modules-obsidian.webp" aria-label="Copy filename docs-25-book-note-modules-obsidian.webp">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
      <span>Copy filename</span>
    </button>
  </div>
  <div class="sp-screen">
    <p class="sp-title">Book note in Obsidian: YAML Properties, cover, dashboard, synopsis &amp; quotes</p>
    <p class="sp-desc">Inquadra una nota libro aperta in Obsidian (Reading View) mostrando le Properties YAML, la copertina, la <em>Reading dashboard</em>, la <em>Book synopsis</em> richiudibile, i tag cliccabili, il callout <em>Overview</em> e lo showcase <em>★ Special highlights</em>.</p>
    <span class="sp-hint">Formato: WebP (q90–q95) · Proporzioni: 16:10 (finestra desktop Obsidian / MarkText)</span>
  </div>
</div>

- **Reading View vs. Live Preview**: in Reading View, YAML frontmatter renders cleanly as Obsidian Properties, and internal Tomedown hashes stay out of sight.
- **Embedded Covers**: when *Settings → Notes & highlights → Book page → Book cover* is enabled, covers are stored in your vault folder (default `covers/`, configurable in *Settings → Export → File names & folders*) and render natively in Obsidian (requires Obsidian 1.8.1 or newer).
- **Wikilinks**: internal references connect book titles directly across your notes.

## Personal notes with *Keep my notes*

Enable **Tomedown → Settings → My notes → Keep my notes for all books** (or per book in **Tomedown → Current book → Keep my notes in this book**) to turn exported files into shared workspaces.

<div class="screenshot-placeholder is-wide" role="region" aria-label="Screenshot placeholder: docs-28-keep-my-notes-obsidian.webp">
  <div class="sp-top">
    <div class="sp-meta">
      <span class="sp-badge">Obsidian Vault</span>
      <code class="sp-filename">docs-28-keep-my-notes-obsidian.webp</code>
    </div>
    <button type="button" class="placeholder-copy-btn" data-copy-filename="docs-28-keep-my-notes-obsidian.webp" aria-label="Copy filename docs-28-keep-my-notes-obsidian.webp">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
      <span>Copy filename</span>
    </button>
  </div>
  <div class="sp-screen">
    <p class="sp-title">Keep my notes in Obsidian: personal thoughts preserved above the marker</p>
    <p class="sp-desc">Inquadra una nota libro in Obsidian con riflessioni personali scritte sotto <code>## My notes...</code> sopra il blocco generato da Tomedown.</p>
    <span class="sp-hint">Formato: WebP (q90–q95) · Proporzioni: 16:10 (finestra desktop Obsidian / MarkText)</span>
  </div>
</div>

1. **Write freely**: write reflections, permanent notes, and synthesis directly under the `## My notes...` section.
2. **Resilient merging**: when you take new highlights on your e-reader, Tomedown folds them into the generated section below without touching a single word of your manual notes.
3. **Safety copies**: if content inside the generated block is ever altered unexpectedly, Tomedown creates a `.bak` backup copy before merging. For a complete deep dive, see [Keep my notes](docs/keep-my-notes.md).

## The Library Index (`00 - Index.md`)

`00 - Index.md` acts as your personal bookshelf dashboard in Obsidian.

<div class="screenshot-placeholder is-wide" role="region" aria-label="Screenshot placeholder: docs-27-index-dashboard-obsidian.webp">
  <div class="sp-top">
    <div class="sp-meta">
      <span class="sp-badge">Obsidian Vault</span>
      <code class="sp-filename">docs-27-index-dashboard-obsidian.webp</code>
    </div>
    <button type="button" class="placeholder-copy-btn" data-copy-filename="docs-27-index-dashboard-obsidian.webp" aria-label="Copy filename docs-27-index-dashboard-obsidian.webp">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
      <span>Copy filename</span>
    </button>
  </div>
  <div class="sp-screen">
    <p class="sp-title">00 - Index.md in Obsidian: Library dashboard, Completed books &amp; Tag cloud</p>
    <p class="sp-desc">Inquadra <code>00 - Index.md</code> in Obsidian mostrando la <em>Library dashboard</em>, la sezione <em>Completed books</em>, la tabella con copertine, barre di avanzamento a 5 celle e tag impilati, e la <em>Tag cloud</em>.</p>
    <span class="sp-hint">Formato: WebP (q90–q95) · Proporzioni: 16:10 (finestra desktop Obsidian / MarkText)</span>
  </div>
</div>

- **Interactive table**: click any book title or cover to navigate straight to that book note.
- **Visual reading progress**: 5-cell Unicode indicators (`▰▰▰▰▰`) display exact completion percentages without breaking columns.
- **Stacked tag pills**: subject tags stack vertically as clean pills, preventing table widening.
- **Customizable views**: choose between *Tags under the title*, *Tags column*, or *Tags column, compact* in **Settings → Index & library → Index layout**.

## Reading Digest (`00 - Reading Digest.md`)

A consolidated chronological reading journal grouping all highlights across your whole library by day:

<div class="screenshot-placeholder is-wide" role="region" aria-label="Screenshot placeholder: docs-03-reading-digest-obsidian.webp">
  <div class="sp-top">
    <div class="sp-meta">
      <span class="sp-badge">Obsidian Vault</span>
      <code class="sp-filename">docs-03-reading-digest-obsidian.webp</code>
    </div>
    <button type="button" class="placeholder-copy-btn" data-copy-filename="docs-03-reading-digest-obsidian.webp" aria-label="Copy filename docs-03-reading-digest-obsidian.webp">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
      <span>Copy filename</span>
    </button>
  </div>
  <div class="sp-screen">
    <p class="sp-title">00 - Reading Digest.md rendered inside Obsidian</p>
    <p class="sp-desc">Inquadra <code>00 - Reading Digest.md</code> in Obsidian con le intestazioni di data letteraria (<code>## 16 Nov 2026</code>), i divisori tra libri e gli orari delle citazioni.</p>
    <span class="sp-hint">Formato: WebP (q90–q95) · Proporzioni: 16:10 (finestra desktop Obsidian / MarkText)</span>
  </div>
</div>

## Handwritten notes & Stylus drawings

For stylus devices, handwritten notes are rendered as pure SVG vector strokes or PNGs in `drawings/` and embedded seamlessly inside your book notes when **Settings → Notes & highlights → Handwritten notes** is enabled.

## Link to a single highlight

Enable **Settings → Notes & highlights → Link IDs on highlights** to attach stable block IDs (`^hl-xxxxxxxx`) to every quote:

<div class="screenshot-placeholder is-wide" role="region" aria-label="Screenshot placeholder: docs-29-highlight-link-ids-obsidian.webp">
  <div class="sp-top">
    <div class="sp-meta">
      <span class="sp-badge">Obsidian Vault</span>
      <code class="sp-filename">docs-29-highlight-link-ids-obsidian.webp</code>
    </div>
    <button type="button" class="placeholder-copy-btn" data-copy-filename="docs-29-highlight-link-ids-obsidian.webp" aria-label="Copy filename docs-29-highlight-link-ids-obsidian.webp">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
      <span>Copy filename</span>
    </button>
  </div>
  <div class="sp-screen">
    <p class="sp-title">Single highlight block IDs (^hl-xxxxxxxx) &amp; transclusion in Obsidian</p>
    <p class="sp-desc">Inquadra una citazione con block ID <code>^hl-xxxxxxxx</code> e l'autocompletamento o l'incorporamento live <code>![[Book title#^hl-xxxxxxxx]]</code> dentro un'altra nota di Obsidian.</p>
    <span class="sp-hint">Formato: WebP (q90–q95) · Proporzioni: 16:10 (finestra desktop Obsidian / MarkText)</span>
  </div>
</div>

Because block IDs are tied to quote hashes, they persist across future re-exports:

- **Jump to a highlight**: `[[Book title#^hl-dfd750fa]]` opens the note directly focused on that quote.
- **Transclude anywhere**: `![[Book title#^hl-dfd750fa]]` embeds the quote live into any other note or daily journal in your vault.

<a id="setting-up-remotely-save"></a>
## Syncing with your vault

To sync notes automatically between your e-reader and Obsidian on computer or mobile:

- Follow the step-by-step [Setup tutorial (Koofr & Remotely Save)](TUTORIAL.md) to connect via WebDAV.
- Read [Sync direction guide](SYNC-DIRECTION.md) to understand how bidirectional sync keeps your notes safe.
- [README](README.md): installation, the menu, settings and file format.
