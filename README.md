<p align="center">
  <img src="assets/banner.svg" alt="tomedown — one Markdown file per book, straight into your notes" width="100%">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/KOReader-171717?style=for-the-badge&logo=koreader&logoColor=white" alt="KOReader">
  <img src="https://img.shields.io/badge/Obsidian-171717?style=for-the-badge&logo=obsidian&logoColor=white" alt="Obsidian">
  <img src="https://img.shields.io/badge/Markdown-171717?style=for-the-badge&logo=markdown&logoColor=white" alt="Markdown">
  <img src="https://img.shields.io/badge/Lua-171717?style=for-the-badge&logo=lua&logoColor=white" alt="Lua">
</p>

<p align="center">
  <a href="https://github.com/imanubdesigner/tomedown.koplugin/releases/latest"><img src="https://img.shields.io/github/v/release/imanubdesigner/tomedown.koplugin?style=for-the-badge&color=171717&labelColor=171717&logo=github&logoColor=white" alt="Latest release"></a>
  <a href="https://github.com/imanubdesigner/tomedown.koplugin/actions/workflows/test.yml"><img src="https://img.shields.io/github/actions/workflow/status/imanubdesigner/tomedown.koplugin/test.yml?style=for-the-badge&labelColor=171717&logo=githubactions&logoColor=white&label=tests" alt="Test status"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/imanubdesigner/tomedown.koplugin?style=for-the-badge&color=171717&labelColor=171717" alt="License"></a>
</p>

A KOReader plugin that exports the highlights of **each book into its own
`.md` file**, with YAML frontmatter and an automatic index. Everything is
written to a folder on the device first (`clipboard/tomedown`, changeable);
uploading to **your cloud** — any WebDAV server, or Dropbox/FTP — is an
option, and so is reading the notes in Obsidian.

