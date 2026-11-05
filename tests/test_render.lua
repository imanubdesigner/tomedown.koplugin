-- tests for tomedown_render.lua (almost pure module: only tomedown_i18n)
local HERE = arg[0]:match("^(.*)/") or "."
package.path = HERE .. "/?.lua;" .. package.path
local T = require("common")
local render = require("tomedown_render")

local book = {
    title = "The Three Impostors",
    author = "Arthur Machen",
    exported = "2026-09-26",
    count = 2,
    annotations = {
        {
            text = "Prima frase.",
            note = "nota utente",
            chapter = "Capitolo I",
            page = "10",
            date = "02/09/2026",
        },
        {
            text = "Seconda riga.",
            chapter = "Capitolo II",
            page = "38",
            date = "03/09/2026",
        },
    },
}

local md = render.buildBookMd(book)
T.check(md:sub(1, 4) == "---\n", "frontmatter opens with ---")
T.check(T.contains(md, 'title: "The Three Impostors"'), "frontmatter title")
T.check(T.contains(md, 'author: "Arthur Machen"'), "frontmatter author")
T.check(T.contains(md, "exported: 2026-09-26"), "frontmatter exported")
T.check(T.contains(md, "highlights: 2"), "frontmatter highlights")
T.check(T.contains(md, "special: 0"), "frontmatter special count")
T.check(T.contains(md, "  - ebook"), "tag ebook")
T.check(not T.contains(md, "kindle"), "the old kindle tag is gone")
T.check(T.contains(md, "  - highlights"), "tag highlights")
T.check(not T.contains(md, "series:"), "no series line when absent")
T.check(not T.contains(md, "language:"), "no language line when absent")
T.check(not T.contains(md, "pages:"), "no pages line when absent")
T.check(not T.contains(md, "status:"), "no status line when absent")
T.check(not T.contains(md, "progress:"), "no progress line when absent")
T.check(not T.contains(md, "# The Three Impostors"), "no h1 in the body")
T.check(not T.contains(md, "*Arthur Machen*"), "author stays in the frontmatter only")
T.check(T.contains(md, "# **2 highlights**"), "highlight count as a heading")
T.check(T.contains(md, "\n# Capitolo I"), "first chapter")
T.check(T.contains(md, "\n# Capitolo II"), "second chapter")
T.check(T.contains(md, "> Prima frase."), "quote 1")
T.check(T.contains(md, "> Seconda riga."), "quote 2")
T.check(T.contains(md, "- **p. 10** · 02/09/2026\n  - **NOTE:** *nota utente*"),
    "meta row with page, date and note")
T.check(T.contains(md, "- **p. 38** · 03/09/2026"), "meta row without note")
local i10 = md:find("- **p. 10**", 1, true)
local i38 = md:find("- **p. 38**", 1, true)
T.check(i10 < i38, "highlights stay in page order")
T.check(md:sub(-1) == "\n", "ends with a newline")
T.check(not T.contains(md, "cover"), "no cover in the markdown")
T.check(not T.contains(md, "![]("), "no image in the markdown")

-- separators: the frontmatter rule, under the stats, between chapters,
-- never at the end of the file
T.check(T.contains(md, "# **2 highlights**\n\n---\n\n# Capitolo I"),
    "separator between the stats and the first chapter")
T.check(T.contains(md, "- **p. 10** · 02/09/2026\n  - **NOTE:** *nota utente*\n\n---\n\n# Capitolo II"),
    "separator when the chapter changes")
-- markers carry a hash; strip it when asserting literal marker text
local plain_md = (md:gsub(" hash=%w+", ""))
T.check(T.contains(plain_md, "---\n\n\n" .. render.beginMarker("body")
    .. "\n\n---\n\n# **2 highlights**"),
    "the body opens with a rule after two blank lines, inside the body region")
local doubled = select(2, md:gsub("%-%-%-\n\n%-%-%-", ""))
T.check(doubled == 0,
    "the frontmatter rule and the body rule never touch: " .. doubled)
T.check(md:match("%-%-%-%s*$") == nil, "no separator at the end of the file")

