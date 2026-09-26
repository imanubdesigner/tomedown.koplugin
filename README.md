# Tomedown

A KOReader plugin that exports the highlights of **each book into its own
`.md` file**, with YAML frontmatter and an automatic index, and uploads them
to **Koofr** so you can read them in Obsidian.

Unlike *Export highlights and notes* (which produces a single combined file),
every volume stays separate:

```
/mnt/us/koreader/clipboard/tomedown/
├── 00 - Index.md
├── Michael McDowell - Blackwater_ The Complete Saga.md
└── ...
```

## Requirements

- KOReader with highlights in the modern format (old `.sdr` files, where
  highlights live in `highlight` + `bookmarks`, are supported too)
- The **Cloud storage** plugin that ships with KOReader, with a WebDAV server
  configured for Koofr: `https://webdav.koofr.net/dav`
- A Koofr account (the free plan is plenty)
- In Obsidian: **Remotely Save** with a WebDAV server (free)

## Installation

1. Plug the Kindle in via USB mass storage.
2. Copy the `tomedown.koplugin` folder into:

   ```
   /mnt/us/koreader/plugins/
   ```

   You can leave `tests/` behind — it is only needed to run the suite:

   ```
   rsync -a --exclude tests tomedown.koplugin /mnt/us/koreader/plugins/
   ```

   The result should look like:

   ```
   /mnt/us/koreader/plugins/tomedown.koplugin/main.lua
   /mnt/us/koreader/plugins/tomedown.koplugin/tomedown_i18n.lua
   /mnt/us/koreader/plugins/tomedown.koplugin/tomedown_render.lua
   /mnt/us/koreader/plugins/tomedown.koplugin/_meta.lua
   /mnt/us/koreader/plugins/tomedown.koplugin/languages/it.po
   /mnt/us/koreader/plugins/tomedown.koplugin/README.md
   ```

3. Unplug the Kindle and restart KOReader (or: ☰ menu → *Plugin management* →
   enable *Tomedown*).
4. **Tomedown** shows up in the file browser's top menu.

## Configuration (one-off)

☰ menu → **Tomedown** → **Settings**:

| Entry | What to do |
|---|---|
| *Upload to Koofr* | leave it ticked (it is by default) |
| *Server and folder…* | opens the Cloud storage browser: pick your Koofr server, then navigate to the final folder (e.g. `Bookshelf/Kindle`) and tap **Choose** |
| *Remote folder…* | only if you want to override the folder chosen above (e.g. `/Bookshelf/Kindle`) |
| *Local folder* | defaults to `clipboard/tomedown` inside KOReader's data folder |
| *Generate the index 00 - Index.md* | table with internal links, author, highlight count and last export date |

Everything is stored in KOReader's settings, so it applies to all books.

### If you already use AnnotationSync

The Koofr server is **inherited automatically** from the one AnnotationSync
already saved in KOReader (`Cloud settings`): *Server and folder…* shows
exactly that. If it is the right folder, you do not have to touch anything.

If AnnotationSync uploads its `.json` files somewhere other than where you
want the `.md` files (say `/Bookshelf/Kindle`), set **Remote folder…** and
type the correct path: it applies to this plugin only.

Tip: keep the `.md` files in a folder where AnnotationSync's JSONs do not
land, or add `*.json` to Remotely Save's *Ignore list* so only the notes
reach Obsidian.

## Usage

☰ menu → **Tomedown**:

- **Export current book** — only the open book.
- **Only updated** — exports only the books whose highlights changed since
  the last export (per-book hash).
- **Choose books…** — a list with checkboxes: tick the volumes and export
  just those.
- **All books with highlights** — exports everything found in KOReader's
  reading history.
- **Reload everything to Koofr** — re-uploads every file already in the local
  folder (use it after a failed upload).
- **Settings** — see above.

After every export, if *Upload to Koofr* is on, the `.md` files and the index
are uploaded to the chosen server automatically. No image folder is created:
only `*.md` files are uploaded (books + `00 - Index.md`).

### Upload retries

While uploading, an *Uploading N files to Koofr…* message stays on screen
(including the wait times), and each file is tried **up to 3 times** with
exponential backoff:

| attempt | wait before the next one |
|:--:|:--:|
| 1 | 2 seconds |
| 2 | 4 seconds |
| 3 | done: the file is marked as failed |

Only **transient** failures are retried:

- network errors (no HTTP code, e.g. `connection reset`, timeout);
- `5xx` (server temporarily unavailable);
- `408` (request timeout) and `429` (too many requests).

`4xx` errors (missing remote folder, wrong credentials…) are **not** retried:
the file fails immediately, because retrying would only cost waiting.

If a file still fails after the 3 attempts, a window shows
`Koofr: X uploaded, Y errors` and everything else continues: the files stay in
the local folder, so you can fix the problem and use **Reload everything to
Koofr**. The attempts are also logged:

