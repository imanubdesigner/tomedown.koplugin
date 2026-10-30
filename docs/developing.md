# Developing

[Back to the README](../README.md).

## Languages

Plugin strings are **English** in the code (`_("…")`), as KOReader
conventions require, and are shown **in Italian** when KOReader's interface
is Italian: no setting to change, only KOReader's language matters.

How it works: KOReader only translates its core (`l10n/<lang>/koreader.mo`)
and does **not** load plugin `.po` files automatically, so
`tomedown_i18n.lua` reads `languages/it.po` based on the current language
(`GetText.current_lang`, falling back to *Settings → Language*) and swaps the
texts. On English (or when no translation exists) the original msgid is
used.

The text inside the `.md` files is translated too (titles, `No chapter`,
`N highlights`, `Page bookmarks`, `Book index`, table headers), so your
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

It covers the Markdown render, the `languages/it.po` sync, the runtime
translations and `main.lua` (export, menu, dialogs, fallback servers, uploads
and retries) against a fake KOReader environment (`kostubs/`). It ends with
`luac5.1 -p` on the sources, the same Lua version that runs on the Kindle.
The same suite runs on every push.

## Publishing

GitHub is the canonical home and `main` tracks `origin/main`. Codeberg runs
the same files with the links that name a host rewritten, so it is published
from the commit that is already on GitHub:

```
tools/publish.sh
```

The script pushes `main` to GitHub, then builds the mirror commit from that
tree, with `README.md` and `TUTORIAL.md` replaced by their `.codeberg.md`
copies, and pushes it to Codeberg. It refuses to run when those copies are
stale, so regenerate and commit them first:

```
lua tools/readme_variant.lua README.md > README.codeberg.md
lua tools/readme_variant.lua TUTORIAL.md > TUTORIAL.codeberg.md
```

## Project structure

```
tomedown.koplugin/
├── _meta.lua              plugin name and description
├── main.lua               menu, .sdr reading, export, upload (with retries)
├── tomedown_render.lua    Markdown builder (pure, testable)
├── tomedown_merge.lua     zones, frontmatter and the .bak copies
├── tomedown_cover.lua     cover extraction and resize
├── tomedown_update.lua    update check and install
├── tomedown_i18n.lua      reads languages/<lang>.po (English/Italian)
├── languages/
│   └── it.po              Italian translation (read by tomedown_i18n)
├── docs/                  this manual, one page per topic
├── tests/                 test suite + fake KOReader environment
│   ├── run.sh             runs everything, ends with luac5.1 -p
│   ├── kostubs/           stubs for KOReader's Lua modules
│   └── test_*.lua
└── README.md
```

## Testing on hardware

I test on a Kindle Paperwhite 5 and on a Kindle 4 Non-Touch. The plugin is
plain Lua and touches no hardware, but I cannot try every KOReader build or
every cloud server. If something breaks on yours, a report with the KOReader
version and the `tomedown:` log line helps me more than a description.
