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
-- means the file gets no heading. The heading itself rides only with
-- the merge markers (preserve on): a plain export writes no heading at
-- all, there is nothing to merge when every export overwrites the file.
function render.notesHeading(title)
    return "## " .. title .. " <!-- tomedown:notes -->"
end

-- The line that seeded an empty write zone in older builds: never
-- written again — the room alone opens the zone — but still known here
-- so the merge can drop it from a file that carries it.
function render.notesInvite()
    return "_" .. _("Write your thoughts, your emotions, your questions.")
        .. "_"
end

-- Reading bar for the index cell: ten cells, the filled ones rounded
-- from the percentage, and a single filled cell for any progress below
-- 5% so a book just started never shows an empty bar. The percentage
-- rides right after it, joined by a no-break space: render.progressPct.
function render.progressBar(progress)
    if progress == nil then
        return nil
    end
    local pct = tonumber(tostring(progress):match("%d+"))
    if not pct then
        return nil
    end
    local on = math.floor(pct / 10 + 0.5)
    if on < 1 and pct > 0 then
        on = 1
    elseif on > 10 then
        on = 10
    end
    return string.rep("▰", on) .. string.rep("▱", 10 - on)
end

-- The percentage as it rides beside the bar: "96%".
function render.progressPct(progress)
    if progress == nil then
        return nil
    end
    local pct = tonumber(tostring(progress):match("%d+"))
    if not pct then
        return nil
    end
    return tostring(pct) .. "%"
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

--- Stable Obsidian block ID of a highlight, built from `seed`.
-- Only letters, digits and "-" survive in a block ID. The result is
-- "hl-" plus eight hex digits of md5(seed): at six, a long book would
-- start to collide, and the numeric suffix below depends on rendering
-- order, so it has to stay practically unreachable.
function render.blockId(seed)
    return "hl-" .. md5(tostring(seed)):sub(1, 8)
end

--- Assign `a.id` to every annotation (in place), deterministically.
-- The seed is the highlight's creation time (a.id_seed), which never
-- changes, so an ID stays tied to its highlight across exports, however
-- many other highlights come or go. Highlights that share a creation
-- time (imports, sync): the first, in rendering order, keeps the plain
-- ID, the others add their position to the seed. Without a creation
-- time the position and text stand in (stable until the highlight is
-- reshaped). A residual clash gets a numeric suffix.
function render.assignBlockIds(annotations)
    local seen_seed, taken = {}, {}
    for __, a in ipairs(annotations) do
        local seed
        if a.id_seed ~= nil and tostring(a.id_seed) ~= "" then
            seed = tostring(a.id_seed)
        else
            seed = "pos:" .. tostring(a.id_pos or "") .. "|"
                .. tostring(a.id_text or a.text or "")
        end
        if seen_seed[seed] then
            seed = seed .. "|" .. tostring(a.id_pos or "")
        else
            seen_seed[seed] = true
        end
        local id = render.blockId(seed)
        if taken[id] then
            local n = 2
            while taken[id .. "-" .. n] do
                n = n + 1
            end
            id = id .. "-" .. n
        end
        taken[id] = true
        a.id = id
    end
end

local function ltrim(s) return (s:gsub("^%s+", "")) end
local function rtrim(s) return (s:gsub("%s+$", "")) end