```
tomedown: upload failed (attempt 1 of 3), retrying in 2 s: <path> 500
```

## File format

```markdown
---
title: "Blackwater: The Complete Saga"
author: "Michael McDowell"
exported: 2026-09-26
highlights: 150
tags:
  - kindle
  - highlights
---

# Blackwater: The Complete Saga

*Michael McDowell*

**150 highlights**

## Chapter I

> First highlighted sentence.
> Second line of the same highlight.

- **p. 10** · 02/09/2026 · note: to reread

> Another highlight.

- **p. 12** · 03/09/2026
```

- **only highlights** are exported: page bookmarks (notes without a
  highlight) and deleted annotations are left out
- the file name matches KOReader's standard exporter (`Author - Title`), so
  it does not clash with exports you already made
- the page is the stable page number (`pageref`) when available, otherwise
  the running page number
- the index uses Obsidian's internal links:

  ```markdown
  | [[Michael McDowell - Blackwater_ The Complete Saga|Blackwater: The Complete Saga]] | Michael McDowell | 150 | 26/09/2026 |
  ```

The sample above is what an English KOReader produces; with an Italian
interface the same text comes out translated (see *Languages*).

## Obsidian

Only **Remotely Save** needs configuring here: the Tomedown plugin lives on
KOReader, nothing special has to be installed in Obsidian.

1. On Koofr create an app (Security → Applications) and copy the **app
   password**, not the account one.
2. In Obsidian install **Remotely Save** and configure:
   - type: **WebDAV**
   - server: `https://webdav.koofr.net/dav`
   - user: your Koofr account e-mail
   - password: the app password
   - **remote folder / base dir: `/Bookshelf`**
3. In Remotely Save's local data, point to the folder that holds your books
   vault (in this example `Bookshelf/`).
4. Sync.

Result: `Bookshelf/Kindle/*.md` arrive in Obsidian, `00 - Index.md` opens as
a clickable table and every title opens that book's file.

## Notes and limitations

- The `.md` files are **rewritten on every export**: treat them as read-only
  in Obsidian, otherwise your edits disappear next time.
- The plugin **never touches** AnnotationSync's files (`<md5>.json`,
  `settings_sync.json`): it only reads the `.sdr` folders.
- Uploads go through KOReader's *Cloud storage* plugin: if it is not active,
  the local export still works, only the Koofr part is skipped.
- If an upload fails (missing remote folder, no connection), the files stay
  in the local folder: fix it and use **Reload everything to Koofr**.

## Languages (English / Italian)

Plugin strings are **English** in the code (`_("…")`), as KOReader
conventions require, and are shown **in Italian** when KOReader's interface
is Italian: no setting to change, only KOReader's language matters.

How it works: KOReader only translates its core (`l10n/<lang>/koreader.mo`)
and does **not** load plugin `.po` files automatically, so
`tomedown_i18n.lua` reads `languages/it.po` based on the current language
(`GetText.current_lang`, falling back to *Settings → Language*) and swaps the
texts. On English (or when no translation exists) the original msgid is
used.

The text inside the `.md` files is translated too (titles,
`No chapter`, `N highlights`, `note:`, `Book index`, table headers), so your
exported notes follow KOReader's language.

To fix or add a translation: edit `languages/it.po` (msgid = English source,
msgstr = Italian) and restart KOReader. It is standard gettext: for another
language just copy it to `languages/<code>.po`.

## Debug

In case of trouble:

```
/mnt/us/koreader/crash.log
```

Plugin messages are prefixed with `tomedown:`.

## Tests

The suite lives in `tests/` and needs Lua 5.3 or newer (the test md5 uses
bitwise operators):

```
cd tests && ./run.sh
```

It covers Markdown rendering, `languages/it.po` sync, runtime translations
and the behaviour of `main.lua` (export, menu, dialogs, fallback servers,
uploads and retries) against a fake KOReader environment (`kostubs/`). It
finishes with `luac5.1 -p` on the sources — the same Lua version that runs
on the Kindle. The same suite runs on every push through GitHub Actions.

## Project structure

```
tomedown.koplugin/
├── _meta.lua              plugin name and description
├── main.lua               menu, .sdr reading, export, upload (with retries)
├── tomedown_render.lua    Markdown builder (pure, testable)
├── tomedown_i18n.lua      reads languages/<lang>.po (English/Italian)
├── languages/
│   └── it.po              Italian translation (read by tomedown_i18n)
├── tests/                 test suite + fake KOReader environment
│   ├── run.sh             runs everything, ends with luac5.1 -p
│   ├── kostubs/           stubs for KOReader's Lua modules
│   └── test_*.lua
└── README.md
```

## License

GNU Affero General Public License v3.0 — see [LICENSE](LICENSE).
