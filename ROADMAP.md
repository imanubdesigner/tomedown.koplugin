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
- **Preserve per book.** With the global switch off, one book may ask
  for its own choice from *Preserve: this book*, in the book's own
  menu: the choice stays stored through later flips of the global
  switch, the book's own stored hash goes so its file is rewritten at
  the next *Export only what changed* while the rest of the library is
  left alone. A book that keeps a zone also names it itself, with
  *Book notes: %1*, the row under the switch: the title is stored for
  that book alone and only its hash goes. The index became a file like
  the others: its own switch, *Preserve: index*, under the global one
  in *Settings → Markdown files*, with *Index notes: %1* under it to
  name the index zone (renaming it goes with every export hash, since
  the index is only rebuilt along with the books), and no book turns
  the switch on any more. Turning it off keeps the zoned index as
  `.bak` before the plain one replaces it. With the global switch on
  it alone is in charge of every file: all of them keep a zone,
  *Notes: %1* names all of them, and the per file rows are not built
  at all (their stored choices wait, untouched, until it goes off
  again). The rows of *Settings* otherwise keep speaking about the
  global switch only: the per book choice, and its title, live in the
  book's own menu.

### Next

#### Turn preserve off for a book

For the reader who took their notes back out and wants the book to go
back to plain exports. Tapping *Preserve: this book*
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
