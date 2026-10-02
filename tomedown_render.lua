--[[
Markdown text building for tomedown.koplugin.

Nearly pure module: it only depends on tomedown_i18n (the plugin's po), so it
can also be tested with a standard Lua interpreter.
]]

local _ = require("tomedown_i18n")
local render = {}

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

-- what Obsidian refuses inside a tag: its docs say tags can't contain
-- spaces, and only letters, numbers, "-", "_" and "/" survive
local FORBIDDEN_TAG_CHARS = "[!@#%$%%%^%&%*%(%)%,%.%?\"%:%{%}%|%<>]"

--- Normalise a keyword into a valid Obsidian tag.
-- Whitespace becomes "-", the characters Obsidian does not allow are
-- dropped, runs of "-" are collapsed and the edge ones are trimmed.
-- The case and any non-ASCII letter (accents included) are kept; the
-- result is idempotent. The caller drops the empty ones.
function render.sanitizeTag(s)
    if s == nil then
        return ""
    end
    s = tostring(s)
    s = s:gsub("%s+", "-")
    s = s:gsub(FORBIDDEN_TAG_CHARS, "")
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

    if opts.cover then
        add("")
        add(render.coverImg(opts.cover, 400, 533))
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
        local note = a.note and tostring(a.note):gsub("[\r\n]+", " ") or nil
        if note and note ~= "" then
            meta[#meta + 1] = _("note: ") .. note
        end
        if #meta == 0 then
            meta[1] = "…"
        end
        add("- " .. table.concat(meta, " · "))
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
    add("title: " .. yamlQuote(title))
    add("exported: " .. yamlQuote(opts.exported or os.date("%Y-%m-%d")))
    add("tags:")
    add("  - ebook")
    add("  - " .. _("index"))
    add("---")
    add("")

    if #books == 0 then
        add("_" .. _("No exported books with highlights.") .. "_")
        return table.concat(out, "\n") .. "\n"
    end

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

    return table.concat(out, "\n") .. "\n"
end

return render
