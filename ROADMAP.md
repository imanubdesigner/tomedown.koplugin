# Roadmap

What has landed, what comes next, and what waits for release day. This
file exists because the plan used to live in a chat thread and we nearly
lost it.

## 1.1

### Done

- **Block IDs for highlights.** Every highlight can carry a `^hl-…` tag
  at the end, so a link in Obsidian jumps straight to it. You switch it
  on from *Block IDs for highlights*.
- **Special highlight markers.** Callout or bold, plus *All highlights
  as Special Highlights* to make every one of them special.
- **A Highlights group in Settings.** All three rows live together now,
  with an icon of their own.
- **Docs and screenshots** for the three rows and for the new menu.

### Next

#### Preserve per book

Right now preserve is a single global switch, read once at the start of
each export (`main.lua:985`) and then used for every book in the loop.
Here is what changes.

- A `preserve_books` map, keyed exactly like `export_records[file]`
  (`main.lua:1039`) which already tracks every book. When a book has its
  own choice, that one wins.
- The global switch stays as the default for books that never chose
  anything. Whoever turned it on under 1.0 keeps it on, and anyone else
  can turn it on for a single book.
- A new row in the book menu: *Preserve manual edits for this book*.
- The rows that depend on preserve (*Merge edits made in the cloud*, *My
  notes...*) follow the book being exported instead of following the
  global value.

#### Turn preserve off for a book

For the reader who took their notes back out and wants the book to go
back to plain exports.

- It drops the book's own choice, so the global default applies again.
- It asks for confirmation first, and says what is about to happen. With
  preserve off, `merge.apply` hands back the generated render straight
  away (`tomedown_merge.lua:537`) and the file gets replaced with no
  `.bak`, so anything written in it is lost.
- Then it rewrites the file clean right away and keeps the old copy as
  `.bak`, rather than waiting for the next export.

### At release

- Bump `_meta.lua` past 1.0.0.
- Tag, zip, release.
- Move the plugin pointer in `contrib` to `724c16f`.

## Later

- Fill in the results table for the 12 block ID cases in Obsidian (how
  links and embeds behave in each one). It is optional, purely
  documentation, and not a blocker for any release.
