# Templates, Folders & Index

Tomedown gives you full control over where files land, how they are named, how `00 - Index.md` looks, and which file formats are generated.

## Export format (`.md` and `.txt`)

In **Settings → Export → Export format**, choose:

- **Markdown (.md)** *(default)*: full Markdown with YAML frontmatter, headings, and callouts.
- **Plain text (.txt)**: clean, human-readable text without YAML or HTML.
- **Both (.md and .txt)**: keeps both files in sync side by side.

When you switch between `.md` and `.txt`, Tomedown automatically manages the old and new files on the next export so you never end up with stale duplicates. When **Plain text (.txt)** is selected, **Markdown style** is disabled automatically with the note *Not used with .txt*.

<div class="screenshot-placeholder" role="region" aria-label="Screenshot placeholder: docs-05-export-format-menu.svg">
  <div class="sp-top">
    <div class="sp-meta">
      <span class="sp-badge">KOReader E-Reader</span>
      <code class="sp-filename">docs-05-export-format-menu.svg</code>
    </div>
    <button type="button" class="placeholder-copy-btn" data-copy-filename="docs-05-export-format-menu.svg" aria-label="Copy filename docs-05-export-format-menu.svg">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
      <span>Copy filename</span>
    </button>
  </div>
  <div class="sp-screen">
    <p class="sp-title">Settings → Export → Export format submenu</p>
    <p class="sp-desc">Inquadra il sottomenu radio <strong>Settings → Export → Export format</strong> su KOReader con le tre opzioni: <em>Markdown (.md)</em>, <em>Plain text (.txt)</em> e <em>Both (.md and .txt)</em>.</p>
    <span class="sp-hint">Formato: SVG (preset vettoriale) · Schermo e-ink KOReader (3:4)</span>
  </div>
</div>

## File names & folders

All naming and directory structure options are grouped cleanly under **Settings → Export → File names & folders**:

<div class="screenshot-placeholder" role="region" aria-label="Screenshot placeholder: docs-06-filenames-folders-menu.svg">
  <div class="sp-top">
    <div class="sp-meta">
      <span class="sp-badge">KOReader E-Reader</span>
      <code class="sp-filename">docs-06-filenames-folders-menu.svg</code>
    </div>
    <button type="button" class="placeholder-copy-btn" data-copy-filename="docs-06-filenames-folders-menu.svg" aria-label="Copy filename docs-06-filenames-folders-menu.svg">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
      <span>Copy filename</span>
    </button>
  </div>
  <div class="sp-screen">
    <p class="sp-title">Settings → Export → File names &amp; folders submenu</p>
    <p class="sp-desc">Inquadra il sottomenu <strong>Settings → Export → File names &amp; folders</strong> che mostra le quattro voci: <em>File name template</em>, <em>Folder organization</em>, <em>Covers folder</em> e <em>Drawings folder</em>.</p>
    <span class="sp-hint">Formato: SVG (preset vettoriale) · Schermo e-ink KOReader (3:4)</span>
  </div>
</div>

### 1. File name template
Configure in **Settings → Export → File names & folders → File name template**:

- `Author - Title` *(default)*
- `Title (Author)`
- `Title only`
- `Custom template…`: build your own pattern using `%A` (author), `%T` (title), `%S` (series), and `%i` (series index).

If you change your template after exporting, Tomedown can rename existing files to match the new pattern without losing your notes.

### 2. Folder organization
Configure in **Settings → Export → File names & folders → Folder organization**:

- **Single folder** *(default)*: all book notes sit together in your Tomedown folder alongside `00 - Index.md`.
- **By author**: groups books into author subfolders (`Arthur Machen/The Three Impostors.md`).
- **By series**: groups multi-volume series into dedicated folders.
- **By reading status**: organizes books by status (`Reading`, `Completed`, `On hold`).

### 3. Covers folder & Drawings folder
- **Covers folder**: custom folder name for extracted cover images (defaults to `covers`, e.g. `_covers` or `assets`, with automatic migration). Available when *Book cover* is enabled in **Settings → Notes & highlights → Book page**.
- **Drawings folder**: custom folder name for extracted stylus sketches and vector SVG drawings (defaults to `drawings`). Available when *Handwritten notes* is enabled in **Settings → Notes & highlights**.

## Index & library (`00 - Index.md`)

In **Settings → Index & library**, you can tailor the library index:

