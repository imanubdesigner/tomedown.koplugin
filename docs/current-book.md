# Current book

In-reader controls, dashboard cards, highlight navigation, per-book format overrides, and metadata management in KOReader.

[Back to the README](../README.md).

☰ menu → **Tomedown** → **Current book**, available whenever a book is open:

<div class="screenshot-placeholder" role="region" aria-label="Screenshot placeholder: docs-20-current-book-menu.svg">
  <div class="sp-top">
    <div class="sp-meta">
      <span class="sp-badge">KOReader E-Reader</span>
      <code class="sp-filename">docs-20-current-book-menu.svg</code>
    </div>
    <button type="button" class="placeholder-copy-btn" data-copy-filename="docs-20-current-book-menu.svg" aria-label="Copy filename docs-20-current-book-menu.svg">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
      <span>Copy filename</span>
    </button>
  </div>
  <div class="sp-screen">
    <p class="sp-title">Tomedown → Current book menu in KOReader</p>
    <p class="sp-desc">Inquadra il sottomenu <strong>Tomedown → Current book</strong> con il nuovo ordine gerarchico: <strong>Book summary</strong> in cima, seguito da <strong>★ Special highlights</strong>, separatore, <strong>Book info ▸</strong>, <strong>Book visibility: Normal ▸</strong>, separatore, <strong>Keep my notes in this book</strong>, <strong>Notes heading</strong>, <strong>Backup copies ▸</strong> e <strong>Format &amp; layout ▸</strong>.</p>
    <span class="sp-hint">Formato: SVG (preset vettoriale) · Schermo e-ink KOReader (3:4)</span>
  </div>
</div>

While [Menu & Settings](settings.md) configures global defaults applied across your entire library, **Current book** controls the volume currently open on your screen. Here you can inspect your reading session, jump across quotes, override export formats, manage book info, and edit notes directly inside KOReader.

## Current book menu reference

