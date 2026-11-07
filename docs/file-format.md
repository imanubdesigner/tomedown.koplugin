# File format

[Back to the README](../README.md).

The file as it comes out with **Keep my notes: all books** on. The plain
export (the default) is the same document with the two comments, the heading
and its tag left out.

```markdown
---
title: "The Three Impostors"
author: "Arthur Machen"
language: "en"
pages: 210
exported: 2026-11-05
highlights: 14
special: 2
status: "reading"
progress: "38%"
tags:
  - ebook
  - highlights
  - horror
  - weird-fiction
---
## My notes... <!-- tomedown:notes -->

<!-- tomedown:begin body hash=9e7017ad — ⛔ generated below: do not edit inside or updates stop arriving · write your notes above -->

---

# **14 highlights · ★ 2 special**

---

# Chapter I

> It is an old story; but it is ever new to those who have the eyes to see and the heart to feel.

- **p. 15** · 05/11/2026 10:20
  - **NOTE:** *to reread*

> Another highlight.

- **p. 18** · 05/11/2026 11:30

---

# Page bookmarks

> Check the epilogue again

- **p. 120** · 04/09/2026 08:15

<!-- tomedown:end body -->
```

The sample is what an English KOReader produces; with an Italian interface
the same text comes out translated (see [Languages](developing.md#languages)).

## Frontmatter

| Field | Value |
|---|---|
| `title`, `author` | as KOReader knows them |
| `series`, `series_index` | only when the book belongs to a series |
| `language` | the book's language |
| `pages` | the total page count |
| `exported` | the date of the export |
| `highlights`, `special` | how many highlights, and how many are starred |
| `status` | `reading`, `abandoned` or `complete` |
| `progress` | the reading position, for example `"96%"` |
| `published`, `rating`, `review`, `date_started`, `date_finished`, `collections` | imported from KOReader, only after *Import book info* (see below) |
| `tags` | `ebook`, `highlights`, the book's own keywords and the tags chosen from its menu |
| `tomedown_book_tags` | the book's own tags that this plugin manages, only with *Keep my notes* (see below) |
| `cover` | `"covers/Author - Title.jpg"`, only with *Include book covers* |

Every keyword is normalised into a valid Obsidian tag: spaces become `-`, and
only letters, numbers, `-`, `_`, `/` and non-ASCII characters (accents, emoji)
survive, everything else (`;`, `'`, `=`, `[`, `]`…) is dropped. Obsidian also
requires at least one non-numerical character, so a tag made only of digits
(`1500`) is dropped: use `1500s` or `anno-1500`. A field KOReader does not
know (ISBN, for instance) is simply not there.

Tags chosen from *Current book → Tags: %1* go through the same normalisation
and join the frontmatter at the next export, without duplicates: `ebook`,
`highlights`, the book's keywords and the book's own tags are one list.
Every file with tags chosen from the menu also carries
`tomedown_book_tags`, the ledger of the tags this plugin added for the book:

```yaml
tags:
  - ebook
  - highlights
  - horror
  - psychological
tomedown_book_tags:
  - horror
  - psychological
```

The ledger is a property, not a tag, so Obsidian does not count it in its tag
panel. It is what lets a merge tell the tags the book's menu owns from the
ones you wrote by hand: remove `psychological` from the menu and the next
export drops it from `tags` while `my-own-tag` stays; clear the field and the
ledger goes with the tags it names. With *Keep my notes* off the file is
rewritten whole, so a clear needs no ledger: the old tags leave with the old
file. With it on, a clear writes `tomedown_book_tags: []`, the signal the
merge uses to drop the old managed tags, and the empty ledger is not written
back.

*Current book → Book info → Tags: %1 → Delete tags…* (also reachable from *Tags…* on a
long-press) lists every tag offered in the tag menu: the suggestion cache, the
per-book choices and, for imported books, the shared keywords. Each deletion
asks first, then removes the tag from every managed list, from the imported
keyword lists and from the suggestion cache, and remembers the deletion so
future exports do not re-add it from book metadata; the notes drop it at the
next export. An empty `book_tags` list is kept on purpose, because it is the
signal that clears the old tags from the note; a missing entry would mean the
book never chose. Tags written by hand stay, and if an imported book cannot be
updated the manager names it and leaves its keywords untouched.

## Imported book information

Tomedown can also write the information KOReader already holds about a book:
the rating, the review, the publication date, the reading dates and the
collections. It is **opt-in for every single book**: a normal export carries
none of these fields, so installing a new version of the plugin never rewrites
the notes you already have.

Open *Current book → Book info* and tap *Import book info* (or long-press the book in the
file browser, History or Bookshelf and use the same row). Tomedown asks once,
then writes the fields and from that moment keeps them up to date. The import
works only for a book KOReader has opened.

```yaml
published: "1999-05"
rating: 4
review: "Bello e davvero intenso."
date_started: "2026-09-10"
date_finished: "2026-10-01"
collections:
  - Fantascienza
  - Preferiti
```

| Field | Where it comes from |
|---|---|
| `published` | the date written inside the book file: EPUB/KEPUB, PDF, MOBI/AZW/AZW3/PRC, FB2/FB2.ZIP and CBZ/CBR/CB7/CBT. Years (`1999`) and months (`1999-05`) are kept as they are |
| `rating` | KOReader's rating, 1 to 5 stars |
| `review` | KOReader's review note, folded to a single line in 1.3.0 |
| `date_started` | the first reading session in KOReader's statistics |
| `date_finished` | the date KOReader marked the book complete |
| `collections` | the KOReader collections the book belongs to, sorted |

Every field stays editable from the book's menu: rating, review and status use
KOReader's own panel, tags open the usual editor, and each date has a row of
its own with a reset to the automatic value. Collections are read from
KOReader: Tomedown does not edit them.

With *Settings → Book info → Update book info automatically* on (the default)
a change to the rating, review, status, tags, collections or dates rewrites
that one book about two seconds later. With it off, the fields are written at
the next normal export. *Import book info for all books* does the first import
for the whole library after a confirmation and skips the books set to *Do not
export*.

*Remove imported book info* deletes those fields from the note and stops
Tomedown from managing the book. The note, the highlights and the tags stay;
the current tags become the book's own chosen list.

## Highlights

- **only highlights** are exported by default: page bookmarks and deleted
  annotations are left out. Tick *Include page bookmarks* in Settings to get
  the `# Page bookmarks` section shown above;
- the file name matches KOReader's standard exporter (`Author - Title`), so it
  does not clash with exports you already made;
- the page is the stable page number (`pageref`) when available, otherwise the
  running page number; the date under each highlight includes the time
  (`HH:MM`);
- highlights marked **Special Highlight** are rendered as `> [!highlight]`
  callouts; with *Treat every highlight as special* ticked every highlight
  gets the marker, otherwise only the special ones:

  ```markdown
  > [!highlight]
  > First highlighted sentence.
  > Second line of the same highlight.

  - **p. 10** · 02/09/2026 10:00
    - **NOTE:** *to reread*
  ```

- files exported by an older version of tomedown keep their old look until
  they are rebuilt: the render format is part of the stored hash, so the first
  export after an update rewrites every file in the current format.

### Special highlights

Every highlight can be flagged **Special Highlight** while you read: the row
sits under *Highlight* when you select text, and at the bottom of the edit
menu when you tap an existing highlight. The flag lives inside the book's own
settings and is part of the book's hash, so the next export rewrites that
file; the flagged quote always keeps a marker of its own: the
`> [!highlight]` callout by default, or `> **quote**` once you pick *Bold*
under *Settings → Highlights for Obsidian*. Either way it stays visually
apart from the plain quotes, even when *Treat every highlight as special* is
off. A notification confirms every change.

Marking it costs a single tap. **Selecting text** puts the row right under
*Highlight*: one tap creates the highlight and flags it.

**Tapping an existing highlight** opens the compact edit menu (trash, Style,
Color, …), with the same row at the bottom. The label says what the tap will
do: *Special Highlight* flags it, *Remove Special Highlight* takes the flag
off, and a notification confirms either way.

The full menu behind the "…" button carries the same row, so a flagged
highlight always offers its own undo and a missed one can still be flagged.

Callouts are an Obsidian convention. In **Notion** (and in GitHub, which only
knows its own few alerts) the marker imports as the literal text
`[!highlight]` inside the quote: quote, page and note all arrive, only the
coloured box is missing. The word in brackets is the flag itself, there to be
deleted or ignored.

### Links to a single highlight

*Add link IDs to highlights* (Settings → Highlights for Obsidian) writes a
short id at the end of every quote:

```md
> First highlighted sentence. ^hl-4f2a9c31
```

The id belongs to the highlight, not to the export, so it never moves: the
same quote keeps the same `^hl-` on every re-export, and a link written today
still lands on it tomorrow. Obsidian can then point at one single quote of the
whole library:

- `[[Book title#^hl-4f2a9c31]]` opens that book's note at the quote;
- `![[Book title#^hl-4f2a9c31]]` pulls the quote into the page you are
  writing, wherever that page sits in the vault.

Inside an `> [!highlight]` callout the anchor stays out of sight while you
read, tucked away by the box: click the quote to edit it and `^hl-4f2a9c31` is
there at the end of the line. Reading or editing, the links find it the same.

Off by default: the apps that do not know ids show `^hl-4f2a9c31` as plain
text at the end of the quote, the same way Notion shows `[!highlight]`, so
leave the toggle off if you read the notes anywhere but Obsidian.

## Covers

With *Include book covers* ticked the file also carries
`cover: "covers/Author - Title.jpg"` in the frontmatter and a centered `<img>`
(wrapped in `<p align="center">`) right after the opening rule, with a second
rule between the cover and the `# **150 highlights**` recap heading. The cover
is the embedded one (or the custom cover KOReader knows), resized into an
800×1200 JPEG and dropped from the device after a successful upload; the copy
in the vault is the master one. Obsidian renders such images starting with
**version 1.8.1**.

## The index

The index uses wiki links (`[[…]]`), opened natively by Obsidian and by most
Markdown apps; the body opens with a rule and a stats line (books, highlights,
starred specials) above the table, and with covers enabled the first column
shows the cover image (120×160 box). By default the tags chosen from
*Current book → Tags: %1* sit under the book title, after a thin rule, so a
long list never widens the table:

```markdown
| <img src="covers/Edgar Wallace - The Three Just Men.jpg" alt="" style="object-fit:contain;width:120px;height:160px"> | [[Edgar Wallace - The Three Just Men\|The Three Just Men]]<hr style="margin:12px 0 10px 0;border:0;border-top:1px solid rgba(128,128,128,0.45)">#mystery #crime | Edgar Wallace | The Four Just Men #4 | Complete<br>▰▰▰▰▰▰▰▰▰▰&nbsp;100%<br>★★★★★ | 05/11/2026 | 22 · ★5 |
```

Without the option the cover column disappears. Tags are written as clickable
`#tag` values separated by a space or a line break. A table cell does not wrap,
so a long list is split into lines of at most 24 characters: the table keeps
its width and never needs horizontal scrolling. A library that never used tags
keeps exactly the table it had before. The Status cell holds whatever the book has: the
status word on the first line, the progress bar under it with the percentage
glued to the bar by a no-break space, so Obsidian can never drop a two-digit
`96%` onto a line of its own, and a dash when it has none. The last read date
has a column of its own, the same goes for a missing series, and a book with
starred highlights shows them as `· ★42` next to the count.

*Settings → Files → Index layout* offers three shapes:

| Layout | What changes |
|---|---|
| *Tags under the title* (the default) | the tags sit in the Book cell under the title, after a thin rule; Status and Last read keep separate columns |
| *Tags column* | the tags move to their own column between Series and Status; Status and Last read keep separate columns |
| *Tags column, compact* | the tags keep their column and Status and Last read merge into one, headed *Status · Last read* when both are present |

Changing the layout marks the index as stale: the next export rebuilds
`00 - Index.md` alone, without rewriting a book note. An unknown value falls
back to *Tags under the title*. Upgrading from 1.2.0 applies the default
layout to an existing install and rebuilds the index once.

Each group keeps its heading even when it is alone: *Series books* and
*My books* are always named, in that order, and a lone table is no longer
mistaken for a duplicate of the one above. *My books* is ordered by author and
then title by default. *Settings → Files → Index order* switches it to title,
last read or highlights: last read and highlights run newest and most first,
with author and title as tie-breakers, and a book never read goes last. Series
books keep their own order by series and position whatever the setting says.

While at least one book is being read, a *Reading now* section repeats those
books above the series and *My books* tables, latest opening first. It is on
by default and *Settings → Files → Show Reading now in the index* takes it
away. A book set to *Book visibility: hidden from the index* or *not
exported*, from its own menu or from the file dialog, is left out of every
table; when every exported book is hidden the index says so instead of
claiming the library is empty.
