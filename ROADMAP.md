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
- **Preserve per book.** The global switch stays the default, and one
  book may ask for its own choice from *Preserve manual edits for this
  book*, in the book's own menu: the choice wins over the global one
  and outlives later flips of it, the book's own stored hash goes so
  its file is rewritten at the next *Export only what changed* while
  the rest of the library is left alone, and `00 - Index.md` keeps its
  zone while any book keeps one. The rows of *Settings* keep speaking
  about the global switch only: the per book choice lives in the
  book's own menu.

### Next

#### Turn preserve off for a book

For the reader who took their notes back out and wants the book to go
back to plain exports. Tapping *Preserve manual edits for this book*
again already stores the explicit off and rewrites the file plain at
the next export; what is left is the safety around it.

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