The examples in this repo use **Koofr**: its free plan gives you 10 GB,
more than enough for a whole library of `.md` files.

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
- The **Cloud storage** plugin that ships with KOReader, with any server it
  supports (WebDAV, Dropbox, FTP). The examples use Koofr's WebDAV:
  `https://app.koofr.net/dav/Koofr`
  (Koofr's documented WebDAV host — the plain `/dav/` root is not writable).
  **No cloud at all?** The local export works anyway
- Optional, to read the notes in Obsidian: **Remotely Save** with a WebDAV
  server (free) — any other Markdown app works too

## Installation

A full walkthrough — cloud account and app password (Koofr as the example),
first export and optional Remotely Save in Obsidian — is in
[TUTORIAL.md](TUTORIAL.md).

1. Plug the Kindle in via USB mass storage.
2. Get the plugin into `/mnt/us/koreader/plugins/`, either way:

   **a. Release zip (easiest)** — download `tomedown.koplugin-v*.zip` from the
   [Releases](https://github.com/imanubdesigner/tomedown.koplugin/releases)
   page and unzip it *into* that folder: the zip already contains the
   `tomedown.koplugin/` directory.

   **b. From a clone of this repo** — copy the folder, leaving behind what
   KOReader does not need (`tests/`, `assets/`, `README.md`, `TUTORIAL.md`,
   git files):

   ```
   rsync -a --exclude tests --exclude assets --exclude README.md \
         --exclude TUTORIAL.md --exclude .git --exclude .github \
         --exclude .gitignore \
         tomedown.koplugin /mnt/us/koreader/plugins/
   ```

   Either way the result should look like:

   ```
   /mnt/us/koreader/plugins/tomedown.koplugin/main.lua
   /mnt/us/koreader/plugins/tomedown.koplugin/tomedown_i18n.lua
   /mnt/us/koreader/plugins/tomedown.koplugin/tomedown_render.lua
   /mnt/us/koreader/plugins/tomedown.koplugin/_meta.lua
   /mnt/us/koreader/plugins/tomedown.koplugin/languages/it.po
   /mnt/us/koreader/plugins/tomedown.koplugin/LICENSE
   ```

3. Unplug the Kindle and restart KOReader (or: ☰ menu → *Plugin management* →
   enable *Tomedown*).
4. **Tomedown** shows up in the file browser's top menu.

## Configuration (one-off)

☰ menu → **Tomedown** → **Settings**:

| Entry | What to do |
|---|---|
| *Upload to cloud* | leave it ticked (it is by default); any WebDAV/Dropbox/FTP server works |
| *Server and folder…* | opens the Cloud storage browser: pick your server (the examples use Koofr), then navigate to the final folder (e.g. `Bookshelf/Kindle`) and tap **Choose** |
| *Remote folder…* | only if you want to override the folder chosen above (e.g. `/Bookshelf/Kindle`) |
| *Local folder* | defaults to `clipboard/tomedown` inside KOReader's data folder |
| *Generate the index 00 - Index.md* | table with internal links, author, highlight count and last export date |
| *Include page bookmarks* | off by default: adds a `## Page bookmarks` section (bookmarked page + note) after the highlights |
| *Version* | the installed version, read from `_meta.lua` |
| *Check for updates…* | asks GitHub for newer releases, shows their notes and can install the update right away (**Update and restart**) |
| *Check for updates in background* | off by default: when enabled, a quiet check runs when KOReader starts and when the menu opens (at most once an hour) and notifies you of a new release |

Everything is stored in KOReader's settings, so it applies to all books.

### If you already use AnnotationSync

The cloud server is **inherited automatically** from the one AnnotationSync
already saved in KOReader (`Cloud settings`): *Server and folder…* shows
exactly that. If it is the right folder, you do not have to touch anything.

If AnnotationSync uploads its `.json` files somewhere other than where you
want the `.md` files (say `/Bookshelf/Kindle`), set **Remote folder…** and
type the correct path: it applies to this plugin only.

Tip: keep the `.md` files in a folder where AnnotationSync's JSONs do not
land, or add `*.json` to Remotely Save's *Ignore list* so only the notes
reach Obsidian.

### Updates

*Check for updates…* compares the installed version with the releases
on GitHub and shows the notes of **every** release newer than yours, so
someone updating from 0.2.0 to 1.0 reads the fixes of 0.3.0, 0.3.1 and
1.0 in one window. When your KOReader renders Markdown, the notes keep
their formatting (bold, headings, lists); older versions get them as
plain text. Tap **Update and restart** and the new version is
installed for you: the release zip is downloaded from the release page,
unpacked over the plugin folder and KOReader asks to restart. If the
download or the unpacking fails, the releases page opens instead so the
zip can be taken by hand (see *Installation*) — that works from any
older version.

When you publish a release, bump `version` in `_meta.lua` to the tag
without the `v`.

The updater is built to keep working from old installs: repository and
API URL never change, tags stay `vX.Y.Z`, release zips keep the
`tomedown.koplugin/` top-level folder, and settings keys are never
renamed.

## Usage

☰ menu → **Tomedown**:

- **Export current book** — only the open book.
- **Only updated** — exports only the books whose highlights changed since
  the last export (per-book hash).
- **Choose books…** — a list with checkboxes: tick the volumes and export
  just those.
- **Import all books from history** — exports everything found in KOReader's
  reading history.
- **Reload everything to the cloud** — re-uploads every file already in the
  local folder (use it after a failed upload).
- **Settings** — see above.

On a fresh install, the first time you open the menu, Tomedown offers to
import your whole KOReader reading history in one tap (*Export* / *Not now* — the
offer is made only once; the menu entry stays available anyway).

After every export, if *Upload to cloud* is on, the `.md` files and the index
are uploaded to the chosen server automatically. No image folder is created:
only `*.md` files are uploaded (books + `00 - Index.md`).

### Upload retries

While uploading, an *Uploading N files to the cloud…* message stays on screen
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
`Cloud: X uploaded, Y errors` and everything else continues: the files stay in
the local folder, so you can fix the problem and use **Reload everything to
the cloud**. The attempts are also logged:

```
tomedown: upload failed (attempt 1 of 3), retrying in 2 s: <path> 500
```

## File format

```markdown
---
title: "Blackwater"
author: "Michael McDowell"
series: "Blackwater"
series_index: 1
language: "it"
pages: 1140
exported: 2026-09-26
highlights: 150
status: "complete"
progress: "96%"
tags:
  - kindle
  - highlights
  - horror
  - gothic-fiction
---

# Blackwater

*Michael McDowell*

**150 highlights**

## Chapter I

> First highlighted sentence.
> Second line of the same highlight.

- **p. 10** · 02/09/2026 · note: to reread

> Another highlight.

- **p. 12** · 03/09/2026

## Page bookmarks

> Check the epilogue again

- **p. 120** · 04/09/2026
```

- the frontmatter keeps what KOReader knows about the book: `series` and
  `series_index`, `language`, `pages`, the reading `status`
  (`reading` / `abandoned` / `complete`), `progress` and the book's
  keywords appended to `tags`; a field KOReader does not know (ISBN, for
  instance) is simply not there, and unknown fields are omitted
- **only highlights** are exported by default: page bookmarks and deleted
  annotations are left out — tick *Include page bookmarks* in Settings to
  get the `## Page bookmarks` section shown above
- the file name matches KOReader's standard exporter (`Author - Title`), so
  it does not clash with exports you already made
- the page is the stable page number (`pageref`) when available, otherwise
  the running page number
- the index uses wiki links (`[[…]]`), opened natively by Obsidian and by
  most Markdown apps:

  ```markdown
  | [[Michael McDowell - Blackwater|Blackwater]] | Michael McDowell | 150 | 26/09/2026 |
  ```

The sample above is what an English KOReader produces; with an Italian
interface the same text comes out translated (see *Languages*).

## Obsidian (optional)

Obsidian is just one way to read the notes: the files are plain Markdown,
so any editor, reader or wiki works. If you do use Obsidian, only
**Remotely Save** needs configuring here: the Tomedown plugin lives on
KOReader, nothing special has to be installed in Obsidian. The steps below
use Koofr (this README's example cloud); with any other WebDAV server —
Nextcloud, ownCloud, a NAS… — substitute its address and credentials.

1. On Koofr create an app (Security → Applications) and copy the **app
   password**, not the account one.
2. In Obsidian install **Remotely Save** and configure:
   - type: **WebDAV**
   - server: `https://app.koofr.net/dav/Koofr`
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
  in your editor, otherwise your edits disappear next time.
- The plugin **never touches** AnnotationSync's files (`<md5>.json`,
  `settings_sync.json`): it only reads the `.sdr` folders.
- Uploads go through KOReader's *Cloud storage* plugin: if it is not active,
  the local export still works, only the upload is skipped.
- If an upload fails (missing remote folder, no connection), the files stay
  in the local folder: fix it and use **Reload everything to the cloud**.

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
`No chapter`, `N highlights`, `note:`, `Page bookmarks`, `Book index`, table
headers), so your exported notes follow KOReader's language.

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

## Support

If Tomedown saves your reading, buy it a coffee — the next features are
brewed with it.

<p align="center">
  <a href="https://ko-fi.com/imanubdesigner">
    <img src="https://img.shields.io/badge/Ko--fi-Buy%20me%20a%20coffee-171717?style=for-the-badge&logo=ko-fi&logoColor=white" alt="Buy me a coffee on Ko-fi">
  </a>
</p>

## License

GNU Affero General Public License v3.0 — see [LICENSE](LICENSE).
