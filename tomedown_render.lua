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
        { text, note, chapter, page, date },
        ...
    },
    bookmarks = { { text, page, date }, ... }, -- optional page bookmarks
}
opts = { no_chapter_label = _("No chapter") }
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
        add("  - " .. yamlListItem(kw))
    end
    add("---")

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
books = { { link, title, author, count, date } }
opts = { title, exported }
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

    add(_("| Book | Author | Highlights | Last export |"))
    add("|:---|:---|---:|:---|")
    for __, b in ipairs(books) do
        local alias = render.alias(b.title)
        local link = alias ~= "" and ("[[" .. tostring(b.link) .. "\\|" .. alias .. "]]")
            or ("[[" .. tostring(b.link) .. "]]")
        local author = tostring(b.author or ""):gsub("|", "\\|"):gsub("[\r\n]+", " ")
        local date = (b.date and b.date ~= "") and b.date or "—"
        add("| " .. link .. " | " .. author .. " | " .. tostring(b.count or 0) .. " | " .. date .. " |")
    end

    return table.concat(out, "\n") .. "\n"
end

return render
