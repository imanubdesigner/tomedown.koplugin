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
T.check(T.contains(md, "# **HIGHLIGHTS: 2**"), "highlight count as a heading")
T.check(T.contains(md, "\n# Capitolo I"), "first chapter")
T.check(T.contains(md, "\n# Capitolo II"), "second chapter")
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

-- separators: under the stats, between chapters, never at the end of the file
T.check(T.contains(md, "# **HIGHLIGHTS: 2**\n\n---\n\n# Capitolo I"),
    "separator between the stats and the first chapter")
T.check(T.contains(md, "- **p. 10** · 02/09/2026 · note: nota utente\n\n---\n\n# Capitolo II"),
    "separator when the chapter changes")
T.check(not T.contains(md, "---\n\n---"), "no doubled separator")
T.check(md:match("%-%-%-%s*$") == nil, "no separator at the end of the file")

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
T.check(T.contains(bmBook, "# **HIGHLIGHTS: 1**"), "highlight count kept")
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
T.check(not T.contains(onlyBookmarks, "# **HIGHLIGHTS: 0**"), "no zero count line")
T.check(T.contains(onlyBookmarks, "\n# Page bookmarks"), "bookmark-only book gets the section")
T.check(select(2, onlyBookmarks:gsub("\n%-%-%-\n", "")) == 1,
    "bookmark-only: no separator besides the frontmatter")
T.check(not T.contains(md, "Page bookmarks"), "no section without bookmarks")

-- ---------------------------------------------------------------- cover
local withCover = render.buildBookMd(book, { cover = "covers/Blackwater.jpg" })
T.check(T.contains(withCover, 'cover: "covers/Blackwater.jpg"'), "cover in the frontmatter")
T.check(T.contains(withCover,
    '<img src="covers/Blackwater.jpg" alt="" style="object-fit:contain;width:400px;height:533px">'),
    "cover embedded in the body")
local img_pos = withCover:find("<img ", 1, true)
local hl_pos = withCover:find("# **HIGHLIGHTS", 1, true)
T.check(img_pos and hl_pos and img_pos < hl_pos, "the cover sits before the highlights heading")
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

T.check(not T.contains(rows, "# Indice dei libri"), "no h1 in the index")
T.check(T.contains(rows, 'title: "Indice dei libri"'), "index frontmatter")
T.check(T.contains(rows, "| Book | Author | Series | Status | Highlights | Last export |"),
    "table header without the cover column")
T.check(not T.contains(rows, "| Cover |"), "no cover column when the option is off")
T.check(T.contains(rows, "|:---|:---|:---|:---|---:|:---|"), "table separators")
T.check(T.contains(rows, "[[Michael McDowell - Blackwater\\|Blackwater]]"), "wikilink with alias")
T.check(T.contains(rows, "| 2 | 26/09/2026 |"), "count and date in the row")
T.check(T.contains(rows, "| A \\| B | — | — | 0 | — |"),
    "pipes escaped, empty date, dash for series and status")
local order = rows:find("[[Michael McDowell - Blackwater\\|Blackwater]]", 1, true)
local order2 = rows:find("[[Altro Autore - Altro\\|Altro]]", 1, true)
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
T.check(line and T.contains(line, "[[Base\\|A B]]"),
    "title with pipe: the alias stays a single valid wikilink")
T.check(line and line:gsub("[^|]", "") == "||||||||",
    "the row has the right number of columns (7 separators + the escaped one)")

-- index v2: cover column, series and status cells
local covered = render.buildIndexMd({
    {
        link = "Autore - Titolo",
        title = "Titolo",
        author = "Autore",
        series = "Saga",
        series_index = 2,
        status = "reading",
        count = 3,
        date = "01/01/2026",
        cover = "covers/Autore - Titolo.jpg",
    },
}, { show_covers = true })
T.check(T.contains(covered, "| Cover | Book | Author | Series | Status | Highlights | Last export |"),
    "header with the cover column")
T.check(T.contains(covered,
    '<img src="covers/Autore - Titolo.jpg" alt="" style="object-fit:contain;width:90px;height:120px">'),
    "cover cell in the index row")
T.check(T.contains(covered, "| Saga #2 |"), "series cell with the series index")
T.check(T.contains(covered, "| Reading |"), "status cell translated to English")
T.check(T.contains(covered, "| 3 | 01/01/2026 |"), "count and date in the covered row")
-- a book without a series/status/cover keeps the columns, with a dash
local sparse = render.buildIndexMd({
    { link = "B", title = "B", author = "Au", count = 1, date = "01/01/2026" },
}, { show_covers = false })
T.check(T.contains(sparse, "| [[B\\|B]] | Au | — | — | 1 | 01/01/2026 |"),
    "missing series/status become a dash, no cover cell")

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

T.finish("test_render")
