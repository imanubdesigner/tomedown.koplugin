--[[
Markdown text building for tomedown.koplugin.

Nearly pure module: it depends on tomedown_i18n (the plugin's po) and
ffi/sha2 for the block digests (the test suite stubs it), so it can
also be tested with a standard Lua interpreter.
]]

local _ = require("tomedown_i18n")
local md5 = require("ffi/sha2").md5
local render = {}

-- Generated blocks are wrapped in HTML comments, invisible in every
-- Markdown renderer (Obsidian included, reading view and live preview
-- alike): the export re-merges new content into these regions and leaves
-- whatever the user wrote outside of them untouched.
--
-- The marker text is part of the file format, never translated: it has
-- to stay byte-identical whatever the UI language, or switching
-- language would break every note. The begin marker is the plugin's
-- territory: the notes belong above it, under the heading, and the
-- marker carries the digest of the block it opens so the next export
-- can tell "fresh" from "hand-edited" at a glance. The end marker just
-- closes the block: everything below it is the reader's again.
render.FORMAT_VERSION = "1.0"

function render.beginMarker(name, hash)
    local marker = "<!-- tomedown:begin " .. name
    if hash then
        marker = marker .. " hash=" .. hash
    end
    return marker .. " — ⛔ generated below: do not edit inside"
        .. " or updates stop arriving · write your notes above -->"
end

function render.endMarker(name)
    return "<!-- tomedown:end " .. name .. " -->"
end

-- Heading that titles the writable zone above the marker. It belongs
-- to the plugin: the trailing tag tells the merge which line to rewrite
-- when the reader renames it, everything below stays theirs. The title
-- arrives translated from the plugin (opts.notes_title); an empty one
-- means the file gets no heading.
function render.notesHeading(title)
    return "## " .. title .. " <!-- tomedown:notes -->"
end

-- Short digest of a generated block: the hash written inside its begin
-- marker and read back by the merge to prove the block still matches
-- what the exporter generated. Whitespace around the block never
-- counts, so the same content hashes the same however it is framed.
function render.digest(text)
    local stripped = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    return md5(stripped):sub(1, 8)
end

local function yamlQuote(s)
    if s == nil then
        return '""'
    end
    s = tostring(s)
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\r", " ")
    s = s:gsub("\n", " ")
    return '"' .. s .. '"'
end

-- list item: plain when YAML-safe, quoted otherwise
local function yamlListItem(s)
    s = tostring(s)
    if s:match("^[%w][%w%s%-_%.']*$") then
        return s
    end
    return yamlQuote(s)
end

--- Normalise a keyword into a valid Obsidian tag.
-- Whitelist, not blacklist: whitespace (ASCII and non-breaking) becomes
-- "-", then every byte outside ASCII letters, numbers, "-", "_" and "/"
-- is dropped -- Obsidian's real validator is stricter than its docs'
-- list, so anything else (";", "'", "=", "[", "\\", ...) never reaches
-- the frontmatter. All non-ASCII bytes (accents, emoji) survive
-- untouched, runs of "-" are collapsed and the edge ones are trimmed.
-- The result is idempotent. The caller drops the empty ones.
function render.sanitizeTag(s)
    if s == nil then
        return ""
    end
    s = tostring(s)
    s = s:gsub("%s+", "-")
    s = s:gsub("\194\160", "-") -- UTF-8 non-breaking space
    s = s:gsub("[^\128-\255]", function(c)
        if c:match("[%w_%-/]") then
            return c
        end
        return ""
    end)
    s = s:gsub("%-+", "-")
    s = s:gsub("^%-+", "")
    s = s:gsub("%-+$", "")
    return s
end

-- "2026-09-26 10:11:12" -> "26/09/2026"
function render.fmtDate(dt)
    if type(dt) ~= "string" then
        return ""
    end
    local y, m, d = dt:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
    if y then
        return d .. "/" .. m .. "/" .. y
    end
    return dt
end

-- "2026-09-26 10:11:12" -> "26/09/2026 10:11"
function render.fmtDateTime(dt)
    if type(dt) ~= "string" then
        return ""
    end
    local y, m, d, hhmm = dt:match("^(%d%d%d%d)-(%d%d)-(%d%d)[ T](%d%d:%d%d)")
    if y then
        return d .. "/" .. m .. "/" .. y .. " " .. hhmm
    end
    return render.fmtDate(dt)
end

-- safe text inside an Obsidian wikilink
function render.alias(s)
    s = tostring(s or "")
    s = s:gsub("[%[%]|#^]", " ")
    s = s:gsub("%s+", " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

-- the cover inside a .md file: a plain <img> tag with a fixed CSS box
-- (Obsidian renders relative src paths since 1.8.1, object-fit is in
-- the sanitizer whitelist, and the letterbox shows the theme background)
function render.coverImg(rel, w, h)
    rel = tostring(rel or ""):gsub('"', "&quot;")
    return string.format('<img src="%s" alt="" style="object-fit:contain;width:%dpx;height:%dpx">',
        rel, w, h)
end

local function annotationChapter(a, no_chapter_label)
    if type(a.chapter) == "string" and a.chapter ~= "" then
        return a.chapter
    end
    return no_chapter_label or _("No chapter")
end

local function hasAnyChapter(annotations)
    for __, a in ipairs(annotations) do
        if type(a.chapter) == "string" and a.chapter ~= "" then
            return true
        end
    end
    return false
end

-- the region content as one string, for the digest in the begin marker
local function sliceText(t, from, to)
    local parts = {}
    for i = from, to do
        parts[#parts + 1] = t[i]
    end
    return table.concat(parts, "\n")
end

--[[
book = {
    title, author, exported, count,
    series, series_index, language, pages,     -- optional frontmatter
    status, progress,                          -- optional frontmatter
    keywords = { ... },                        -- optional, appended to tags
    annotations = {
        { text, note, chapter, page, date, special },
        ...
    },
    bookmarks = { { text, page, date }, ... }, -- optional page bookmarks
}
opts = { no_chapter_label = _("No chapter"),
         cover = "covers/x.jpg",               -- extracted during export
         callout = false }                     -- every highlight as [!highlight]
]]
function render.buildBookMd(book, opts)
    opts = opts or {}
    local annotations = book.annotations or {}
    local count = book.count or #annotations
    local out = {}
    local function add(s)
        out[#out + 1] = s
    end

    add("---")
    add('tomedown: "' .. render.FORMAT_VERSION .. '"')
    add("title: " .. yamlQuote(book.title))
    add("author: " .. yamlQuote(book.author))
    if opts.cover then
        add("cover: " .. yamlQuote(opts.cover))
    end
    if book.series then
        add("series: " .. yamlQuote(book.series))
    end
    if book.series and book.series_index ~= nil and tostring(book.series_index) ~= "" then
        if type(book.series_index) == "number" then
            add("series_index: " .. tostring(book.series_index))
        else
            add("series_index: " .. yamlQuote(book.series_index))
        end
    end
    if book.language then
        add("language: " .. yamlQuote(book.language))
    end
    if book.pages ~= nil then
        add("pages: " .. tostring(book.pages))
    end
    add("exported: " .. (book.exported or os.date("%Y-%m-%d")))
    add("highlights: " .. tostring(count))
    if book.status then
        add("status: " .. yamlQuote(book.status))
    end
    if book.progress then
        add("progress: " .. yamlQuote(book.progress))
    end
    add("tags:")
    add("  - ebook")
    add("  - " .. _("highlights"))
    for __, kw in ipairs(book.keywords or {}) do
        local tag = render.sanitizeTag(kw)
        if tag ~= "" then
            add("  - " .. yamlListItem(tag))
        end
    end
    add("---")
    -- one generated block per book file: from the rule down to the last
    -- bookmark is the plugin's territory; the reader writes above it
    -- (right under the front matter), and the next export refreshes this
    -- single region without touching anything else. The heading of the
    -- write zone sits between the front matter and the block; the
    -- content is collected first: the begin marker is inserted below
    -- and carries the digest of what it wraps.
    if opts.notes_title and opts.notes_title ~= "" then
        add(render.notesHeading(opts.notes_title))
    end
    add("")
    local region_from = #out + 1
    add("")
    add("---")

    if opts.cover then
        add("")
        add('<p align="center">' .. render.coverImg(opts.cover, 400, 533) .. "</p>")
        -- second rule frames the cover above the count
        add("")
        add("---")
    end

    local open = false
    if count > 0 then
        add("")
        add("# **" .. _("highlights"):upper() .. ": " .. tostring(count) .. "**")
        add("")
        add("---")
    end
    local function heading(h)
        if open then
            add("")
            add("---")
        end
        if out[#out] ~= "" then
            add("")
        end
        add(h)
        open = true
    end

    local with_chapters = hasAnyChapter(annotations)
    local current_chapter = nil

    for __, a in ipairs(annotations) do
        if with_chapters then
            local chapter = annotationChapter(a, opts.no_chapter_label)
            if chapter ~= current_chapter then
                heading("# " .. chapter)
                current_chapter = chapter
            end
        end

        add("")
        -- Special Highlight always renders as a callout; the global
        -- setting turns every remaining highlight into one
        if opts.callout or a.special then
            add("> [!highlight]")
        end
        local text = tostring(a.text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
        for line in (text .. "\n"):gmatch("(.-)\n") do
            add("> " .. line)
        end
        add("")

        local meta = {}
        if a.page and tostring(a.page) ~= "" then
            meta[#meta + 1] = "**p. " .. tostring(a.page) .. "**"
        end
        if a.date and tostring(a.date) ~= "" then
            meta[#meta + 1] = tostring(a.date)
        end
        local note_lines
        if a.note then
            local body = tostring(a.note):gsub("\r\n", "\n"):gsub("\r", "\n")
            note_lines = {}
            for line in (body .. "\n"):gmatch("(.-)\n") do
                note_lines[#note_lines + 1] = line
            end
            while #note_lines > 0 and note_lines[1]:match("^%s*$") do
                table.remove(note_lines, 1)
            end
            while #note_lines > 0 and note_lines[#note_lines]:match("^%s*$") do
                table.remove(note_lines)
            end
            if #note_lines == 0 then
                note_lines = nil
            end
        end
        if #meta > 0 then
            add("- " .. table.concat(meta, " · "))
        end
        if note_lines then
            if #meta > 0 then
                add("")
            end
            local first = true
            for __, line in ipairs(note_lines) do
                if line:match("^%s*$") then
                    add("")
                elseif first then
                    add("- **NOTE:** *" .. line .. "*")
                    first = false
                else
                    add("  *" .. line .. "*")
                end
            end
        elseif #meta == 0 then
            add("- …")
        end
        open = true
    end

    local bookmarks = book.bookmarks or {}
    if #bookmarks > 0 then
        heading("# " .. _("Page bookmarks"))
        for __, b in ipairs(bookmarks) do
            add("")
            if b.text and tostring(b.text) ~= "" then
                local btext = tostring(b.text):gsub("\r\n", "\n"):gsub("\r", "\n")
                for line in (btext .. "\n"):gmatch("(.-)\n") do
                    add("> " .. line)
                end
                add("")
            end
            local bmeta = {}
            if b.page and tostring(b.page) ~= "" then
                bmeta[#bmeta + 1] = "**p. " .. tostring(b.page) .. "**"
            end
            if b.date and tostring(b.date) ~= "" then
                bmeta[#bmeta + 1] = tostring(b.date)
            end
            if #bmeta == 0 then
                bmeta[1] = "…"
            end
            add("- " .. table.concat(bmeta, " · "))
        end
    end
    -- the region always closes on a blank line: the end marker never
    -- glues to the last generated line
    if out[#out] ~= "" then
        add("")
    end
    table.insert(out, region_from, render.beginMarker("body",
        render.digest(sliceText(out, region_from, #out))))
    add(render.endMarker("body"))

    return table.concat(out, "\n") .. "\n"
end

--[[
books = { { link, title, author, series, series_index, status,
            count, date, cover } }
opts = { title, exported, show_covers }
The Series and Status columns are always there (a dash when the book
has neither), the cover column only with opts.show_covers.
]]
function render.buildIndexMd(books, opts)
    opts = opts or {}
    local title = opts.title or _("Book index")
    local out = {}
    local function add(s)
        out[#out + 1] = s
    end

    add("---")
    add('tomedown: "' .. render.FORMAT_VERSION .. '"')
    add("title: " .. yamlQuote(title))
    add("exported: " .. yamlQuote(opts.exported or os.date("%Y-%m-%d")))
    add("tags:")
    add("  - ebook")
    add("  - " .. _("index"))
    add("---")
    if opts.notes_title and opts.notes_title ~= "" then
        add(render.notesHeading(opts.notes_title))
    end
    add("")
    -- one generated region: the rule, the stats line and the table; the
    -- content is collected first, the begin marker carries its digest
    local region_from = #out + 1
    add("")
    add("---")
    add("")

    if #books == 0 then
        add("_" .. _("No exported books with highlights.") .. "_")
        add("")
        table.insert(out, region_from, render.beginMarker("index",
            render.digest(sliceText(out, region_from, #out))))
        add(render.endMarker("index"))
        return table.concat(out, "\n") .. "\n"
    end

    local total_highlights = 0
    for __, b in ipairs(books) do
        total_highlights = total_highlights + (tonumber(b.count) or 0)
    end
    local books_txt = #books == 1 and _("%1 book") or _("%1 books")
    local highlights_txt = total_highlights == 1 and _("%1 highlight")
        or _("%1 highlights")
    local stats = "*" .. (books_txt:gsub("%%1", tostring(#books)))
        .. " · " .. (highlights_txt:gsub("%%1", tostring(total_highlights)))
        .. " " .. _("— click a title to open its note.") .. "*"
    add(stats)
    add("")

    local with_covers = opts.show_covers
    local status_labels = {
        reading = _("Reading"),
        complete = _("Complete"),
        abandoned = _("Abandoned"),
    }

    local header, align = {}, {}
    local function column(title, separator)
        header[#header + 1] = title
        align[#align + 1] = separator or ":---"
    end
    if with_covers then
        column(_("Cover"))
    end
    column(_("Book"))
    column(_("Author"))
    column(_("Series"))
    column(_("Status"))
    column(_("Highlights"), "---:")
    column(_("Last export"))
    add("| " .. table.concat(header, " | ") .. " |")
    add("|" .. table.concat(align, "|") .. "|")

    for __, b in ipairs(books) do
        local alias = render.alias(b.title)
        local link = alias ~= "" and ("[[" .. tostring(b.link) .. "\\|" .. alias .. "]]")
            or ("[[" .. tostring(b.link) .. "]]")
        local author = tostring(b.author or ""):gsub("|", "\\|"):gsub("[\r\n]+", " ")
        local series = "—"
        if b.series and tostring(b.series) ~= "" then
            series = tostring(b.series)
            if b.series_index ~= nil and tostring(b.series_index) ~= "" then
                series = series .. " #" .. tostring(b.series_index)
            end
            series = series:gsub("|", "\\|"):gsub("[\r\n]+", " ")
        end
        local status = (b.status and status_labels[b.status]) or "—"
        local date = (b.date and b.date ~= "") and b.date or "—"
        local cells = {}
        if with_covers then
            cells[#cells + 1] = b.cover and render.coverImg(b.cover, 90, 120) or ""
        end
        cells[#cells + 1] = link
        cells[#cells + 1] = author
        cells[#cells + 1] = series
        cells[#cells + 1] = status
        cells[#cells + 1] = tostring(b.count or 0)
        cells[#cells + 1] = date
        add("| " .. table.concat(cells, " | ") .. " |")
    end

    -- the region closes on a blank line, the file ends on the marker
    if out[#out] ~= "" then
        add("")
    end
    table.insert(out, region_from, render.beginMarker("index",
        render.digest(sliceText(out, region_from, #out))))
    add(render.endMarker("index"))
    return table.concat(out, "\n") .. "\n"
end

return render
