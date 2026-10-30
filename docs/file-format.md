# File format

[Back to the README](../README.md).

The file as it comes out with **Keep my notes: all books** on. The plain
export (the default) is the same document with the two comments, the heading
and its tag left out.

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
special: 42
status: "complete"
progress: "96%"
tags:
  - ebook
  - highlights
  - horror
  - gothic-fiction
---
## My notes... <!-- tomedown:notes -->

<!-- tomedown:begin body hash=9e7017ad — ⛔ generated below: do not edit inside or updates stop arriving · write your notes above -->

---

# **150 highlights · ★ 42 special**

---

# Chapter I

> First highlighted sentence.
> Second line of the same highlight.

- **p. 10** · 02/09/2026 10:00
  - **NOTE:** *to reread*

> Another highlight.

- **p. 12** · 03/09/2026 11:30

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
| `tags` | `ebook`, `highlights`, and the book's own keywords |
| `cover` | `"covers/Author - Title.jpg"`, only with *Include book covers* |

Every keyword is normalised into a valid Obsidian tag: spaces become `-`, and
only letters, numbers, `-`, `_`, `/` and non-ASCII characters (accents, emoji)
survive, everything else (`;`, `'`, `=`, `[`, `]`…) is dropped. A field
KOReader does not know (ISBN, for instance) is simply not there.

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

![The highlight menu on a fresh selection: Special Highlight sits right under Highlight](../assets/menu/highlights/special_highlights_big_menu.png)

**Tapping an existing highlight** opens the compact edit menu (trash, Style,
Color, …), with the same row at the bottom. The label says what the tap will
do: *Special Highlight* flags it, *Remove Special Highlight* takes the flag
off, and a notification confirms either way.

![The compact edit menu with Special Highlight as the bottom row](../assets/menu/highlights/special_highlights_small_menu.png)
![The compact edit menu with Remove Special Highlight as the bottom row](../assets/menu/highlights/remove_special_highlights_small_menu.png)

The full menu behind the "…" button carries the same row, so a flagged
highlight always offers its own undo and a missed one can still be flagged.

![The full menu on a flagged highlight: Remove Special Highlight](../assets/menu/highlights/remove_special_highlights_big_menu.png)

Callouts are an Obsidian convention. In **Notion** (and in GitHub, which only
knows its own few alerts) the marker imports as the literal text
`[!highlight]` inside the quote: quote, page and note all arrive, only the
coloured box is missing. The word in brackets is the flag itself, there to be
deleted or ignored.

![In Obsidian the flagged highlight renders as a callout while the plain quotes stay quotes](../assets/obsidian/markdown_special_highlights.png)

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

![The exported note in Obsidian: the properties, the rule, the centered cover and your notes as bullets under each highlight](../assets/obsidian/markdown_tags_cover.png)

## The index

The index uses wiki links (`[[…]]`), opened natively by Obsidian and by most
Markdown apps; the body opens with a rule and a stats line (books, highlights,
starred specials) above the table, and with covers enabled the first column
shows the cover image (120×160 box):

```markdown
| <img src="covers/Michael McDowell - Blackwater.jpg" alt="" style="object-fit:contain;width:120px;height:160px"> | [[Michael McDowell - Blackwater\|Blackwater]] | Michael McDowell | Blackwater #1 | Complete<br>▰▰▰▰▰▰▰▰▰▰&nbsp;96% | 26/09/2026 | 150 · ★42 |
```

Without the option the cover column disappears. The Status cell holds whatever
the book has: the status word on the first line, the progress bar under it
with the percentage glued to the bar by a no-break space, so Obsidian can
never drop a two-digit `96%` onto a line of its own, and a dash when it has
none. The last read date has a column of its own, the same goes for a missing
series, and a book with starred highlights shows them as `· ★42` next to the
count.

![Hovering a title in the index opens a preview of the book's note: the bold highlight recap heading, the chapter heading and the highlight](../assets/obsidian/00_index_preview.png)
