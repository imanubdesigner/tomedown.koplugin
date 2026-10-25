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
- **Turning preserve off for one book asks first.** The row says what
  it is about to do before doing it, and confirming rewrites the file
  plain there and then instead of waiting for the next export, keeping
  what the file held as `.bak`. The copy is now written by the export
  itself for every book that goes from zoned to plain, which is what
  the index already did: with preserve off `merge.apply` hands back the
  generated render straight (`tomedown_merge.lua:537`) and never flags
  a backup, so nothing was written for a book until here.
- **A backup never eats another one.** Every `.bak` went to the same
  fixed name, so the next backup overwrote the last one, and the copy
  thrown away could be the one holding what the reader wrote by hand:
  turning the global switch back on exported a file that
  `merge.apply` flags with `backup = true` (`tomedown_merge.lua:561`),
  the plain content replaced the note in the older `.bak`, and it was
  gone. `keepBackup()` now moves an existing `.bak` to `.bak.1` first,
  so there are two copies at most per file and the older one always
  survives. The same shape for the books, the index and the cloud
  fold, which had four copies of that block and now call one helper.
- **Our own file is not backed up any more.** The copy that broke the
  rule above was our own: turning the global switch back on found the
  plain export on disk, `rebuildable()` claimed it
  (`tomedown_merge.lua:308`) and `merge.apply` returned `legacy` with
  `backup = true` (line 561), so a file we had written a run earlier
  took the slot of the copy holding the reader's notes. Every write
  now stores its bytes (`export_records[file].disk`, `index_disk` for
  the index) and `ownCopy()` skips the backup while the file still
  holds them, when nothing of the reader's can be in it. A file from
  before this field existed is still backed up, on the safe side.
- **Preserve coming back on brings the backup back.** Whoever turns
  preserve on again used to find a clean file, with their notes waiting
  in the `.bak` and nothing reading it. The export now folds that copy
  back in, for the books and for the index, but only when the file on
  disk is the plain export this plugin wrote itself (`ownCopy()`) and
  the copy is zoned: a file edited meanwhile is never replaced by an
  older snapshot, it is merged as it is and the copy is left alone.
  Silent, no new box, no new string, and nothing to decide in the
  Discussion about it after all.

### Next

#### Managing the .bak copies

The copies are bounded: two at most beside each file, `.bak` and
`.bak.1`, rotated so a newer one never throws the older away, and the
upload never takes them (it collects `*.md` and `covers/*.jpg`). What
is missing is seeing them from inside the plugin.

- One row inside the book, for the reader who is already in it: it
  shows that book's copy and deletes it, one confirmation at a time.
  Never all of them together, they may be the only copy of what was
  written by hand.
- One row in *Markdown files* that lists every `.bak` of the folder,
  so they can be reviewed and removed from outside any book.
- Uploading them and moving them around waits: KOReader's file browser
  already does both, and the copies travel along anyway if the vault
  is synced.

### At release

- Bump `_meta.lua` past 1.0.0.
- Tag, zip, release.
- Move the plugin pointer in `contrib` to `724c16f`.

## Later

- Fill in the results table for the 12 block ID cases in Obsidian (how
  links and embeds behave in each one). It is optional, purely
  documentation, and not a blocker for any release.