| Entry | What it does |
|---|---|
| *Book summary* | First entry in the menu: opens the rounded e-ink dashboard card showing book metrics, 3 interactive KPI counters, effective format, tags, and export status (see [Book summary](#book-summary-dashboard-card)) |
| *★ Special highlights* | Displayed when starred highlights exist in the book (with the count on the right): opens the in-device card browser to review standout passages |
| *Book info ▸* | Opens the book info submenu to import KOReader ratings, reviews, reading dates, collections, or manage per-book tags (see [Book info](#book-info--metadata)) |
| *Book visibility: %1 ▸* | Opens a 3-option radio submenu: **Export and show in the index** (*Normal*), **Export, but hide from the index** (*Hidden from index*), or **Do not export** (*Not exported*) |
| *Keep my notes in this book* | Enables [Keep my notes](keep-my-notes.md) specifically for this volume without turning it on for all books. If turned off later, Tomedown asks first and preserves an automatic `.bak` copy before reverting to plain exports |
| *Notes heading: %1* | Displayed when *Keep my notes* is active for this book: tap to set a custom Markdown heading (e.g. `## My thoughts`) above the generated body |
| *Backup copies ▸* | Displayed when `.bak` snapshots exist for this book: opens a submenu to view real file dates and safely delete stale backup files |
| *Format & layout ▸* | Overrides global style and layout settings (export format, Markdown style, notes format, details, headings, context, covers, bookmarks, handwritten notes, and **Book page** modules) specifically for this book (see [Format & layout overrides](#format--layout-overrides)) |

## Book summary dashboard card

Under **Tomedown → Current book → Book summary**, Tomedown opens a rounded dashboard card built specifically for e-ink displays:

<div class="screenshot-placeholder" role="region" aria-label="Screenshot placeholder: docs-21-book-summary-card.svg">
  <div class="sp-top">
    <div class="sp-meta">
      <span class="sp-badge">KOReader E-Reader</span>
      <code class="sp-filename">docs-21-book-summary-card.svg</code>
    </div>
    <button type="button" class="placeholder-copy-btn" data-copy-filename="docs-21-book-summary-card.svg" aria-label="Copy filename docs-21-book-summary-card.svg">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
      <span>Copy filename</span>
    </button>
  </div>
  <div class="sp-screen">
    <p class="sp-title">Current book → Book summary dashboard card</p>
    <p class="sp-desc">Inquadra la card arrotondata <strong>Book summary</strong> su KOReader: titolo e autore in alto, i 3 pulsanti KPI cliccabili (<em>Highlights</em>, <em>★ Special</em>, <em>Notes</em>), i dettagli <em>Format</em>, <em>Status</em>, <em>Tags</em> e i pulsanti <strong>Export this book</strong> e <strong>Close</strong>.</p>
    <span class="sp-hint">Formato: SVG (preset vettoriale) · Schermo e-ink KOReader (3:4)</span>
  </div>
</div>

### What the card displays

- **Book Title & Author**: Extracted cleanly from the document metadata.
- **3-Column KPI Buttons**:
  - **Highlights**: Total count of all highlighted passages in the book.
  - **★ Special**: Count of standout passages marked with *Special highlight*.
  - **Notes**: Count of highlights that have personal user notes attached.
- **Format**: Shows the effective export format and Markdown style for this book (e.g. `Markdown (.md) · Obsidian` or `Markdown (.md) · Standard`).
- **Status**: Indicates the export state:
  - `Up to date`: Exported file matches your latest highlights and reading position.
  - `Updates pending`: New highlights, notes, or reading progress await the next export.
  - `Not exported yet`: Book has not been exported to disk yet.
- **Action Buttons**:
  - **Export this book**: Immediately exports the open book, extracts covers or drawings if enabled, and uploads the note if cloud sync is configured.
  - **Close**: Closes the card and returns smoothly to your reading session with full screen repaint.

## Highlights, ★ Special & Notes card browser

Tapping any of the three KPI buttons in **Book summary** (or selecting **Current book → ★ Special highlights**) opens the paginated card browser for your annotations:

- **Highlights KPI**: Browses all extracted quotes and passages from the book.
- **Notes KPI**: Displays only passages that contain personal annotations.
- **★ Special KPI**: Displays all passages you have marked as favorites.

<div class="screenshot-placeholder" role="region" aria-label="Screenshot placeholder: docs-22-highlights-notes-cards.svg">
  <div class="sp-top">
    <div class="sp-meta">
      <span class="sp-badge">KOReader E-Reader</span>
      <code class="sp-filename">docs-22-highlights-notes-cards.svg</code>
    </div>
    <button type="button" class="placeholder-copy-btn" data-copy-filename="docs-22-highlights-notes-cards.svg" aria-label="Copy filename docs-22-highlights-notes-cards.svg">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
      <span>Copy filename</span>
    </button>
  </div>
  <div class="sp-screen">
    <p class="sp-title">Paginated Highlights / ★ Special / Notes card browser</p>
    <p class="sp-desc">Inquadra la card paginata delle evidenziazioni o delle note su KOReader (con sottotitolo <em>Tap to jump · Hold for ★</em> oppure <em>Tap to jump · Hold to edit</em>, elenco citazioni con capitolo/pagina e frecce di paginazione <code>◀</code> / <code>▶</code>).</p>
    <span class="sp-hint">Formato: SVG (preset vettoriale) · Schermo e-ink KOReader (3:4)</span>
  </div>
</div>

The card browser allows you to review and manage your annotations without leaving your reading session. Designed for 6-inch e-ink screens, it features pagination controls (`◀` / `▶`) showing 3 to 4 items per page.

### Gestures & Shortcuts

| Action | Highlight / ★ Special cards | Notes card |
|---|---|---|
| **Short tap** | **Jump to passage**: Instantly navigates to the highlighted location in the book (`GotoXPointer` on reflowable EPUBs, `GotoPage` on PDFs) | **Jump to passage**: Navigates directly to the page and sentence where the note was recorded |
| **Long-press** | **Toggle ★ Special**: Star or unstar the passage in place without leaving the card. The change is persisted immediately to KOReader's `.sdr` file | **Edit note**: Opens KOReader's `InputDialog` showing your existing note. You can edit the text, append thoughts, or clear it completely |

<a id="style--format-overrides"></a>
## Format & layout overrides

By default, every book follows your library-wide defaults configured in [Settings → Notes & highlights](settings.md#notes--highlights) and [Settings → Export](settings.md#export). Under **Current book → Format & layout**, you can customize settings for a single volume without affecting the rest of your library:

<div class="screenshot-placeholder" role="region" aria-label="Screenshot placeholder: docs-23-current-book-format-layout.svg">
  <div class="sp-top">
    <div class="sp-meta">
      <span class="sp-badge">KOReader E-Reader</span>
      <code class="sp-filename">docs-23-current-book-format-layout.svg</code>
    </div>
    <button type="button" class="placeholder-copy-btn" data-copy-filename="docs-23-current-book-format-layout.svg" aria-label="Copy filename docs-23-current-book-format-layout.svg">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
      <span>Copy filename</span>
    </button>
  </div>
  <div class="sp-screen">
    <p class="sp-title">Current book → Format &amp; layout submenu</p>
    <p class="sp-desc">Inquadra il sottomenu <strong>Current book → Format &amp; layout</strong> su KOReader con indicatori <code>Global</code> / <code>Custom</code> a destra: mostra <em>Export format</em>, <em>Markdown style</em>, <em>Personal notes format</em>, <em>Highlight details</em>, <em>Chapter headings</em>, <em>Highlight context</em>, <em>Book cover</em>, <em>Page bookmarks</em>, <em>Handwritten notes</em>, <em>Book page ▸</em> e <em>Reset to global style settings</em>.</p>
    <span class="sp-hint">Formato: SVG (preset vettoriale) · Schermo e-ink KOReader (3:4)</span>
  </div>
</div>

### Available overrides

1. **Export format**: Choose between **Follow global setting**, **Markdown (.md)**, **Plain text (.txt)**, or **Both (.md and .txt)**.
2. **Markdown style**: Select **Follow global setting**, **Obsidian** (wikilinks, `[!...]` callouts, `^hl-` block IDs), or **Standard** (universal Markdown headings, `[Title](file.md)` links, no orphan block IDs).
3. **Personal notes format**: Override between **Inline** (indented right under the quote) or **Footnotes** (`[^1]` at the end of the file).
4. **Highlight details**: Switch between **Page and date**, **Page only**, **Date only**, or **None**.
5. **Chapter headings**: Override heading level (**Heading 1**, **Heading 2**, **Heading 3**, or **None**).
6. **Highlight context**: Enable or disable sentence surrounding extraction for this book.
7. **Book cover**: Override cover image extraction for this volume.
8. **Page bookmarks & Handwritten notes**: Enable or disable bookmarks and stylus vector drawing extraction.
9. **Book page ▸**: Override header layout, **Overview style**, **Reading dashboard**, **Book synopsis**, **Tags in body**, **Special highlights showcase**, **Section styles ▸** (*Harmonize book style* or per-section styles), and **YAML frontmatter** (**Frontmatter fields ▸**) for this title.
10. **Reset to global style settings**: Removes all per-book overrides and restores global defaults with a single tap.

### Selecting Markdown style for a book

When you select **Standard** for a book, Tomedown automatically adapts the generated note:
- Callouts (`[!book]`, `[!abstract]-`, `[!highlight]`) become clean Markdown headings (`### Reading dashboard`, `### Book synopsis`, `### ★ Special highlights`).
- Obsidian wikilinks switch to standard `[Title](file.md)`.
- Obsidian-only block IDs (`^hl-xxxxxxxx`) are omitted.
- Obsidian-specific style options (such as *Obsidian Callout* in Section styles) are disabled for that volume.

## Book info & Metadata

Under **Current book → Book info**, you can enrich your book note with extended metadata tracked by KOReader:

- **Import book info**: Reads the volume's rating (1–5 stars), personal review text, reading dates (`date_started`, `date_finished`), reading status (`reading`, `complete`, `abandoned`), and KOReader collections into the note's YAML frontmatter.
- **Tags: %1**: Assign custom tags to this specific book. Assigned tags appear under the title in `00 - Index.md`, in frontmatter, and inside the book note.
- **Delete tags…**: Delete obsolete tags across your library and clean up the suggestion cache.

To automate metadata imports across all your books, see [Settings → Book info → Update book info automatically](settings.md#book-info).

## Book visibility & Keep my notes

### Book visibility radio submenu

Under **Current book → Book visibility**, choose one of three radio options:

- **Export and show in the index** (*Normal*): the book is exported and listed in `00 - Index.md` and `00 - Reading Digest.md`.
- **Export, but hide from the index** (*Hidden from index*): the book note is exported to disk, but omitted from `00 - Index.md`.
- **Do not export** (*Not exported*): instructs Tomedown to ignore this volume during library-wide exports and omit it from both `00 - Index.md` and `00 - Reading Digest.md`.

<div class="screenshot-placeholder" role="region" aria-label="Screenshot placeholder: docs-24-book-visibility-radio.svg">
  <div class="sp-top">
    <div class="sp-meta">
      <span class="sp-badge">KOReader E-Reader</span>
      <code class="sp-filename">docs-24-book-visibility-radio.svg</code>
    </div>
    <button type="button" class="placeholder-copy-btn" data-copy-filename="docs-24-book-visibility-radio.svg" aria-label="Copy filename docs-24-book-visibility-radio.svg">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
      <span>Copy filename</span>
    </button>
  </div>
  <div class="sp-screen">
    <p class="sp-title">Current book → Book visibility radio submenu</p>
    <p class="sp-desc">Inquadra il sottomenu radio <strong>Current book → Book visibility</strong> su KOReader con le tre opzioni: <em>Export and show in the index</em>, <em>Export, but hide from the index</em> e <em>Do not export</em>.</p>
    <span class="sp-hint">Formato: SVG (preset vettoriale) · Schermo e-ink KOReader (3:4)</span>
  </div>
</div>

### Per-book Keep my notes

If you want to write personal summaries or commentary directly inside certain Markdown notes while keeping plain, automated exports for others:

1. Open the book in KOReader.
2. Tap **Tomedown → Current book → Keep my notes in this book**.
3. Tomedown writes a protected `## My notes... <!-- tomedown:notes -->` zone at the top of the file.
4. Any thoughts you type above the body zone in Obsidian or your text editor will remain intact on every future export from KOReader.

If you ever disable *Keep my notes* for the book, Tomedown creates an automatic `.bak` copy of your note before switching back to plain exports, ensuring your manual thoughts are never lost.
