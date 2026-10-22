-- tests for tomedown_render.lua (almost pure module: only tomedown_i18n)
local HERE = arg[0]:match("^(.*)/") or "."
package.path = HERE .. "/?.lua;" .. package.path
local T = require("common")
local render = require("tomedown_render")

local book = {
    title = "Blackwater",
    author = "Michael McDowell",
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
T.check(T.contains(md, 'title: "Blackwater"'), "frontmatter title")
T.check(T.contains(md, 'author: "Michael McDowell"'), "frontmatter author")
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
T.check(not T.contains(md, "# Blackwater"), "no h1 in the body")
T.check(not T.contains(md, "*Michael McDowell*"), "author stays in the frontmatter only")
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
    title = "Blackwater",
    author = "Michael McDowell",
    series = "Blackwater",
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
T.check(T.contains(rich, 'series: "Blackwater"'), "frontmatter series")
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
local withCover = render.buildBookMd(book, { cover = "covers/Blackwater.jpg" })
T.check(T.contains(withCover, 'cover: "covers/Blackwater.jpg"'), "cover in the frontmatter")
T.check(T.contains(withCover,
    '<p align="center"><img src="covers/Blackwater.jpg" alt="" style="object-fit:contain;width:400px;height:533px"></p>'),
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
        link = "Michael McDowell - Blackwater",
        title = "Blackwater",
        author = "Michael McDowell",
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
T.check(T.contains(rows, "[[Michael McDowell - Blackwater\\|Blackwater]]"), "wikilink with alias")
T.check(T.contains(rows, "| Michael McDowell | 2 |"), "author and count in the row")
T.check(T.contains(rows, "| A \\| B | 0 |"), "pipes escaped, count zero")
local order = rows:find("[[Michael McDowell - Blackwater\\|Blackwater]]", 1, true)
local order2 = rows:find("[[Altro Autore - Altro\\|Altro]]", 1, true)
T.check(order < order2, "the index keeps the order of the books it received")
T.check(not T.contains(rows, "### "), "no group headings when every book is plain")
local plain_rows = (rows:gsub(" hash=%w+", ""))
T.check(T.contains(plain_rows,
    "---\n\n\n" .. render.beginMarker("index")
    .. "\n\n---\n\n**2 books** · **2 highlights**\n\n| Book |"),
    "the stats line sits between the frontmatter rule and the table")

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
T.check(not T.contains(covered, "### "), "a lone group gets no heading")
-- a book without a series/status/cover drops those columns, no dash
local sparse = render.buildIndexMd({
    { link = "B", title = "B", author = "Au", count = 1 },
}, { show_covers = false })
T.check(T.contains(sparse, "| [[B\\|B]] | Au | 1 |"),
    "missing series/status drop their columns, no cover cell")

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
local clean_once = render.sanitizeTag("Occult & Supernatural")
T.check(render.sanitizeTag(clean_once) == clean_once, "sanitizeTag is idempotent")

-- through the exporter: dirty keywords render sanitized, dead ones vanish
local tagged = render.buildBookMd({
    title = "Blackwater",
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

-- special marker: callout (default), bold, none
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
    T.check(quote(render.buildBookMd(sbook("one\ntwo", true), { special_marker = "none" }))
        == "> one\n> two", "special marker: none leaves a plain quote")
    T.check(quote(render.buildBookMd(sbook("one", true), { callout = true, special_marker = "bold" }))
        == "> [!highlight]\n> one", "special marker: the global callout wins")
    T.check(quote(render.buildBookMd(sbook("one", false), { special_marker = "bold" }))
        == "> one", "special marker: a normal highlight is never wrapped")
    local with_id = render.buildBookMd(sbook("one\ntwo", true),
        { special_marker = "bold", block_ids = true })
    T.check(T.contains(with_id, "> **one\n> two** ^hl-"),
        "special marker: the block id follows the closing emphasis")
    local counted = render.buildBookMd(sbook("one", true), { special_marker = "none" })
    T.check(T.contains(counted, "special: 1") and T.contains(counted, "★ 1 special"),
        "special marker: counts stay whatever the marker")
end

T.finish("test_render")
