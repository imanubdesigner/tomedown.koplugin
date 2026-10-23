# Roadmap

What has landed, what comes next, and what waits for release day. This
file exists because the plan used to live in a chat thread and we nearly
lost it.

## Working on the roadmap

Reminders for myself. I used to keep the plan in a chat thread and
nearly lost it, and these rules lived in the same thread, so I am
writing them down here too.

- **I open a branch and a pull request before I start.** The work
  happens there, in the open, and nothing reaches `main` before that.
- **I merge only when I have looked at everything and it is in order.**
  Until then `main` stays exactly where it is.
- **I get my green before I push.** The suite runs locally with the same
  interpreter CI uses (`LUA=lua5.4 ./tests/run.sh` plus `luac5.1 -p`),
  so the CI result is a confirmation, never a surprise.
- **I do one feature at a time.** One branch, one pull request, one
  merge. A feature that does not convince me does not get merged, and
  `main` keeps only what I approved.
- **I do not release until I decide it is release day.** No version
  bump, no tag, no zip, no release before that.
- **I let the numbers tell the truth.** New features mean a minor bump
  (1.1.0), fixes only mean a patch (1.0.1). I make that choice when I
  release.

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
