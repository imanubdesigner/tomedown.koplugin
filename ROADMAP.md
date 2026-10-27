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

- **One menu, five groups.** The rows that name the open book now live
  together in *Current book*: the per book switch, its heading and the
  copies. The main menu is the same everywhere, with *Export this book*,
  *Export new and changed books*, *Export all books*, *Choose books…*,
  *Current book*, *Upload all files again*, *Last export*, *Settings*,
  *About*. Settings is five groups, *Files*, *Cloud*, *My notes*,
  *Highlights for Obsidian* and *Updates* (with *Beta versions* inside),
  and the merge row moved to *My notes* where the notes are. No export,
  merge or upload code changed.
- **Add link IDs to highlights.** Every highlight can carry a `^hl-…` tag
  at the end, so a link in Obsidian jumps straight to it. You switch it
  on from *Add link IDs to highlights*.
- **Special highlight markers.** Callout or bold, plus *Treat every highlight
  as special* to make every one of them special.
- **A Highlights for Obsidian group in Settings.** All three rows live together now,
  with an icon of their own.
- **Docs and screenshots** for the three rows and for the new menu.
- **Keep my notes per book.** With the global switch off, one book may ask
  for its own choice from *Keep my notes in this book*, in the book's own
  menu: the choice stays stored through later flips of the global
  switch, the book's own stored hash goes so its file is rewritten at
  the next *Export new and changed books* while the rest of the library is
  left alone. A book that keeps a zone also names it itself, with
  *Notes heading: %1*, the row under the switch: the title is stored for
  that book alone and only its hash goes. The index became a file like
  the others: its own switch, *Keep my notes: index*, under the global one
  in *Settings → My notes*, with *Index notes heading: %1* under it to
  name the index zone (renaming it goes with every export hash, since
  the index is only rebuilt along with the books), and no book turns
  the switch on any more. Turning it off keeps the zoned index as
  `.bak` before the plain one replaces it. With the global switch on
  it alone is in charge of every file: all of them keep a zone,
  *Notes heading: %1* names all of them, and the per file rows are not built
  at all (their stored choices wait, untouched, until it goes off
  again). The rows of *Settings* otherwise keep speaking about the
  global switch only: the per book choice, and its title, live in the
  book's own menu.
- **Turning Keep my notes off for one book asks first.** The row says what
  it is about to do before doing it, and confirming rewrites the file
  plain there and then instead of waiting for the next export, keeping
  what the file held as `.bak`. The copy is now written by the export
  itself for every book that goes from zoned to plain, which is what
  the index already did: with Keep my notes off `merge.apply` hands back the
  generated render straight (`tomedown_merge.lua:537`) and never flags
  a backup, so nothing was written for a book until here.
- **The `.bak` is the reader's file, set aside.** Every `.bak` went to
  the same fixed name and later rotated into `.bak.1`, so a third
  backup of any kind (a plain file typed into while Keep my notes was off, a
  block edited inside its comments) could push the copy holding the
  notes out, and on / off / on / off / on lost them for good. Now
  `.bak` has one job: when Keep my notes goes off, `parkZone()` keeps the
  zoned file there, one copy, the latest (whatever the old one held was
  folded back into the file when Keep my notes came back, so replacing it
  loses nothing, and a deleted note stays deleted). Turning Keep my notes on
  restores from it whenever the file on disk has no zone, whether or
  not it is the plain export we wrote. Everything else the rewrite
  would destroy goes to `.bak.1` through `keepSafety()`, one slot that
  never touches `.bak`; an identical copy takes no slot, and both are
  written through a temp file and a rename, so a failed write leaves
  what was there (and should the rename be refused, the copy is written
  in place instead). When a copy cannot be written at all, the file it
  was meant to protect is left as it is and the export reports it. The
  test in section 21 runs the sequence with edits on every step.
  A card that has run the beta.1 may hold the notes in `.bak.1` behind
  a newer copy without a zone: the first export swaps the two (section
  22), once, so the notes come back and nothing is overwritten.
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
- **Keep my notes coming back on brings the notes set aside back.** Whoever
  turns Keep my notes on again used to find a clean file, with their notes
  waiting in the `.bak` and nothing reading it. The export now folds
  that copy back in, for the books and for the index, whenever the file
  on disk has no zone and the `.bak` has one. If the plain file was not
  the one we wrote (typed into while Keep my notes was off) the notes still
  come back from the `.bak`, and the typed text is kept as `.bak.1`
  instead of deciding which of the two wins. Silent, no new box, no new
  string.
- **Two devices on one cloud folder do not lose the notes set aside.** A
  cloud copy edited elsewhere can become the base of the export, and
  until now the notes waiting in this device's `.bak` were left out of
  the file, then overwritten at the next export. Now, when the base comes
  from the cloud and has a zone while this device holds a plain file
  with a `.bak` that holds notes set aside, the two zones are joined: the cloud text keeps
  its place and its order, and every paragraph that exists only in the
  copy set aside follows it. A paragraph already present, or the same note
  reworded in the cloud, is not repeated. The copy the rewrite replaces
  is kept first (the plain file when it holds the reader's own text,
  the cloud copy otherwise), and the same road runs in the flush of the
  queued uploads, after the beta.1 slots have been repaired. If the
  join cannot be made, the export is held back and nothing is written.
  The trade-off is deliberate: a note deleted in Obsidian while this
  device still had it set aside comes back, because the alternative is
  losing it in silence. Sections 23 and 24 run the export and the flush.

### Next

#### Managing the .bak copies

The copies are bounded: two at most beside each file, `.bak` (the zoned file set aside
) and `.bak.1` (the safety copy), each with a fixed job, and
the upload never takes them (it collects `*.md` and `covers/*.jpg`).

- **Done: one row inside the book**, for the reader who is already in
  it. *Backup copies…* appears in the book's menu only while that book
  has a copy beside its file (the export record names the file), lists
  the copies one by one with the day they were saved, and deletes one
  only after a question that says what it holds. Never all together:
  they may be the only copy of what was written by hand. When the book
  has no zone right now and the copy holds the notes set aside, the question
  says the notes are in it and go with it. Nothing else is touched by
  the delete, and the row leaves with the last copy (section 25).
- A list of every `.bak` of the folder, to review and remove them from
  outside any book: postponed. With two copies of clear roles it adds
  little over the row inside the book.
- Uploading them and moving them around waits: KOReader's file browser
  already does both, and the copies travel along anyway if the vault
  is synced.

#### Known limit: two devices on one cloud folder

The notes set aside are no longer one of the losses: the export joins the
two zones and keeps a copy of what it replaces (see *Done*). What
remains is the price of that choice. There is no common ancestor to tell
a note deleted in Obsidian from a note lost in the cloud, so the join
brings back a note this device still had set aside even when the reader
meant to delete it. It is visible in the file, and deleting it again is
enough. A three-way merge that remembers the last zone both sides
agreed on would tell the two cases apart, and waits.

### At release

- Bump `_meta.lua` to the version being tagged (the beta included).
- Tag, zip, release.
- Move the plugin pointer in `contrib` to the tagged commit.

## Later

- Fill in the results table for the 12 block ID cases in Obsidian (how
  links and embeds behave in each one). It is optional, purely
  documentation, and not a blocker for any release.