-- region markers: a single generated region per file, always paired
local begins = {}
for name in md:gmatch("<!%-%- tomedown:begin ([%w_]+)[^\n]*%-%->") do
    begins[#begins + 1] = name
end
T.check(table.concat(begins, ",") == "body",
    "one book region, named body: " .. table.concat(begins, ","))
local ends = select(2, md:gsub("<!%-%- tomedown:end[^\n]*%-%->", ""))
T.check(ends == 1, "one end marker: " .. ends)
local body_tail = render.endMarker("body")
T.check(md:sub(-#body_tail - 1) == body_tail .. "\n",
    "the file ends on the end marker, no trailing blank line")
T.check(T.contains(md, 'tomedown: "1.0"'), "format stamp in the book frontmatter")

-- markers: the begin carries the digest of the block, the end is plain
T.check(T.contains(md, "hash="), "the begin marker carries a hash")
T.check(T.contains(md, "⛔ generated below: do not edit inside"),
    "the begin marker tells the block is generated")
T.check(render.endMarker("body") == "<!-- tomedown:end body -->",
    "the end marker is plain")
T.check(render.digest("  x  ") == render.digest("x"),
    "the digest ignores surrounding whitespace")
T.check(#render.digest("x") == 8, "the digest is the short hash")
T.check(not T.contains(render.beginMarker("body"), "hash="),
    "a marker built without a hash stays hash-free")

-- the notes heading: titles the writable zone above the marker,
-- outside the hashed block, and only appears with opts.notes_title
T.check(not T.contains(md, "tomedown:notes"),
    "no heading without opts.notes_title")
local headed = render.buildBookMd(book, { notes_title = "My notes..." })
T.check(T.contains(headed, "## My notes... <!-- tomedown:notes -->"),
    "the heading titles the zone")
T.check(headed:find('---\n## My notes... <!-- tomedown:notes -->\n\n\n'
        .. "<!-- tomedown:begin body", 1, true) ~= nil,
    "rule, heading, two blank lines, marker")
T.check(select(2, headed:gsub("tomedown:notes", "")) == 1, "one heading only")
T.check(headed:match("tomedown:begin body hash=(%w+)")
        == md:match("tomedown:begin body hash=(%w+)"),
    "the heading sits outside the hashed block")
T.check(not T.contains(render.buildBookMd(book, { notes_title = "" }),
    "tomedown:notes"), "an empty title exports no heading")
local headed_index = render.buildIndexMd({}, { notes_title = "Appunti" })
T.check(headed_index:find('---\n## Appunti <!-- tomedown:notes -->\n\n\n'
        .. "<!-- tomedown:begin index", 1, true) ~= nil,
    "the index gets the heading too")

-- the invitation of older builds is never written again: the room
-- alone opens the zone, and opts.notes_invite is not honoured anymore
local INVITE = render.notesInvite()
T.check(not T.contains(headed, INVITE),
    "no invitation in the book file")
local invited = render.buildBookMd(book,
    { notes_title = "My notes...", notes_invite = true })
T.check(invited == headed, "opts.notes_invite is ignored since 1.0")
T.check(invited:find('---\n## My notes... <!-- tomedown:notes -->\n\n\n'
        .. "<!-- tomedown:begin body", 1, true) ~= nil,
    "the zone opens with the heading and the room to write")
T.check(invited:match("tomedown:begin body hash=(%w+)")
        == md:match("tomedown:begin body hash=(%w+)"),
    "the room lives outside the hashed block")
local invited_index = render.buildIndexMd({},
    { notes_title = "Appunti", notes_invite = true })
T.check(invited_index:find('---\n## Appunti <!-- tomedown:notes -->\n\n\n'
        .. "<!-- tomedown:begin index", 1, true) ~= nil
        and not T.contains(invited_index, INVITE),
    "the index zone opens with the room, without the invitation")
local bare_invited = render.buildIndexMd({}, { notes_invite = true })
T.check(not T.contains(bare_invited, "tomedown:notes")
        and not T.contains(bare_invited, INVITE),
    "no heading and no invitation either")

-- markers=false is the export behind preserve off: no handles at all
-- and no heading either — nothing to merge (every run overwrites) and
-- nothing to write under (the next export would take it away)
local unmarked = render.buildBookMd(book,
    { notes_title = "My notes...", markers = false })
T.check(not T.contains(unmarked, "tomedown:begin")
        and not T.contains(unmarked, "tomedown:end")
        and not T.contains(unmarked, "tomedown:notes")
        and not T.contains(unmarked, "## My notes"),
    "markers=false writes no markers, no tag and no heading")
T.check(not T.contains(unmarked, INVITE),
    "nor the invitation of older builds")
-- apart from the handles and the zone framed around them the two
-- documents are byte for byte the same
local dehandled = (headed:gsub("<!%-%- tomedown:begin body[^\n]*%-%->\n", ""))
dehandled = (dehandled:gsub("<!%-%- tomedown:end body[^\n]*%-%->\n?", ""))
dehandled = (dehandled:gsub(
    "## My notes%.%.%. <!%-%- tomedown:notes %-%->\n\n\n", "", 1))
T.check(dehandled == unmarked,
    "markers=false only takes the handles and the zone's frame out")
local unmarked_index = render.buildIndexMd({},
    { notes_title = "Appunti", markers = false })
T.check(not T.contains(unmarked_index, "## Appunti")
        and not T.contains(unmarked_index, "tomedown:begin"),
    "the plain index carries no heading and no handles")
T.check(not T.contains(render.buildBookMd(book, { markers = false }),
    "tomedown:begin"), "no heading, no handles either")

-- no chapters: the body has only the HIGHLIGHTS heading
local noChapters = render.buildBookMd({
    title = "Senza capitoli",
    count = 1,
    annotations = { { text = "Solo testo", page = "1" } },
})
local body_h1 = select(2, noChapters:gsub("\n# ", ""))
T.check(body_h1 == 1, "without chapters only HIGHLIGHTS is an H1: " .. body_h1)
T.check(noChapters:match("%-%-%-%s*$") == nil, "chapterless: no separator at the end")

-- mixed chapters: annotations without a chapter use the given label
local mixed = render.buildBookMd({
    title = "Misto",
    count = 2,
    annotations = {
        { text = "A", chapter = "Capitolo I" },
        { text = "B" },
    },
}, { no_chapter_label = "Senza capitolo" })
T.check(T.contains(mixed, "\n# Capitolo I"), "chapter present")
T.check(T.contains(mixed, "\n# Senza capitolo"), "fallback label")
T.check(not T.contains(mixed, "\n## No chapter"), "no leftover English msgid")

-- multiline note flattened onto one line
local multi = render.buildBookMd({
    title = "Note",
    count = 1,
    annotations = { { text = "X", note = "riga1\nriga2" } },
})
T.check(T.contains(multi, "**NOTE:** *riga1*\n  *riga2*"), "multiline note keeps its lines")
T.check(not T.contains(multi, "riga1 riga2"), "the lines are not flattened")

-- a blank line inside the note becomes a paragraph break
local para = render.buildBookMd({
    title = "Par",
    count = 1,
    annotations = { { text = "Y", note = "a\n\nb" } },
})
T.check(T.contains(para, "**NOTE:** *a*\n\n  *b*"), "blank line in the note")

-- a note without page/date: the note is the meta row
local only_note = render.buildBookMd({
    title = "SoloNota",
    count = 1,
    annotations = { { text = "Z", note = "solo nota" } },
})
T.check(T.contains(only_note, "- **NOTE:** *solo nota*"), "note-only annotation")

-- nested under a meta row: the continuation lines indent deeper
local nest = render.buildBookMd({
    title = "Nido", count = 1,
    annotations = { { text = "W", page = 5, date = "01/02/2026", note = "a\nb" } },
})
T.check(T.contains(nest, "- **p. 5** · 01/02/2026\n  - **NOTE:** *a*\n    *b*"),
    "note nested under the meta row")

-- no page/date/note: ellipsis
local bare = render.buildBookMd({
    title = "Nudo",
    count = 1,
    annotations = { { text = "Y" } },
})
T.check(T.contains(bare, "- …"), "empty meta with ellipsis")

-- escaping YAML
local escaped = render.buildBookMd({
    title = 'Dice "ciao"\nalla fine',
    author = "A\\B",
    count = 0,
    annotations = {},
})
T.check(T.contains(escaped, 'title: "Dice \\"ciao\\" alla fine"'), "quotes and newline in the title")
T.check(T.contains(escaped, 'author: "A\\\\B"'), "backslash in the author")

-- ---------------------------------------------------------- rich frontmatter
local rich = render.buildBookMd({
    title = "The Three Impostors",
    author = "Arthur Machen",
    series = "The Three Impostors",
    series_index = 3,
    language = "it",
    pages = 1140,
    exported = "2026-09-26",
    count = 2,
    status = "reading",
    progress = "96%",
    keywords = { "horror", "gothic-fiction" },
    annotations = { { text = "Riga.", page = "1" } },
})
T.check(T.contains(rich, 'series: "The Three Impostors"'), "frontmatter series")
T.check(T.contains(rich, "series_index: 3"), "series_index as a number, unquoted")
T.check(T.contains(rich, 'language: "it"'), "frontmatter language")
T.check(T.contains(rich, "pages: 1140"), "frontmatter pages")
T.check(T.contains(rich, 'status: "reading"'), "frontmatter status")
T.check(T.contains(rich, 'progress: "96%"'), "frontmatter progress")
local fm = rich:match("^%-%-%-\n(.-)\n%-%-%-\n")
local seq = {
    "title:", "author:", "series:", "series_index:", "language:", "pages:",
    "exported:", "highlights:", "status:", "progress:", "tags:",
}
local last, order_ok = 0, fm ~= nil
for __, key in ipairs(seq) do
    local pos = fm and fm:find(key, 1, true)
    if not pos or pos < last then
        order_ok = false
    end
    last = pos or last
end
T.check(order_ok, "frontmatter keys in the documented order")
local t1 = rich:find("  - ebook", 1, true)
local t2 = rich:find("  - highlights", 1, true)
local t3 = rich:find("  - horror", 1, true)
local t4 = rich:find("  - gothic-fiction", 1, true)
T.check(t1 and t2 and t3 and t4 and t1 < t2 and t2 < t3 and t3 < t4,
    "tags: ebook, highlights, then the book keywords")
for __, key in ipairs({ "published:", "rating:", "review:", "date_started:",
        "date_finished:", "collections:" }) do
    T.check(not rich:find(key, 1, true),
        "a normal book carries no imported field: " .. key)
end

-- imported book information: present only when the reader imported this
-- one book, in a fixed order before the tags
local importedBook = render.buildBookMd({
    title = "The Three Impostors",
    author = "Arthur Machen",
    exported = "2026-09-26",
    count = 1,
    status = "complete",
    published = "1999-05",
    rating = 4,
    review = "Bello e davvero intenso.",
    date_started = "2026-09-10",
    date_finished = "2026-10-01",
    collections = { "Fantascienza", "Da leggere" },
    keywords = { "horror" },
    annotations = { { text = "Riga.", page = "1" } },
})
T.check(T.contains(importedBook, 'published: "1999-05"'),
    "the publication date is quoted")
T.check(T.contains(importedBook, "rating: 4"), "the rating is a number")
T.check(T.contains(importedBook, 'review: "Bello e davvero intenso."'),
    "the review is a quoted one-liner")
T.check(T.contains(importedBook, 'date_started: "2026-09-10"'),
    "the reading start date")
T.check(T.contains(importedBook, 'date_finished: "2026-10-01"'),
    "the reading finish date")
T.check(T.contains(importedBook, "collections:\n  - Fantascienza\n  - Da leggere"),
    "the collections are a list")
local importedFm = importedBook:match("^%-%-%-\n(.-)\n%-%-%-\n")
local importedOrder = { "status:", "published:", "rating:", "review:",
    "date_started:", "date_finished:", "collections:", "tags:" }
local lastImported = 0
for __, key in ipairs(importedOrder) do
    local pos = importedFm and importedFm:find(key, 1, true)
    if not pos or pos < lastImported then
        lastImported = -1
        break
    end
    lastImported = pos
end
T.check(lastImported ~= -1,
    "the imported fields sit between progress and tags")
T.check(T.contains(importedBook, '  - "rating"') == false,
    "the rating field itself is never mistaken for a tag")

-- per book tags: chosen at the book menu, washed in with ebook,
-- highlights and the keywords, and receipted in the internal ledger
local bookTagged = render.buildBookMd({
    title = "The Three Impostors",
    keywords = { "horror" },
    tags = { "Horror", "Psicologico", "ebook" },
    tags_managed = true,
    count = 1,
    annotations = { { text = "X" } },
})
local b1 = bookTagged:find("  - ebook", 1, true)
local b2 = bookTagged:find("  - highlights", 1, true)
local b3 = bookTagged:find("  - horror", 1, true)
local b4 = bookTagged:find("  - Psicologico", 1, true)
T.check(b1 and b2 and b3 and b4 and b1 < b2 and b2 < b3 and b3 < b4,
    "the book tags join the list after the keywords, without duplicates")
T.check(select(2, (bookTagged:match("tags:\n(.-)\ntomedown_book_tags:")
        or ""):gsub("%- ebook", "")) == 1,
    "ebook is written once even when the book chose it too")
T.check(T.contains(bookTagged,
        "  - Psicologico\ntomedown_book_tags:\n  - Horror\n  - Psicologico\n  - ebook\n---"),
    "the ledger lists only the tags the menu manages")
T.check(not T.contains(bookTagged, "tomedown_book_tags:\n  - horror"),
    "a keyword is not in the ledger")
T.check(T.contains(render.buildBookMd({
    title = "T", tags = { "Horror" }, tags_managed = true,
    count = 0, annotations = {},
}, { markers = false }), "tomedown_book_tags:\n  - Horror"),
    "the ledger of chosen tags is written without markers too")

-- a tag that is only digits is not valid for Obsidian, and a tag YAML
-- would type as a number or a boolean is quoted so the list stays strings
local yamlTags = render.buildBookMd({
    title = "T",
    keywords = { "1500", "1500s", "true", "no", "null", "2026-11-01" },
    count = 0,
    annotations = {},
})
T.check(not T.contains(yamlTags, "  - 1500\n"),
    "a numeric-only keyword never reaches the frontmatter")
T.check(T.contains(yamlTags, '  - "1500s"'),
    "a digit-led tag is quoted for YAML")
T.check(T.contains(yamlTags, '  - "true"'), "a boolean-looking tag is quoted")
T.check(T.contains(yamlTags, '  - "no"'), "a yes/no-looking tag is quoted")
T.check(T.contains(yamlTags, '  - "null"'), "a null-looking tag is quoted")
T.check(T.contains(yamlTags, '  - "2026-11-01"'), "a date-like tag is quoted")
local numericBook = render.buildBookMd({
    title = "T", tags = { "Storico", "1500", "Paranormale" },
    tags_managed = true, count = 0, annotations = {},
})
T.check(not T.contains(numericBook, "1500"),
    "a numeric tag stays out of tags and ledger")
T.check(T.contains(numericBook, "  - Storico")
        and T.contains(numericBook, "  - Paranormale"),
    "the valid tags around it still render")

local bookUnmanaged = render.buildBookMd({
    title = "T", keywords = { "horror" }, count = 0, annotations = {},
})
T.check(not T.contains(bookUnmanaged, "tomedown_book_tags"),
    "a book that never chose writes no ledger")

-- cleared tags: the empty ledger is the signal the merge needs, and it
-- exists only with markers (without them the whole file is rewritten)
local cleared = render.buildBookMd({
    title = "T", tags = {}, tags_managed = true, count = 0, annotations = {},
})
T.check(T.contains(cleared, "tomedown_book_tags: []"),
    "cleared tags leave an empty ledger")
T.check(not T.contains(render.buildBookMd({
    title = "T", tags = {}, tags_managed = true, count = 0, annotations = {},
}, { markers = false }), "tomedown_book_tags"),
    "no ledger without markers: the file is replaced whole")

local idxBook = render.buildBookMd({
    title = "T",
    series = "S",
    series_index = "1.5",
    annotations = {},
})
T.check(T.contains(idxBook, 'series_index: "1.5"'), "string series_index is quoted")
T.check(not T.contains(idxBook, "status:"), "status still absent without data")

local weird = render.buildBookMd({
    title = "T",
    keywords = { "Sci-Fi & Fantasy" },
    annotations = {},
})
T.check(T.contains(weird, "  - Sci-Fi-Fantasy"),
    "a dirty keyword is sanitized, not quoted as it was")

-- ------------------------------------------------------------ page bookmarks
local bmBook = render.buildBookMd({
    title = "T",
    count = 1,
    annotations = { { text = "Evidenziato", page = "1" } },
    bookmarks = {
        { text = "Nota segnalibro", page = "5", date = "01/09/2026" },
        { page = "7", date = "02/09/2026" },
    },
})
T.check(T.contains(bmBook, "\n# Page bookmarks"), "bookmarks heading")
T.check(T.contains(bmBook, "> Nota segnalibro"), "bookmark note quoted")
T.check(T.contains(bmBook, "- **p. 5** · 01/09/2026"), "bookmark meta row")
T.check(T.contains(bmBook, "- **p. 7** · 02/09/2026"), "bookmark without note: meta only")
T.check(T.contains(bmBook, "# **1 highlight**"), "highlight count kept")
local iHl = bmBook:find("> Evidenziato", 1, true)
local iSect = bmBook:find("\n# Page bookmarks", 1, true)
T.check(iHl and iSect and iHl < iSect, "the section comes after the highlights")
T.check(T.contains(bmBook, "\n\n---\n\n# Page bookmarks"),
    "separator before the bookmarks section")
local quoted = select(2, bmBook:gsub("> ", ""))
T.check(quoted == 2, "the highlight and the bookmark note: " .. quoted)

local onlyBookmarks = render.buildBookMd({
    title = "Solo bm",
    count = 0,
    annotations = {},
    bookmarks = { { page = "1", date = "01/01/2026" } },
})
T.check(not T.contains(onlyBookmarks, "# **0 highlight"), "no zero count line")
T.check(T.contains(onlyBookmarks, "\n# Page bookmarks"), "bookmark-only book gets the section")
T.check(select(2, onlyBookmarks:gsub("\n%-%-%-\n", "")) == 2,
    "bookmark-only: frontmatter rule and body rule, nothing else")
T.check(not T.contains(md, "Page bookmarks"), "no section without bookmarks")

-- ---------------------------------------------------------------- cover
local withCover = render.buildBookMd(book, { cover = "covers/The Three Impostors.jpg" })
T.check(T.contains(withCover, 'cover: "covers/The Three Impostors.jpg"'), "cover in the frontmatter")
T.check(T.contains(withCover,
    '<p align="center"><img src="covers/The Three Impostors.jpg" alt="" style="object-fit:contain;width:400px;height:533px"></p>'),
    "cover embedded in the body, centered")
T.check(T.contains(withCover, "</p>\n\n---\n\n# **2 highlights**"),
    "the rule between the cover and the highlights heading")
local img_pos = withCover:find("<img ", 1, true)
local hl_pos = withCover:find("# **2 highlights", 1, true)
T.check(img_pos and hl_pos and img_pos < hl_pos, "the cover sits before the highlights heading")
local doubledCover = select(2, withCover:gsub("%-%-%-\n\n%-%-%-", ""))
T.check(doubledCover == 0,
    "with a cover no two rules touch: " .. doubledCover)
T.check(render.coverImg('a"b.jpg', 90, 120):find("a&quot;b.jpg", 1, true) ~= nil,
    "a quote in the path is escaped for the attribute")

-- ---------------------------------------------------------------- callout
local plainCallout = render.buildBookMd({
    title = "P",
    count = 1,
    annotations = { { text = "Riga uno\nRiga due" } },
})
T.check(not T.contains(plainCallout, "[!highlight]"), "no callout by default")
local allCallout = render.buildBookMd({
    title = "P",
    count = 2,
    annotations = { { text = "Uno" }, { text = "Due", special = true } },
}, { callout = true })
T.check(select(2, allCallout:gsub("%[!highlight%]", "")) == 2,
    "the option turns every highlight into a callout")
T.check(T.contains(allCallout, "> [!highlight]\n> Uno"), "callout marker before the text")
T.check(T.contains(allCallout, "> [!highlight]\n> Due"), "multi-line text stays inside the callout")
local onlySpecial = render.buildBookMd({
    title = "P",
    count = 2,
    annotations = { { text = "Uno" }, { text = "Due", special = true } },
})
T.check(select(2, onlySpecial:gsub("%[!highlight%]", "")) == 1,
    "without the option only the special one is a callout")
T.check(T.contains(onlySpecial, "> [!highlight]\n> Due"), "special one rendered as callout")
T.check(T.contains(onlySpecial, "\n> Uno\n"), "the plain one stays a blockquote")

-- ---------------------------------------------------------------- index
local index = render.buildIndexMd({}, {})
T.check(T.contains(index, 'title: "Book index"'), "index default title in the frontmatter")
T.check(not T.contains(index, "# Book index"), "no h1 in the index")
T.check(T.contains(index, "_No exported books with highlights._"), "empty index")
T.check(T.contains(index, "  - index"), "tag index")
T.check(T.contains(index, "---\n"), "index frontmatter")
T.check(T.contains(index, "  - ebook"), "tag ebook in the index")
T.check(not T.contains(index, "kindle"), "the old kindle tag is gone from the index")
local plain_index = (index:gsub(" hash=%w+", ""))
T.check(T.contains(plain_index, "---\n\n\n" .. render.beginMarker("index")
    .. "\n\n---\n\n_No exported"),
    "the empty index opens the body with a rule after two blank lines")
T.check(index:match("tomedown: \"1%.0\"") ~= nil, "format stamp in the index frontmatter")
T.check(select(2, index:gsub("<!%-%- tomedown:end[^\n]*%-%->", "")) == 1,
    "the empty index still closes its region")
local index_tail = render.endMarker("index")
T.check(index:sub(-#index_tail - 1) == index_tail .. "\n",
    "the index ends on its end marker, no trailing blank line")
T.check(not T.contains(index, "click a title"), "no stats line without books")

local rows = render.buildIndexMd({
    {
        link = "Arthur Machen - The Three Impostors",
        title = "The Three Impostors",
        author = "Arthur Machen",
        count = 2,
    },
    {
        link = "Altro Autore - Altro",
        title = "Altro",
        author = "A | B",
        count = 0,
    },
}, { title = "Indice dei libri", exported = "2026-09-26" })

T.check(not T.contains(rows, "# Indice dei libri"), "no h1 in the index")
T.check(T.contains(rows, 'title: "Indice dei libri"'), "index frontmatter")
T.check(T.contains(rows, "| Book | Author | Highlights |"),
    "table header: adaptive columns, no export date")
T.check(not T.contains(rows, "| Cover |"), "no cover column when the option is off")
T.check(not T.contains(rows, "Last export"),
    "the export date column is gone")
T.check(T.contains(rows, "|:---|:---|---:|"), "table separators")
T.check(T.contains(rows, "[[Arthur Machen - The Three Impostors\\|The Three Impostors]]"), "wikilink with alias")
T.check(T.contains(rows, "| Arthur Machen | 2 |"), "author and count in the row")
T.check(T.contains(rows, "| A \\| B | 0 |"), "pipes escaped, count zero")
local order = rows:find("[[Arthur Machen - The Three Impostors\\|The Three Impostors]]", 1, true)
local order2 = rows:find("[[Altro Autore - Altro\\|Altro]]", 1, true)
T.check(order2 < order, "author order is the default for My books")
T.check(T.contains(rows, "### My books"),
    "the plain group keeps its heading even when it is alone")
T.check(not T.contains(rows, "### Series books"),
    "no series heading without series books")
local plain_rows = (rows:gsub(" hash=%w+", ""))
T.check(T.contains(plain_rows,
    "---\n\n\n" .. render.beginMarker("index")
    .. "\n\n---\n\n**2 books** · **2 highlights**\n\n### My books\n\n| Book |"),
    "the stats line, the heading and then the table")

local single = render.buildIndexMd({
    {
        link = "Autore - Solo",
        title = "Solo",
        author = "Autore",
        count = 1,
    },
}, { title = "Indice", exported = "2026-10-02" })
T.check(T.contains(single, "**1 book** · **1 highlight**"),
    "singular stats line with one book and one highlight")

-- alias: no characters that break the wikilink
local clean = render.alias("Titolo [x] #y | z ^w")
T.check(not clean:find("[", 1, true) and not clean:find("|", 1, true),
    "alias without brackets or pipes")
T.check(not clean:find("%s%s"), "alias without double spaces")
T.check(render.alias("") == "", "empty alias")
T.check(render.alias(nil) == "", "alias with nil")

-- title with pipe: the index alias stays valid
local pipeIndex = render.buildIndexMd({
    { link = "Base", title = "A | B", author = "Aut", count = 1 },
})
local line = pipeIndex:match("| %[[^\n]+")
T.check(line and T.contains(line, "[[Base\\|A B]]"),
    "title with pipe: the alias stays a single valid wikilink")
T.check(line and line:gsub("[^|]", "") == "|||||",
    "the row has the right number of columns (4 separators + the escaped one)")

-- index v3: cover column, series and status cells
local covered = render.buildIndexMd({
    {
        link = "Autore - Titolo",
        title = "Titolo",
        author = "Autore",
        series = "Saga",
        series_index = 2,
        status = "reading",
        count = 3,
        cover = "covers/Autore - Titolo.jpg",
    },
}, { show_covers = true })
T.check(T.contains(covered,
    "| Cover | Book | Author | Series | Status | Highlights |"),
    "header with the cover column, no export date")
T.check(T.contains(covered,
    '<img src="covers/Autore - Titolo.jpg" alt="" style="object-fit:contain;width:120px;height:160px">'),
    "cover cell in the index row")
T.check(T.contains(covered, "| Saga #2 |"), "series cell with the series index")
T.check(T.contains(covered, "| Reading | 3 |"), "status cell translated to English")
T.check(T.contains(covered, "### Reading now"),
    "a book being read gets the short section above the index")
T.check(T.contains(covered, "### Series books"),
    "a lone series group keeps its heading")
T.check(not T.contains(covered, "### My books"),
    "no plain heading without plain books")
-- a book without a series/status/cover drops those columns, no dash
local sparse = render.buildIndexMd({
    { link = "B", title = "B", author = "Au", count = 1 },
}, { show_covers = false })
T.check(T.contains(sparse, "| [[B\\|B]] | Au | 1 |"),
    "missing series/status drop their columns, no cover cell")

-- Reading now: repeats the books being read above the full index, latest
-- opening first, and disappears when empty or when the setting is off.
local readingIndex = render.buildIndexMd({
    { link = "Autore - Primo", title = "Primo", author = "Autore",
        status = "reading", count = 1, last_read_sort = 10,
        progress = "20%" },
    { link = "Autore - Secondo", title = "Secondo", author = "Autore",
        status = "reading", count = 2, last_read_sort = 20,
        progress = "70%" },
    { link = "Altro - Finito", title = "Finito", author = "Altro",
        status = "complete", count = 3, series = "Saga" },
})
local readingSection = readingIndex:match("### Reading now(.-)###")
T.check(readingSection ~= nil, "the Reading now section is there")
local firstReading = readingSection and readingSection:find("\\|Primo]]", 1, true)
local secondReading = readingSection and readingSection:find("\\|Secondo]]", 1, true)
T.check(firstReading and secondReading and secondReading < firstReading,
    "Reading now sorts by the latest opening")
T.check(readingSection and T.contains(readingSection, "Reading<br>")
        and T.contains(readingSection, "▰▰▱▱▱▱▱▱▱▱&nbsp;20%"),
    "Reading now keeps the status and the progress bar")
T.check(readingIndex:find("### Reading now", 1, true)
        < readingIndex:find("### Series books", 1, true),
    "Reading now sits above the series and My books tables")
T.check(not T.contains(render.buildIndexMd({
    { link = "B", title = "B", author = "Au", status = "complete", count = 1 },
}, {}), "### Reading now"), "no section when nothing is being read")
T.check(not T.contains(render.buildIndexMd({
    { link = "B", title = "B", author = "Au", status = "reading", count = 1 },
}, { reading_now = false }), "### Reading now"),
    "the setting removes the section")
local hiddenEmpty = render.buildIndexMd({}, { hidden_books = 2 })
T.check(T.contains(hiddenEmpty, "_Every exported book is hidden from the index._"),
    "the empty state names the hidden books")
T.check(not T.contains(hiddenEmpty, "No exported books"),
    "the old empty message is not used when every book is hidden")

-- index v4: per-book tags. The default keeps them under the title,
-- after a thin rule with room around it; the old column is the second
-- layout, and the third folds the date into the status cell.
local indexTags = render.buildIndexMd({
    {
        link = "Au - Tagged", title = "Tagged", author = "Au", series = "Saga",
        series_index = 1, tags = { "Horror", "Psicologico" },
        status = "reading", count = 1,
    },
    { link = "Au - Plain", title = "Plain", author = "Au", count = 1 },
}, { index_layout = "tags_column" })
T.check(T.contains(indexTags,
        "| Book | Author | Series | Tags | Status | Highlights |"),
    "the tags column sits between Series and Status")
T.check(T.contains(indexTags,
        "| [[Au - Tagged\\|Tagged]] | Au | Saga #1 | #Horror #Psicologico |"),
    "the tags are clickable, separated by a space")
T.check(T.contains(indexTags, "| Book | Author | Highlights |"),
    "a table with no tags of its own keeps no Tags column")
T.check(not T.contains(indexTags, "| [[Au - Plain\\|Plain]] | Au | — | 1 |"),
    "the untagged table gets no empty Tags cell")

local tagsBelow = render.buildIndexMd({
    {
        link = "Au - Tagged", title = "Tagged", author = "Au",
        tags = { "Horror", "Psicologico" }, count = 1,
    },
}, {})
T.check(not T.contains(tagsBelow, "| Tags |"),
    "the default layout has no Tags column to widen the table")
T.check(T.contains(tagsBelow,
        "[[Au - Tagged\\|Tagged]]<hr style=\"margin:12px 0 10px 0;"
        .. "border:0;border-top:1px solid rgba(128,128,128,0.45)\">"
        .. "#Horror #Psicologico |"),
    "the tags sit under the title after a spaced thin rule in the same cell")

local wrappedTags = render.buildIndexMd({
    {
        link = "Jerome K. Jerome - Three Men in a Boat", title = "Three Men in a Boat", author = "A", count = 1,
        tags = { "Strega", "Paranormale", "Vecchie", "football", "1500s" },
    },
}, {})
T.check(T.contains(wrappedTags,
        "#Strega #Paranormale<br>#Vecchie #football<br>#1500s"),
    "a long tag list wraps inside the cell instead of widening it")

local dirtyIndexTags = render.buildIndexMd({
    {
        link = "B", title = "B", author = "A", count = 1,
        tags = { "Horror tales", "1500", "horror-tales", "" },
    },
}, { index_layout = "tags_column" })
T.check(T.contains(dirtyIndexTags, "| #Horror-tales |"),
    "raw index tags are sanitized, deduplicated and numbers dropped")

-- the compact layout folds Status and Last read into a single column
local compactIndex = render.buildIndexMd({
    {
        link = "Au - One", title = "One", author = "Au", status = "reading",
        count = 2, progress = "6%", last_read = "2026-10-01",
    },
    {
        link = "Au - Two", title = "Two", author = "Au", count = 1,
        status = "complete",
    },
}, { index_layout = "tags_column_compact" })
T.check(T.contains(compactIndex, "| Status · Last read | Highlights |"),
    "the compact layout has one status and date column")
T.check(T.contains(compactIndex,
        "| Reading · 01/10/2026<br>▰▱▱▱▱▱▱▱▱▱&nbsp;6% | 2 |"),
    "the date joins the status word, the bar keeps its own line")
T.check(T.contains(compactIndex, "| Complete | 1 |"),
    "a book with no date shows the status alone in the merged column")
local compactSingle = render.buildIndexMd({
    { link = "B", title = "B", author = "A", count = 1,
        last_read = "2026-10-02" },
}, { index_layout = "tags_column_compact" })
T.check(T.contains(compactSingle, "| Last read | Highlights |"),
    "the merged column drops the missing half from its title")
T.check(T.contains(compactSingle, "| 02/10/2026 | 1 |"),
    "a date alone still fills the merged column")
local bogusLayout = render.buildIndexMd({
    { link = "B", title = "B", author = "A", count = 1,
        tags = { "Horror" } },
}, { index_layout = "bogus" })
T.check(T.contains(bogusLayout, "### My books")
        and not T.contains(bogusLayout, "| Tags |"),
    "an unknown layout falls back to tags under the title")

-- imported book rating stars in the index
T.check(render.stars(nil) == nil and render.stars(0) == nil
        and render.stars(6) == nil,
    "stars returns nil outside 1..5")
T.check(render.stars(4) == "★★★★☆" and render.stars(5) == "★★★★★",
    "stars formats 1..5 as five-star glyphs")
local ratedIndex = render.buildIndexMd({
    {
        link = "Au - Rated", title = "Rated", author = "Au",
        status = "complete", progress = "100%", rating = 4, count = 3,
    },
}, {})
T.check(T.contains(ratedIndex, "Complete<br>▰▰▰▰▰▰▰▰▰▰&nbsp;100%<br>★★★★☆"),
    "an imported rating appears under the status and progress bar")

-- index v3: two groups, each with its own columns and a heading
local split = render.buildIndexMd({
    {
        link = "Z - First", title = "First", author = "Zoe",
        series = "Saga", series_index = 1, count = 1,
    },
    { link = "A - Solo", title = "Solo", author = "Al", count = 4 },
}, {})
T.check(T.contains(split, "### Series books"), "heading for the series group")
T.check(T.contains(split, "### My books"), "heading for the plain group")
T.check(T.contains(split, "| Book | Author | Series | Highlights |"),
    "the series table keeps the Series column")
T.check(T.contains(split, "| Book | Author | Highlights |"),
    "the plain table has no Series column")
T.check(T.contains(split, "| [[A - Solo\\|Solo]] | Al | 4 |"),
    "the plain row carries only its own cells")

-- series books read by series, then by position in it
local sorted = render.buildIndexMd({
    { link = "B", title = "B", series = "Alpha", series_index = 2, count = 1 },
    { link = "C", title = "C", series = "Zeta", series_index = 1, count = 1 },
    { link = "A", title = "A", series = "Alpha", series_index = 1, count = 1 },
}, {})
local posA = sorted:find("[[A\\|A]]", 1, true)
local posB = sorted:find("[[B\\|B]]", 1, true)
local posC = sorted:find("[[C\\|C]]", 1, true)
T.check(posA and posB and posC and posA < posB and posB < posC,
    "series books read by series, then by position")

-- My books: the four index orders, descending for last read and count
local orderBooks = {
    { link = "A", title = "Zeta", author = "Anna", count = 1,
        last_read = "2026-01-01", last_read_sort = 100 },
    { link = "B", title = "Alfa", author = "Bruno", count = 2,
        last_read = "2026-03-01", last_read_sort = 300 },
    { link = "C", title = "Beta", author = "Carla", count = 5,
        last_read = "2026-02-01", last_read_sort = 200 },
}
local function positions(md, links)
    local out = {}
    for __, link in ipairs(links) do
        out[#out + 1] = md:find("[[" .. link .. "\\|", 1, true)
    end
    for i = 2, #out do
        if not (out[i - 1] and out[i] and out[i - 1] < out[i]) then
            return false
        end
    end
    return #out > 0
end
T.check(positions(render.buildIndexMd(orderBooks, {}), { "A", "B", "C" }),
    "default order: author")
T.check(positions(render.buildIndexMd(orderBooks, { index_order = "title" }),
        { "B", "C", "A" }), "title order")
T.check(positions(render.buildIndexMd(orderBooks, { index_order = "last_read" }),
        { "B", "C", "A" }), "last read, newest first")
T.check(positions(render.buildIndexMd(orderBooks, { index_order = "highlights" }),
        { "C", "B", "A" }), "highlights, most first")
local tie = render.buildIndexMd({
    { link = "T2", title = "Beta", author = "Anna", count = 1 },
    { link = "T1", title = "Alfa", author = "Anna", count = 1 },
}, {})
T.check(positions(tie, { "T1", "T2" }),
    "ties fall back to the title in author order")
local unread = render.buildIndexMd({
    { link = "Old", title = "Old", author = "A", count = 1,
        last_read_sort = 100 },
    { link = "Never", title = "Never", author = "B", count = 1 },
}, { index_order = "last_read" })
T.check(positions(unread, { "Old", "Never" }),
    "a book never read goes last in last-read order")
local withSeries = render.buildIndexMd({
    { link = "P1", title = "Zeta", author = "Anna", count = 1 },
    { link = "S2", title = "Second", series = "Saga", series_index = 2, count = 1 },
    { link = "P2", title = "Alfa", author = "Bruno", count = 1 },
    { link = "S1", title = "First", series = "Saga", series_index = 1, count = 1 },
}, { index_order = "title" })
local s1 = withSeries:find("[[S1\\|First]]", 1, true)
local s2 = withSeries:find("[[S2\\|Second]]", 1, true)
local p1 = withSeries:find("[[P2\\|Alfa]]", 1, true)
local p2 = withSeries:find("[[P1\\|Zeta]]", 1, true)
T.check(s1 and s2 and s1 < s2, "a title order leaves the series in its own order")
T.check(p1 and p2 and p1 < p2, "and sorts My books by title")

-- index v3: progress, last read and the special count
local rich = render.buildIndexMd({
    {
        link = "Au - One", title = "One", author = "Au", status = "reading",
        count = 5, special = 2, progress = "6%", last_read = "2026-10-01",
    },
    {
        link = "Au - Two", title = "Two", author = "Au",
        count = 1, progress = "", last_read = "",
    },
}, {})
T.check(T.contains(rich,
    "**2 books** · **6 highlights** · **★ 2 special**"),
    "the stats line counts the specials")
T.check(T.contains(rich, "| Book | Author | Status | Last read | Highlights |"),
    "the percent rides with the bar, the date gets a column of its own")
T.check(T.contains(rich,
    "| Reading<br>▰▱▱▱▱▱▱▱▱▱&nbsp;6% | 01/10/2026 |"),
    "the status word over the bar, the percent stuck to it with a nbsp")
T.check(T.contains(rich, "| 5 · ★2 |"),
    "special count in the highlights cell")
T.check(T.contains(rich, "| Au | — | — | 1 |"),
    "a book with no handle at all gets a dash in both cells")
T.check(not T.contains(rich, "Last export"),
    "the export date is not among the columns")

-- fmtDate
T.check(render.fmtDate("2026-09-02 10:00:00") == "02/09/2026", "ISO date in Italian format")
T.check(render.fmtDate("2026-12-31") == "31/12/2026", "date without time")
T.check(render.fmtDate("01/02/2026") == "01/02/2026", "already formatted date passes through")
T.check(render.fmtDate(nil) == "", "nil date is empty")
T.check(render.fmtDate(42) == "", "non-string date is empty")

-- fmtDateTime
T.check(render.fmtDateTime("2026-09-02 10:00:00") == "02/09/2026 10:00",
    "ISO datetime keeps the time")
T.check(render.fmtDateTime("2026-12-31") == "31/12/2026",
    "date without time falls back to fmtDate")
T.check(render.fmtDateTime("01/02/2026") == "01/02/2026",
    "already formatted date passes through")
T.check(render.fmtDateTime(nil) == "", "nil datetime is empty")
T.check(render.fmtDateTime(42) == "", "non-string datetime is empty")

-- series_index only when the book belongs to a series
local orphan = render.buildBookMd({
    title = "Orfano",
    series_index = 4,
    count = 1,
    annotations = { { text = "X" } },
})
T.check(not T.contains(orphan, "series_index:"), "no series_index without a series")
local named = render.buildBookMd({
    title = "Serie senza numero",
    series = "Saga",
    count = 1,
    annotations = { { text = "X" } },
})
T.check(T.contains(named, 'series: "Saga"'), "series without an index is kept")
T.check(not T.contains(named, "series_index:"), "no index line when the index is unknown")

-- sanitizeTag: a keyword has to become a valid Obsidian tag
T.check(render.sanitizeTag("Occult & Supernatural") == "Occult-Supernatural",
    "spaces to dashes, & dropped")
T.check(render.sanitizeTag("Horror tales: American") == "Horror-tales-American",
    "colon dropped, the dashes around it collapsed")
T.check(render.sanitizeTag("American Horror tales") == "American-Horror-tales",
    "plain multi-word keyword")
T.check(render.sanitizeTag("  spaced   out  ") == "spaced-out",
    "run of spaces and edge spaces trimmed")
T.check(render.sanitizeTag("!!!") == "", "only forbidden characters: empty result")
T.check(render.sanitizeTag(nil) == "", "nil is empty, not an error")
T.check(render.sanitizeTag("gothic-fiction") == "gothic-fiction",
    "an already valid keyword is untouched")
T.check(render.sanitizeTag("Favole dell'ORRORE!") == "Favole-dellORRORE",
    "case kept, apostrophe and ! dropped")
T.check(render.sanitizeTag("Séries noires") == "Séries-noires",
    "accents kept")
T.check(render.sanitizeTag("fantasy/sci-fi") == "fantasy/sci-fi",
    "the nested tag separator survives")
T.check(render.sanitizeTag("Horror tales; American") == "Horror-tales-American",
    "semicolon dropped: Obsidian rejects it although its docs list allows it")
T.check(render.sanitizeTag("Scifi [2020] = cult") == "Scifi-2020-cult",
    "brackets and equals dropped, dashes around them collapsed")
T.check(render.sanitizeTag("C# tips") == "C-tips",
    "hash dropped")
T.check(render.sanitizeTag("a\194\160b") == "a-b",
    "non-breaking space becomes a dash")
T.check(render.sanitizeTag("fantasy \240\159\144\137") == "fantasy-\240\159\144\137",
    "emoji (multi-byte) survives")
T.check(render.sanitizeTag("1500") == "",
    "a tag made only of digits is not a tag for Obsidian")
T.check(render.sanitizeTag("1984") == "", "another numeric-only tag is dropped")
T.check(render.sanitizeTag("1500s") == "1500s",
    "a digit-led tag with a letter survives")
T.check(render.sanitizeTag("2026-11-01") == "2026-11-01",
    "a date-like tag survives, the hyphen is not numerical")
local clean_once = render.sanitizeTag("Occult & Supernatural")
T.check(render.sanitizeTag(clean_once) == clean_once, "sanitizeTag is idempotent")

-- parseTagList: the comma separated field of the book menu
local parsed = render.parseTagList("Horror, psicologico, Horror, , Sci-Fi!")
T.check(#parsed == 3 and parsed[1] == "Horror" and parsed[2] == "psicologico"
        and parsed[3] == "Sci-Fi",
    "tags split on commas, sanitized, deduplicated case-insensitively")
T.check(#render.parseTagList("  ,  , ") == 0, "empty field: no tags")
T.check(#render.parseTagList(nil) == 0, "nil field: no tags")
T.check(render.parseTagList("A\nB")[2] == "B", "newlines split tags too")
local numericTags, numericRejected = render.parseTagList(
    "Horror, 1500, 1984, Psicologico, 1500")
T.check(#numericTags == 2 and numericTags[1] == "Horror"
        and numericTags[2] == "Psicologico",
    "numeric-only tags are dropped from the field")
T.check(#numericRejected == 2 and numericRejected[1] == "1500"
        and numericRejected[2] == "1984",
    "the dropped numbers are reported once each")
local digitLed, digitRejected = render.parseTagList("1500s")
T.check(#digitLed == 1 and digitLed[1] == "1500s"
        and #digitRejected == 0,
    "a valid digit-led tag is not reported as dropped")

-- through the exporter: dirty keywords render sanitized, dead ones vanish
local tagged = render.buildBookMd({
    title = "The Three Impostors",
    keywords = { "Occult & Supernatural", "!!!", "American Horror tales" },
    count = 1,
    annotations = { { text = "X" } },
})
T.check(T.contains(tagged, "  - Occult-Supernatural"), "the rendered tag is sanitized")
T.check(T.contains(tagged, "  - American-Horror-tales"),
    "the second dirty keyword too")
T.check(not T.contains(tagged, "Occult &"), "no raw keyword reaches the frontmatter")
T.check(not T.contains(tagged, "- !!!"), "the dead keyword is not exported")

-- ------------------------------------------------------- reading bar
T.check(render.progressBar("0%") == "▱▱▱▱▱▱▱▱▱▱",
    "a book never opened gets an empty bar")
T.check(render.progressBar("4%") == "▰▱▱▱▱▱▱▱▱▱",
    "progress below 5% still lights one cell")
T.check(render.progressBar("25%") == "▰▰▰▱▱▱▱▱▱▱",
    "25% rounds to three cells")
T.check(render.progressBar("150%") == "▰▰▰▰▰▰▰▰▰▰",
    "the bar never runs past ten cells")
T.check(render.progressBar("") == nil and render.progressBar(nil) == nil,
    "no bar without a percentage")
T.check(render.progressPct("0%") == "0%" and render.progressPct("4%") == "4%"
        and render.progressPct("25%") == "25%" and render.progressPct("150%") == "150%",
    "the percentage keeps its own shape")
T.check(render.progressPct("") == nil and render.progressPct(nil) == nil,
    "no percentage without a progress")

-- Block ID and special marker cases for tests/test_render.lua: paste this
-- block before the final T.finish("test_render"). It only needs `render`
-- and `T`, both already in scope there (the md5 stub gives deterministic
-- ids). The existing test that pins `> [!highlight]` for a special stays
-- valid: callout is still the default marker.

do
    local function ann(text, seed, pos, extra)
        local a = { text = text, page = 1, date = "15/10/2026 11:59",
            id_seed = seed, id_pos = pos, id_text = text }
        for k, v in pairs(extra or {}) do a[k] = v end
        return a
    end
    local function book(list)
        return { title = "T", author = "A", annotations = list }
    end
    local function ids(md)
        local out = {}
        for id in md:gmatch(" %^(hl%-[%w%-]+)\n") do
            out[#out + 1] = id
        end
        return out
    end

    local A = function() return ann("one", "2026-10-15 11:59:23", "/p1") end
    local B = function() return ann("two", "2026-10-15 12:10:00", "/p2") end
    local C = function() return ann("three", "2026-10-16 09:00:00", "/p3") end

    -- 1. option off: no ids
    local off = render.buildBookMd(book({ A(), B() }), {})
    T.check(not off:find("%^hl%-"), "block ids: none when the option is off")

    -- 9. option off: the output is what it always was
    local nil_opt = render.buildBookMd(book({ A(), B() }), {})
    local false_opt = render.buildBookMd(book({ A(), B() }), { block_ids = false })
    T.check(nil_opt == false_opt, "block ids: absent and false options render the same")
    T.check(T.contains(nil_opt, "> one\n\n- **p. 1**"),
        "block ids: option off keeps the quote followed by a blank line and the metadata")

    -- 2. option on: one id per highlight, `hl-` plus eight hex digits
    local on = render.buildBookMd(book({ A(), B() }), { block_ids = true })
    local first = ids(on)
    T.check(#first == 2, "block ids: one per highlight")
    T.check(first[1]:match("^hl%-%x%x%x%x%x%x%x%x$") ~= nil,
        "block ids: hl- followed by eight hex digits")
    T.check(T.contains(on, "> one ^" .. first[1] .. "\n\n- **p. 1**"),
        "block ids: the id ends the last line of the quote")

    -- 3. identical between two exports
    local again = ids(render.buildBookMd(book({ A(), B() }), { block_ids = true }))
    T.check(again[1] == first[1] and again[2] == first[2],
        "block ids: identical across exports")

    -- 4. unchanged when other highlights come or go
    local plus = ids(render.buildBookMd(book({ A(), B(), C() }), { block_ids = true }))
    local minus = ids(render.buildBookMd(book({ B() }), { block_ids = true }))
    T.check(plus[1] == first[1] and plus[2] == first[2],
        "block ids: unchanged when a highlight is added")
    T.check(minus[1] == first[2], "block ids: unchanged when another is removed")

    -- 5. same creation time: distinct ids; the one holding the plain id
    --    is the first in rendering order, and the other takes it when
    --    that one goes away (accepted)
    local X = function() return ann("x", "2026-10-15 11:59:23", "/a") end
    local Y = function() return ann("y", "2026-10-15 11:59:23", "/b") end
    local both = ids(render.buildBookMd(book({ X(), Y() }), { block_ids = true }))
    T.check(both[1] ~= both[2], "block ids: same creation time, distinct ids")
    local only_x = ids(render.buildBookMd(book({ X() }), { block_ids = true }))
    local only_y = ids(render.buildBookMd(book({ Y() }), { block_ids = true }))
    T.check(only_x[1] == both[1], "block ids: the first keeps the plain id")
    T.check(only_y[1] == only_x[1],
        "block ids: the survivor takes the plain id when the first is gone")

    -- 6. no creation time: still stable
    local F = function() return ann("no date", nil, "/z") end
    local f1 = ids(render.buildBookMd(book({ F() }), { block_ids = true }))
    local f2 = ids(render.buildBookMd(book({ F(), A() }), { block_ids = true }))
    T.check(f1[1] == f2[1], "block ids: stable without a creation time")

    -- 7. same time and same position: numeric suffix
    local P = ann("p", "2026-10-15 11:59:23", "/s")
    local Q = ann("q", "2026-10-15 11:59:23", "/s")
    local R = ann("r", "2026-10-15 11:59:23", "/s")
    local s = ids(render.buildBookMd(book({ P, Q, R }), { block_ids = true }))
    T.check(s[1] ~= s[2] and s[2] ~= s[3] and s[3]:match("%-2$") ~= nil,
        "block ids: residual clash gets a numeric suffix")

    -- 8. callout: the id ends the last line inside the callout
    local sp = render.buildBookMd(book({ ann("spec", "2026-10-15 11:59:23", "/p1",
        { special = true }) }), { block_ids = true })
    T.check(sp:match("> %[!highlight%]\n> spec %^hl%-%x+\n\n%- %*%*p%. 1%*%*") ~= nil,
        "block ids: in a callout the id ends the last quote line")
    local multi = render.buildBookMd(book({ ann("one\ntwo", "2026-10-15 11:59:23", "/p1") }),
        { block_ids = true, callout = true })
    T.check(T.contains(multi, "> one\n> two ^hl-"),
        "block ids: multi-line quote, id on the last line only")

    -- the ids live inside the generated region, so the digest covers them
    T.check(on:find("^hl-", 1, true) > on:find("tomedown:begin body", 1, true),
        "block ids: inside the generated region")
end

-- special marker: callout (default), bold
do
    local function sbook(text, special)
        return { title = "T", author = "A", annotations = { {
            text = text, page = 1, date = "15/10/2026 11:59", special = special,
            id_seed = "2026-10-15 11:59:23", id_pos = "/p", id_text = text } } }
    end
    local function quote(md)
        return md:match("(> .-)\n\n%- %*%*p%. 1%*%*")
    end

    T.check(quote(render.buildBookMd(sbook("one", true), {})) == "> [!highlight]\n> one",
        "special marker: callout is the default")
    T.check(quote(render.buildBookMd(sbook("one", true), { special_marker = "callout" }))
        == "> [!highlight]\n> one", "special marker: callout when chosen")
    T.check(quote(render.buildBookMd(sbook("one\ntwo", true), { special_marker = "bold" }))
        == "> **one\n> two**", "special marker: bold wraps the quote as a whole")
    T.check(quote(render.buildBookMd(sbook("one\ntwo\n\nthree", true), { special_marker = "bold" }))
        == "> **one\n> two**\n> \n> **three**",
        "special marker: bold wraps paragraph by paragraph across a blank line")
    T.check(quote(render.buildBookMd(sbook("  one  ", true), { special_marker = "bold" }))
        == "> **one**", "special marker: bold trims the edges of a paragraph")
    T.check(quote(render.buildBookMd(sbook("a **b** c", true), { special_marker = "bold" }))
        == "> a **b** c", "special marker: bold leaves a paragraph with ** inside plain")
    T.check(quote(render.buildBookMd(sbook("*note* text", true), { special_marker = "bold" }))
        == "> *note* text", "special marker: bold leaves a paragraph with * at the edge plain")
    -- "none" was a real choice until 1.1: a stored value must fall back
    -- to the callout, never render as a plain quote the reader never chose
    T.check(quote(render.buildBookMd(sbook("one\ntwo", true), { special_marker = "none" }))
        == "> [!highlight]\n> one\n> two",
        "special marker: any value but bold falls back to the callout")
    T.check(quote(render.buildBookMd(sbook("one", true), { callout = true, special_marker = "bold" }))
        == "> [!highlight]\n> one", "special marker: the global callout wins")
    T.check(quote(render.buildBookMd(sbook("one", false), { special_marker = "bold" }))
        == "> one", "special marker: a normal highlight is never wrapped")
    local with_id = render.buildBookMd(sbook("one\ntwo", true),
        { special_marker = "bold", block_ids = true })
    T.check(T.contains(with_id, "> **one\n> two** ^hl-"),
        "special marker: the block id follows the closing emphasis")
    local counted = render.buildBookMd(sbook("one", true), { special_marker = "bold" })
    T.check(T.contains(counted, "special: 1") and T.contains(counted, "★ 1 special"),
        "special marker: counts stay whatever the marker")
end

-- standard Markdown links in the index and footnotes in book notes (v1.4.0)
do
    T.check(render.bookLink("Arthur Machen - The Three Impostors", "The Three Impostors", "wikilink")
        == "[[Arthur Machen - The Three Impostors\\|The Three Impostors]]",
        "bookLink: wikilink default")
    T.check(render.bookLink("Arthur Machen - The Three Impostors", "The Three Impostors", "markdown")
        == "[The Three Impostors](Arthur%20Machen%20-%20The%20Three%20Impostors.md)",
        "bookLink: standard markdown link encodes spaces")
    T.check(render.bookLink("Arthur Machen/The Three Impostors (1895)", "The Three Impostors", "markdown")
        == "[The Three Impostors](Arthur%20Machen/The%20Three%20Impostors%20%281895%29.md)",
        "bookLink: subfolder slash kept, parentheses encoded")

    local md_idx = render.buildIndexMd({
        {
            link = "Arthur Machen/Arthur Machen - The Three Impostors",
            title = "The Three Impostors",
            author = "Arthur Machen",
            count = 2,
        },
    }, { index_links = "markdown" })
    T.check(T.contains(md_idx,
            "[The Three Impostors](Arthur%20Machen/Arthur%20Machen%20-%20The%20Three%20Impostors.md)"),
        "index with markdown links")
    T.check(not T.contains(md_idx, "[["), "no wikilink when markdown format is chosen")

    local fn_book = render.buildBookMd({
        title = "The Three Impostors",
        author = "Arthur Machen",
        count = 2,
        annotations = {
            {
                text = "First passage.",
                note = "First personal note\nSecond line",
                chapter = "Chapter I",
                page = "7",
                date = "05/11/2026",
            },
            {
                text = "Second passage.",
                note = "Another note",
                chapter = "Chapter II",
                page = "14",
            },
        },
    }, { note_style = "footnote" })
    T.check(T.contains(fn_book, "- **p. 7** · 05/11/2026 [^1]"),
        "footnote marker 1 on first highlight meta")
    T.check(T.contains(fn_book, "- **p. 14** [^2]"),
        "footnote marker 2 on second highlight meta")
    T.check(not T.contains(fn_book, "**NOTE:**"),
        "inline NOTE label omitted in footnote mode")
    T.check(T.contains(fn_book, "[^1]: First personal note\n    Second line"),
        "multiline footnote definition indented")
    T.check(T.contains(fn_book, "[^2]: Another note"),
        "second footnote definition")
    T.check(fn_book:find("[^1]:", 1, true) < fn_book:find("tomedown:end body", 1, true),
        "footnotes stay inside the generated body region")

    -- Reading Digest (00 - Reading Digest.md)
    local empty_digest = render.buildDigestMd({}, {})
    T.check(T.contains(empty_digest, 'title: "Reading digest"'),
        "digest default title in frontmatter")
    T.check(T.contains(empty_digest, "  - digest"), "digest tag in frontmatter")
    T.check(T.contains(empty_digest, "_No exported books with highlights._"),
        "empty digest message")

    local digest = render.buildDigestMd({
        {
            link = "Arthur Machen - The Three Impostors",
            title = "The Three Impostors",
            author = "Arthur Machen",
            annotations = {
                {
                    text = "Older quote.",
                    chapter = "Prologue",
                    page = "5",
                    date = "04/11/2026 10:00",
                    sort_time = "2026-11-04 10:00:00",
                    sort_page = 5,
                },
                {
                    text = "Newer quote.",
                    note = "Key passage",
                    chapter = "Adventure of the Gold Tiberius",
                    page = "18",
                    date = "05/11/2026 21:15",
                    sort_time = "2026-11-05 21:15:00",
                    sort_page = 18,
                    special = true,
                },
            },
        },
        {
            link = "Edgar Wallace - The Three Just Men",
            title = "The Three Just Men",
            author = "Edgar Wallace",
            annotations = {
                {
                    text = "Same day earlier.",
                    page = "12",
                    date = "05/11/2026 09:30",
                    sort_time = "2026-11-05 09:30:00",
                    sort_page = 12,
                },
            },
        },
    }, { index_links = "markdown", note_style = "footnote" })
    T.check(T.contains(digest, "**2 books** · **3 highlights** · **★ 1 special**"),
        "digest stats summary line")
    local d_nov5 = digest:find("## 05/11/2026", 1, true)
    local d_nov4 = digest:find("## 04/11/2026", 1, true)
    T.check(d_nov5 and d_nov4 and d_nov5 < d_nov4,
        "digest groups newest day first")
    local q_newer = digest:find("> Newer quote.", 1, true)
    local q_earlier = digest:find("> Same day earlier.", 1, true)
    T.check(q_newer and q_earlier and q_newer < q_earlier,
        "digest orders newest highlight first within the same day")
    T.check(T.contains(digest,
            "### [The Three Impostors](Arthur%20Machen%20-%20The%20Three%20Impostors.md) — *Arthur Machen*"),
        "digest book heading uses configured link format and author")
    T.check(T.contains(digest, "[^1]: Key passage"),
        "digest supports footnote style for personal notes")
end

T.finish("test_render")