-- Wrap the quote in bold, paragraph by paragraph: emphasis spans a soft
-- line break but never an empty line, so a quote holding one is wrapped
-- once per paragraph. The edges are trimmed first (CommonMark does not
-- open "** text" nor close "text **"). A paragraph that already carries
-- asterisks at its edges or a "**" inside is left plain: wrapping it
-- would break the emphasis, and the star in the heading and the index
-- still marks it. Works on `lines` in place.
local function wrapBold(lines)
    local i = 1
    while i <= #lines do
        if lines[i]:match("^%s*$") then
            i = i + 1
        else
            local j = i
            while j < #lines and not lines[j + 1]:match("^%s*$") do
                j = j + 1
            end
            local first, last = ltrim(lines[i]), rtrim(lines[j])
            local joined = table.concat(lines, "\n", i, j)
            if not joined:find("**", 1, true)
                and first:sub(1, 1) ~= "*" and last:sub(-1) ~= "*" then
                if i == j then
                    lines[i] = "**" .. rtrim(first) .. "**"
                else
                    lines[i] = "**" .. first
                    lines[j] = last .. "**"
                end
            end
            i = j + 1
        end
    end
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
         callout = false,                      -- every highlight as [!highlight]
         block_ids = false,                    -- stable ^hl-xxxxxxxx ending each quote
         special_marker = "callout" }          -- or "bold" / "none", while callout is off