- **Index note (00 - Index.md)**: master switch to generate the index table (on by default).
- **Index order**: sort by **Author** *(default)*, **Title**, **Last read** (newest first), or **Highlights** (most first).
- **Index layout**: **Tags under the title** *(default)*, **Tags column**, or **Tags column, compact**.
- **Index links**: choose **Obsidian wikilink** (`[[Book]]`) or **Standard Markdown** (`[Book](Book.md)`) if you use another Markdown app.
- **Index style**: choose **Minimal symbols** (`▰▰▰▰▰` and `★`), **Classic text**, or **Emoji badges** for status and progress cells.
- **Tags display**: choose **Show all** *(default)*, **First 3 (+N)** for a compact badge, or **Collapsible (<details>)** to fold long tag lists behind an expandable dropdown.
- **Reading now section**: repeats currently active books in a dedicated top section.
- **Completed books**: generates a `### Completed books` trophy showcase celebrating finished volumes with ratings and stats.
- **Library dashboard**: renders a top-level reading overview table with total books, completed count, and progress.
- **Tag cloud**: generates an alphabetical directory of all tags with volume counts at the bottom of the index.

<div class="screenshot-placeholder" role="region" aria-label="Screenshot placeholder: docs-07-index-library-menu.svg">
  <div class="sp-top">
    <div class="sp-meta">
      <span class="sp-badge">KOReader E-Reader</span>
      <code class="sp-filename">docs-07-index-library-menu.svg</code>
    </div>
    <button type="button" class="placeholder-copy-btn" data-copy-filename="docs-07-index-library-menu.svg" aria-label="Copy filename docs-07-index-library-menu.svg">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
      <span>Copy filename</span>
    </button>
  </div>
  <div class="sp-screen">
    <p class="sp-title">Settings → Index &amp; library menu in KOReader</p>
    <p class="sp-desc">Inquadra il gruppo <strong>Settings → Index &amp; library</strong> su KOReader con il master toggle <em>Index note (00 - Index.md)</em>, le opzioni di struttura (<em>Index order</em>, <em>Index layout</em>, <em>Index links</em>, <em>Index style</em>, <em>Tags display</em>) e i quattro toggle delle sezioni (<em>Reading now section</em>, <em>Completed books</em>, <em>Library dashboard</em>, <em>Tag cloud</em>).</p>
    <span class="sp-hint">Formato: SVG (preset vettoriale) · Schermo e-ink KOReader (3:4)</span>
  </div>
</div>

## Top bar icon & Settings backup

- **Top bar icon** *(Settings → App & updates → Top bar icon)*: adds a dedicated Tomedown icon directly in KOReader's top bar for one-tap access while reading.
- **Settings export & restore** *(Settings → Export)*:
  - **Export settings to file**: writes a portable backup of all your Tomedown options to `tomedown_settings_backup.lua`.
  - **Restore settings from backup…**: restores your exact configuration from `tomedown_settings_backup.lua` with a confirmation dialog.
  - **Delete all backup copies…**: inside **Settings → Export → Backup copies**, scans your vault and safely removes stale `.bak` copies while keeping all original notes intact.

## Manage books anywhere (Long-press shortcuts)

You don't need to open a book to manage how it exports. When you long-press any book in KOReader's **File Manager**, **History**, **Collections**, or **Bookshelf**, Tomedown adds direct shortcuts to the file dialog:

- **Export this book**: runs an immediate export for that volume without touching the rest of your library.
- **Tags…**: opens the tag picker and suggestion manager.
- **Book visibility…**: choose whether the book appears in the index, exports silently, or is excluded (`Do not export`).
- **Import book info** / **Remove imported book info…**: opt-in or remove extended KOReader metadata (rating, review, reading dates).

<div class="screenshot-placeholder" role="region" aria-label="Screenshot placeholder: docs-08-longpress-file-dialog.svg">
  <div class="sp-top">
    <div class="sp-meta">
      <span class="sp-badge">KOReader E-Reader</span>
      <code class="sp-filename">docs-08-longpress-file-dialog.svg</code>
    </div>
    <button type="button" class="placeholder-copy-btn" data-copy-filename="docs-08-longpress-file-dialog.svg" aria-label="Copy filename docs-08-longpress-file-dialog.svg">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
      <span>Copy filename</span>
    </button>
  </div>
  <div class="sp-screen">
    <p class="sp-title">Long-press book dialog in KOReader File Manager / History</p>
    <p class="sp-desc">Inquadra il dialogo che appare tenendo premuto un libro nel File Manager o in History su KOReader, mostrando i pulsanti rapidi di Tomedown: <strong>Export this book</strong>, <strong>Tags…</strong>, <strong>Book visibility…</strong> e <strong>Import book info</strong>.</p>
    <span class="sp-hint">Formato: SVG (preset vettoriale) · Schermo e-ink KOReader (3:4)</span>
  </div>
</div>
