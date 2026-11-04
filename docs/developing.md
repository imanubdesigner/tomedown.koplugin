# Developing

[Back to the README](../README.md).

## Languages

Plugin strings are **English** in the code (`_("…")`), as KOReader
conventions require. They are shown in the reader's language when a
catalog exists: Italian, German, French, Spanish and Brazilian
Portuguese. No setting to change, only KOReader's language matters.

How it works: KOReader only translates its core (`l10n/<lang>/koreader.mo`)
and does **not** load plugin `.po` files automatically, so
`tomedown_i18n.lua` reads `languages/<lang>.po` based on the current
language (`GetText.current_lang`, falling back to *Settings → Language*)
and swaps the texts. Regional codes fall back to the two-letter file
(`de_AT` reads `de.po`). On English (or when no translation exists) the
original msgid is used.

The text inside the `.md` files is translated too (titles, `No chapter`,
`N highlights`, `Page bookmarks`, `Book index`, table headers), so your
exported notes follow KOReader's language.

To fix or add a translation: edit the catalog (msgid = English source,
msgstr = translated text) and restart KOReader. It is standard gettext:
for another language copy `languages/it.po` to `languages/<code>.po`,
translate every `msgstr` and run `./tests/run.sh`, which checks every
catalog against the source strings.

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

It covers the Markdown render, the merge and frontmatter ownership, the
book-info modules (metadata sources, publication dates, import and removal),
every language catalog, the runtime translations and the plugin modules
(export, menu, dialogs, fallback servers, uploads and retries) against a fake
KOReader environment (`kostubs/`). It ends with `luac5.1 -p` on the sources,
the same Lua version that runs on the Kindle. The same suite runs on every
push.

## Release zip

The release asset is built from a commit, never from a folder copied by
hand:

```
tools/release-zip.sh            # HEAD
tools/release-zip.sh 1.2.0      # a branch, tag or commit
```

It refuses a dirty working tree, reads the version from `_meta.lua` at that
ref and writes `~/Documents/Tomedown-Bidirectional/tomedown.koplugin-v<version>.zip`
(set `TOMEDOWN_RELEASE_DIR` to change the folder). The archive may contain
only `LICENSE`, `_meta.lua`, `assets/logo.png`, `main.lua`, the
`tomedown_*.lua` modules and `languages/*.po`: never `docs/`, the tests, the
menu screenshots or the repository banners. The script compares that list
with the archive contents, runs `luac5.1 -p` on every Lua file and prints the
sha256 to record with the release.

## Project structure

```
tomedown.koplugin/
├── _meta.lua              plugin name and description
├── main.lua               plugin class, settings, server getters, reader events
├── tomedown_shared.lua    settings accessors and write-zone file helpers
├── tomedown_menu.lua      main menu, Settings groups, About, book menu
├── tomedown_export.lua    .sdr reading, Markdown export and index
├── tomedown_upload.lua    cloud upload, retries, pending queue and Status
├── tomedown_render.lua    Markdown builder (pure, testable)
├── tomedown_merge.lua     zones, frontmatter and the .bak copies
├── tomedown_metadata.lua  imported book info, sources and automatic updates
├── tomedown_pubdate.lua   publication dates out of the book files
├── tomedown_cover.lua     cover extraction and resize
├── tomedown_update.lua    update check and install
├── tomedown_i18n.lua      reads languages/<lang>.po (English fallback)
├── languages/
│   ├── it.po              Italian translation (read by tomedown_i18n)
│   ├── de.po              German translation
│   ├── fr.po              French translation
│   ├── es.po              Spanish translation
│   └── pt_BR.po           Brazilian Portuguese translation
├── docs/                  this manual, one page per topic
├── tests/                 test suite + fake KOReader environment
│   ├── run.sh             runs everything, ends with luac5.1 -p
│   ├── kostubs/           stubs for KOReader's Lua modules
│   └── test_*.lua
├── tools/
│   └── release-zip.sh     builds the release asset from a commit
└── README.md
```

## Testing on hardware

I test on a Kindle Paperwhite 5 and on a Kindle 4 Non-Touch. The plugin is
plain Lua and touches no hardware, but I cannot try every KOReader build or
every cloud server. If something breaks on yours, a report with the KOReader
version and the `tomedown:` log line helps me more than a description.