-- annotations also carry, for block_ids: id_seed (creation time),
-- id_pos, id_text (fallback seed)
]]
function render.buildBookMd(book, opts)
    opts = opts or {}
    -- false only behind preserve off: the export overwrites the file
    -- wholesale, so it writes no handles for a merge that never runs
    local markers = opts.markers ~= false
    local annotations = book.annotations or {}
    local count = book.count or #annotations
    local special_count = 0
    for __, a in ipairs(annotations) do
        if a.special then
            special_count = special_count + 1
        end
    end
    local out = {}
    local marker_global = opts.special_marker
    if marker_global ~= "bold" and marker_global ~= "none" then
        marker_global = "callout"
    end
    local function add(s)
        out[#out + 1] = s
    end
    if opts.block_ids then
        render.assignBlockIds(annotations)
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
    add("special: " .. tostring(special_count))
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
    -- single region without touching anything else. With preserve on
    -- the heading of the write zone sits between the front matter and
    -- the block, followed by two blank lines of room to write in. The
    -- content is collected first: the begin marker is inserted below
    -- and carries the digest of what it wraps (the room above it is
    -- never hashed). With opts.markers false — the export behind
    -- preserve off — none of the handles are written: no markers, no
    -- heading, no room, the file is plain markdown the next run
    -- replaces wholesale.
    if markers then
        if opts.notes_title and opts.notes_title ~= "" then
            add(render.notesHeading(opts.notes_title))
        end
        add("")
        add("")
    end
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
        -- the recap heads the block: how many highlights, and the
        -- starred ones next to them — the same star the index uses
        local headline = count == 1 and _("%1 highlight")
            or _("%1 highlights")
        headline = headline:gsub("%%1", tostring(count))
        if special_count > 0 then
            headline = headline .. " · ★ "
                .. (_("%1 special"):gsub("%%1", tostring(special_count)))
        end
        add("")
        add("# **" .. headline .. "**")
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
        -- A Special Highlight is a callout unless the reader chose
        -- another marker (bold, none); the global setting turns every
        -- highlight into a callout and wins over that choice
        local marker = marker_global
        local as_callout = opts.callout or (a.special and marker == "callout")
        local as_bold = a.special and not opts.callout and marker == "bold"
        if as_callout then
            add("> [!highlight]")
        end
        local text = tostring(a.text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
        local quote_lines = {}
        for line in (text .. "\n"):gmatch("(.-)\n") do
            quote_lines[#quote_lines + 1] = line
        end
        if as_bold then
            wrapBold(quote_lines)
        end
        for __, line in ipairs(quote_lines) do
            add("> " .. line)
        end
        -- Obsidian block ID: the end of the last line of the quote (or
        -- of the callout), after any closing emphasis. Checked in
        -- Obsidian: a link jumps to, and an embed shows, the whole
        -- quote, multi-paragraph and callout included.
        if opts.block_ids and a.id then
            out[#out] = out[#out] .. " ^" .. a.id
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
            local head = #meta > 0 and "  - " or "- "
            local pad = #meta > 0 and "    " or "  "
            local first = true
            for __, line in ipairs(note_lines) do
                if line:match("^%s*$") then
                    add("")
                elseif first then
                    add(head .. "**NOTE:** *" .. line .. "*")
                    first = false
                else
                    add(pad .. "*" .. line .. "*")
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
    if markers then
        table.insert(out, region_from, render.beginMarker("body",
            render.digest(sliceText(out, region_from, #out))))
        add(render.endMarker("body"))
    end
    return table.concat(out, "\n") .. "\n"
end

--[[
books = { { link, title, author, series, series_index, status, count,
            special, progress, last_read, cover } }
opts = { title, exported, show_covers }
The books land in two tables: those that belong to a series, and the
rest — a heading each only when both groups exist. The columns adapt
to what each group holds: Series only on the series books, Author,
Status, Progress and Last read only when at least one book of the
group has them; Book and Highlights are always there (with the
special count in the cell), the cover column only with
opts.show_covers.
]]
function render.buildIndexMd(books, opts)
    opts = opts or {}
    -- see buildBookMd: no handles behind preserve off
    local markers = opts.markers ~= false
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
    if markers then
        if opts.notes_title and opts.notes_title ~= "" then
            add(render.notesHeading(opts.notes_title))
        end
        add("")
        add("")
    end
    -- one generated region: the rule, the stats line and the table; the
    -- content is collected first, the begin marker carries its digest
    -- (written only with opts.markers, see buildBookMd)
    local region_from = #out + 1
    add("")
    add("---")
    add("")

    if #books == 0 then
        add("_" .. _("No exported books with highlights.") .. "_")
        add("")
        if markers then
            table.insert(out, region_from, render.beginMarker("index",
                render.digest(sliceText(out, region_from, #out))))
            add(render.endMarker("index"))
        end
        return table.concat(out, "\n") .. "\n"
    end

    local total_highlights, total_special = 0, 0
    for __, b in ipairs(books) do
        total_highlights = total_highlights + (tonumber(b.count) or 0)
        total_special = total_special + (tonumber(b.special) or 0)
    end
    local books_txt = #books == 1 and _("%1 book") or _("%1 books")
    local highlights_txt = total_highlights == 1 and _("%1 highlight")
        or _("%1 highlights")
    local stats = "**" .. (books_txt:gsub("%%1", tostring(#books)))
        .. "** · **" .. (highlights_txt:gsub("%%1", tostring(total_highlights)))
        .. "**"
    if total_special > 0 then
        stats = stats .. " · **★ "
            .. (_("%1 special"):gsub("%%1", tostring(total_special))) .. "**"
    end
    add(stats)
    add("")

    local with_covers = opts.show_covers
    local status_labels = {
        reading = _("Reading"),
        complete = _("Complete"),
        abandoned = _("Abandoned"),
    }

    -- the books split into the ones that belong to a series and the
    -- rest: one table each, a heading only when both exist
    local series_books, plain_books = {}, {}
    for __, b in ipairs(books) do
        if b.series and tostring(b.series) ~= "" then
            series_books[#series_books + 1] = b
        else
            plain_books[#plain_books + 1] = b
        end
    end
    -- the series read in order: by series, then by position in it
    table.sort(series_books, function(a, b)
        local sa = tostring(a.series or ""):lower()
        local sb = tostring(b.series or ""):lower()
        if sa ~= sb then
            return sa < sb
        end
        local ia = tonumber(a.series_index) or math.huge
        local ib = tonumber(b.series_index) or math.huge
        if ia ~= ib then
            return ia < ib
        end
        return tostring(a.title or ""):lower()
            < tostring(b.title or ""):lower()
    end)

    local function filled(v)
        return v ~= nil and tostring(v) ~= ""
    end
    local function any_filled(list, key)
        for __, b in ipairs(list) do
            if filled(b[key]) then
                return true
            end
        end
        return false
    end

    local function addTable(list, with_series)
        local has_author = any_filled(list, "author")
        -- the status cell keeps the word over the bar and the percentage
        -- glued to it; the date is a column of its own, so nothing stacks
        -- three lines deep inside one cell
        local has_status = any_filled(list, "status")
            or any_filled(list, "progress")
        local has_last_read = any_filled(list, "last_read")
        local header, align = {}, {}
        local function column(title, separator)
            header[#header + 1] = title
            align[#align + 1] = separator or ":---"
        end
        if with_covers then
            column(_("Cover"))
        end
        column(_("Book"))
        if has_author then
            column(_("Author"))
        end
        if with_series then
            column(_("Series"))
        end
        if has_status then
            column(_("Status"))
        end
        if has_last_read then
            column(_("Last read"))
        end
        column(_("Highlights"), "---:")
        add("| " .. table.concat(header, " | ") .. " |")
        add("|" .. table.concat(align, "|") .. "|")

        for __, b in ipairs(list) do
            local alias = render.alias(b.title)
            local link = alias ~= "" and ("[[" .. tostring(b.link) .. "\\|" .. alias .. "]]")
                or ("[[" .. tostring(b.link) .. "]]")
            local author = tostring(b.author or ""):gsub("|", "\\|")
                :gsub("[\r\n]+", " ")
            local series = "—"
            if b.series and tostring(b.series) ~= "" then
                series = tostring(b.series)
                if b.series_index ~= nil and tostring(b.series_index) ~= "" then
                    series = series .. " #" .. tostring(b.series_index)
                end
                series = series:gsub("|", "\\|"):gsub("[\r\n]+", " ")
            end
            local special = tonumber(b.special) or 0
            local count_txt = tostring(b.count or 0)
            if special > 0 then
                -- the star speaks every language: 12 · ★3
                count_txt = count_txt .. " · ★" .. tostring(special)
            end
            -- word over the bar, the percentage glued to the bar with a
            -- no-break space so Obsidian can never drop it on its own line;
            -- nothing to show is a dash, as it always was
            local status_cell = "—"
            if has_status then
                local parts = {}
                if b.status and status_labels[b.status] then
                    parts[#parts + 1] = status_labels[b.status]
                end
                local bar = render.progressBar(b.progress)
                local pct = render.progressPct(b.progress)
                if bar and pct then
                    parts[#parts + 1] = bar .. "&nbsp;" .. pct
                elseif bar then
                    parts[#parts + 1] = bar
                elseif pct then
                    parts[#parts + 1] = pct
                end
                if #parts > 0 then
                    status_cell = table.concat(parts, "<br>")
                end
            end
            local cells = {}
            if with_covers then
                cells[#cells + 1] = b.cover and render.coverImg(b.cover, 120, 160)
                    or ""
            end
            cells[#cells + 1] = link
            if has_author then
                cells[#cells + 1] = author
            end
            if with_series then
                cells[#cells + 1] = series
            end
            if has_status then
                cells[#cells + 1] = status_cell
            end
            if has_last_read then
                cells[#cells + 1] = filled(b.last_read)
                    and render.fmtDate(tostring(b.last_read)) or "—"
            end
            cells[#cells + 1] = count_txt
            add("| " .. table.concat(cells, " | ") .. " |")
        end
    end

    if #series_books > 0 and #plain_books > 0 then
        add("### " .. _("Series books"))
        add("")
        addTable(series_books, true)
        add("")
        add("### " .. _("My books"))
        add("")
        addTable(plain_books, false)
    elseif #series_books > 0 then
        addTable(series_books, true)
    else
        addTable(plain_books, false)
    end

    -- the region closes on a blank line, the file ends on the marker
    if out[#out] ~= "" then
        add("")
    end
    if markers then
        table.insert(out, region_from, render.beginMarker("index",
            render.digest(sliceText(out, region_from, #out))))
        add(render.endMarker("index"))
    end
    return table.concat(out, "\n") .. "\n"
end

return render
