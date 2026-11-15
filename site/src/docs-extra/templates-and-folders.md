# Templates, Folders & Formats

Tomedown gives you full control over where files land, how they are named, how `00 - Index.md` looks, and which file formats are generated.

## Export format (`.md` and `.txt`)

In **Settings → Files → Export format**, choose:

- **Markdown (.md)** *(default)*: full Markdown with YAML frontmatter, headings, and callouts.
- **Plain text (.txt)**: clean, human-readable text without YAML or HTML.
- **Both (.md and .txt)**: keeps both files in sync side by side.

When you switch between `.md` and `.txt`, Tomedown automatically manages the old and new files on the next export so you never end up with stale duplicates.

<figure class="doc-device-figure">
  <img src="{{base}}/assets/img/export-format-kindle.svg" alt="KOReader Tomedown Export format submenu showing Markdown (.md), Plain text (.txt), and Both (.md and .txt)" />
</figure>

## Folder organization

Configure in **Settings → Files → Folder organization**:

- **Single folder** *(default)*: all book notes sit together in your Tomedown folder alongside `00 - Index.md`.
- **By author**: groups books into author subfolders (`Arthur Machen/The Three Impostors.md`).
- **By series**: groups multi-volume series into dedicated folders.
- **By reading status**: organizes books by status (e.g. `Reading`, `Completed`).

<figure class="doc-device-figure">
  <img src="{{base}}/assets/img/folder-organization-kindle.svg" alt="KOReader Tomedown Folder organization submenu showing Single folder, By author, By series, and By reading status" />
</figure>

## Filename templates

Configure in **Settings → Files → File name template**:

- `Author - Title` *(default)*
- `Title (Author)`
- `Title only`
- `Custom template…`: build your own pattern using `{author}`, `{title}`, `{series}`, and `{series_index}`.

If you change your template after exporting, Tomedown can rename existing files to match the new pattern without losing your notes.

<figure class="doc-device-figure">
  <img src="{{base}}/assets/img/filename-template-kindle.svg" alt="KOReader Tomedown File name template submenu showing Author - Title, Title (Author), Title only, and Custom template" />
</figure>

## Index layout, links & clean tags (`00 - Index.md`)

In **Settings → Index**, you can tailor the library index:

- **Index order**: sort by **Author** *(default)*, **Title**, **Last read** (newest first), or **Highlights** (most first).
- **Index layout**: **Tags under the title** *(default)*, **Tags column**, or **Tags column, compact**.
- **Index link style**: choose **Obsidian wikilink** (`[[Book]]`) or **Standard Markdown** (`[Book](Book.md)`) if you use another Markdown app.
- **Show Reading now in the index**: repeats currently active books in a dedicated top section.
- **Smart tag splitting & pills**: EPUB/Calibre subject facets (like `Fiction -- Mystery & Detective`) are automatically split into clean individual tags and stacked vertically as unbreakable `#tag` pills so the index table stays tidy.

<figure class="doc-device-figure">
  <img src="{{base}}/assets/img/index-order-kindle.svg" alt="KOReader Tomedown Index order settings submenu showing Author, Title, Last read, and Highlights" />
</figure>

<figure class="doc-shot">
  <div class="doc-shot-frame">
    <img class="zoom-index" src="{{base}}/assets/img/index-obsidian.webp" alt="00 - Index.md in Obsidian showing Series books, My books, 90x120 covers, progress bars, and stacked #tag pills" />
  </div>
  <figcaption><code>00 - Index.md</code> in Obsidian: covers, 5-cell progress bars, and stacked <code>#tag</code> pills.</figcaption>
</figure>

## Covers, page bookmarks & top bar icon

- **Include book covers**: exports full-color cover images into `covers/` (or any custom name you set in **Covers folder**, like `_covers` or `assets`, with automatic migration).
- **Include page bookmarks**: adds a `# Page bookmarks` section at the end of the book note with bookmarked page numbers and notes.
- **Show Tomedown icon in the top bar** *(Settings → Style)*: adds a dedicated Tomedown icon directly in KOReader's top bar for one-tap access while reading.

<figure class="doc-device-figure">
  <img src="{{base}}/assets/img/topbar-icon-kindle.svg" alt="KOReader top bar showing the dedicated Tomedown icon next to the menu icons" />
</figure>

## Manage books anywhere (Long-press shortcuts)

You don't need to open a book to manage how it exports. When you long-press any book in KOReader's **File Manager**, **History**, **Collections**, or **Bookshelf**, Tomedown adds direct shortcuts to the file dialog:

- **Export this book**: runs an immediate export for that volume without touching the rest of your library.
- **Tags…**: opens the tag picker and suggestion manager.
- **Book visibility…**: choose whether the book appears in the index, exports silently, or is excluded (`Do not export`).
- **Import book info** / **Remove imported book info…**: opt-in or remove extended KOReader metadata (rating, review, reading dates).

<figure class="doc-device-figure">
  <img src="{{base}}/assets/img/file-dialog-longpress-kindle.svg" alt="KOReader file dialog showing Tomedown direct action buttons on long press" />
</figure>
