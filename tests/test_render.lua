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
T.check(T.contains(md, "  - kindle"), "tag kindle")
T.check(T.contains(md, "  - highlights"), "tag highlights")
T.check(not T.contains(md, "series:"), "no series line when absent")
T.check(not T.contains(md, "language:"), "no language line when absent")
T.check(not T.contains(md, "pages:"), "no pages line when absent")
T.check(not T.contains(md, "status:"), "no status line when absent")
T.check(not T.contains(md, "progress:"), "no progress line when absent")
T.check(T.contains(md, "# Blackwater"), "h1 with the title")
T.check(T.contains(md, "*Michael McDowell*"), "author in italics")
T.check(T.contains(md, "**2 highlights**"), "highlight count")
T.check(T.contains(md, "## Capitolo I"), "first chapter")
T.check(T.contains(md, "## Capitolo II"), "second chapter")
T.check(T.contains(md, "> Prima frase."), "quote 1")
T.check(T.contains(md, "> Seconda riga."), "quote 2")
T.check(T.contains(md, "- **p. 10** · 02/09/2026 · note: nota utente"),
    "meta row with page, date and note")
T.check(T.contains(md, "- **p. 38** · 03/09/2026"), "meta row without note")
local i10 = md:find("- **p. 10**", 1, true)
local i38 = md:find("- **p. 38**", 1, true)
T.check(i10 < i38, "highlights stay in page order")
T.check(md:sub(-1) == "\n", "ends with a newline")
T.check(not T.contains(md, "cover"), "no cover in the markdown")
T.check(not T.contains(md, "![]("), "no image in the markdown")

-- no chapters: no ## sections
local noChapters = render.buildBookMd({
    title = "Senza capitoli",
    count = 1,
    annotations = { { text = "Solo testo", page = "1" } },
})
T.check(not T.contains(noChapters, "\n## "), "without chapters no heading appears")

-- mixed chapters: annotations without a chapter use the given label
local mixed = render.buildBookMd({
    title = "Misto",
    count = 2,
    annotations = {
        { text = "A", chapter = "Capitolo I" },
        { text = "B" },
    },
}, { no_chapter_label = "Senza capitolo" })
T.check(T.contains(mixed, "## Capitolo I"), "chapter present")
T.check(T.contains(mixed, "## Senza capitolo"), "fallback label")
T.check(not T.contains(mixed, "\n## No chapter"), "no leftover English msgid")

-- multiline note flattened onto one line
local multi = render.buildBookMd({
    title = "Note",
    count = 1,
    annotations = { { text = "X", note = "riga1\nriga2" } },
})
T.check(T.contains(multi, "note: riga1 riga2"), "multiline note on one line")
T.check(not T.contains(multi, "note: riga1\n"), "the note does not break the meta line")

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
local t1 = rich:find("  - kindle", 1, true)
local t2 = rich:find("  - highlights", 1, true)
local t3 = rich:find("  - horror", 1, true)
local t4 = rich:find("  - gothic-fiction", 1, true)
T.check(t1 and t2 and t3 and t4 and t1 < t2 and t2 < t3 and t3 < t4,
    "tags: kindle, highlights, then the book keywords")

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
T.check(T.contains(weird, '  - "Sci-Fi & Fantasy"'),
    "a keyword needing quotes gets them")

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
T.check(T.contains(bmBook, "## Page bookmarks"), "bookmarks heading")
T.check(T.contains(bmBook, "> Nota segnalibro"), "bookmark note quoted")
T.check(T.contains(bmBook, "- **p. 5** · 01/09/2026"), "bookmark meta row")
T.check(T.contains(bmBook, "- **p. 7** · 02/09/2026"), "bookmark without note: meta only")
T.check(T.contains(bmBook, "**1 highlights**"), "highlight count kept")
local iHl = bmBook:find("> Evidenziato", 1, true)
local iSect = bmBook:find("## Page bookmarks", 1, true)
T.check(iHl and iSect and iHl < iSect, "the section comes after the highlights")
local quoted = select(2, bmBook:gsub("> ", ""))
T.check(quoted == 2, "only the highlight and the bookmark note are quoted: " .. quoted)

local onlyBookmarks = render.buildBookMd({
    title = "Solo bm",
    count = 0,
    annotations = {},
    bookmarks = { { page = "1", date = "01/01/2026" } },
})
T.check(not T.contains(onlyBookmarks, "**0 highlights**"), "no zero count line")
T.check(T.contains(onlyBookmarks, "## Page bookmarks"), "bookmark-only book gets the section")
T.check(not T.contains(md, "Page bookmarks"), "no section without bookmarks")

-- ---------------------------------------------------------------- index
local index = render.buildIndexMd({}, {})
T.check(T.contains(index, "# Book index"), "index default title")
T.check(T.contains(index, "_No exported books with highlights._"), "empty index")
T.check(T.contains(index, "  - index"), "tag index")
T.check(T.contains(index, "---\n"), "index frontmatter")

local rows = render.buildIndexMd({
    {
        link = "Michael McDowell - Blackwater",
        title = "Blackwater",
        author = "Michael McDowell",
        count = 2,
        date = "26/09/2026",
    },
    {
        link = "Altro Autore - Altro",
        title = "Altro",
        author = "A | B",
        count = 0,
        date = "",
    },
}, { title = "Indice dei libri", exported = "2026-09-26" })

T.check(T.contains(rows, "# Indice dei libri"), "index title")
T.check(T.contains(rows, 'title: "Indice dei libri"'), "index frontmatter")
T.check(T.contains(rows, "| Book | Author | Highlights | Last export |"), "table header")
T.check(T.contains(rows, "|:---|:---|---:|:---|"), "table separators")
T.check(T.contains(rows, "[[Michael McDowell - Blackwater|Blackwater]]"), "wikilink with alias")
T.check(T.contains(rows, "| 2 | 26/09/2026 |"), "count and date in the row")
T.check(T.contains(rows, "| A \\| B | 0 | — |"), "pipes escaped and empty date")
local order = rows:find("[[Michael McDowell - Blackwater|Blackwater]]", 1, true)
local order2 = rows:find("[[Altro Autore - Altro|Altro]]", 1, true)
T.check(order < order2, "the index keeps the order of the books it received")

-- alias: no characters that break the wikilink
local clean = render.alias("Titolo [x] #y | z ^w")
T.check(not clean:find("[", 1, true) and not clean:find("|", 1, true),
    "alias without brackets or pipes")
T.check(not clean:find("%s%s"), "alias without double spaces")
T.check(render.alias("") == "", "empty alias")
T.check(render.alias(nil) == "", "alias with nil")

-- title with pipe: the index alias stays valid
local pipeIndex = render.buildIndexMd({
    { link = "Base", title = "A | B", author = "Aut", count = 1, date = "01/01/2026" },
})
local line = pipeIndex:match("| %[[^\n]+")
T.check(line and T.contains(line, "[[Base|A B]]"),
    "title with pipe: the alias stays a single valid wikilink")
T.check(line and line:gsub("[^|]", "") == "||||||",
    "the row has the right number of columns")

-- fmtDate
T.check(render.fmtDate("2026-09-02 10:00:00") == "02/09/2026", "ISO date in Italian format")
T.check(render.fmtDate("2026-12-31") == "31/12/2026", "date without time")
T.check(render.fmtDate("01/02/2026") == "01/02/2026", "already formatted date passes through")
T.check(render.fmtDate(nil) == "", "nil date is empty")
T.check(render.fmtDate(42) == "", "non-string date is empty")

T.finish("test_render")
