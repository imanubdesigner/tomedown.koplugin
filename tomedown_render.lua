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

-- Five-star rating for the index cell: "★★★★☆", or nil when unset.
function render.stars(rating)
    local r = tonumber(rating)
    if not r then
        return nil
    end
    r = math.floor(r + 0.5)
    if r < 1 or r > 5 then
        return nil
    end
    return string.rep("★", r) .. string.rep("☆", 5 - r)
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

-- Values YAML would read as something other than a string. Quoting
-- them keeps the tags and the ledger a list of strings: an unquoted
-- `1500` or `true` makes Obsidian show the whole property as an array.
local YAML_RESERVED = {
    ["true"] = true, ["false"] = true, ["yes"] = true, ["no"] = true,
    ["on"] = true, ["off"] = true, ["y"] = true, ["n"] = true,
    ["null"] = true, ["nan"] = true, ["inf"] = true,
}

-- list item: plain when YAML-safe, quoted otherwise
local function yamlListItem(s)
    s = tostring(s)
    if s:match("^[%a_][%w%s%-_%.']*$")
            and not YAML_RESERVED[s:lower()] then
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
-- Obsidian also needs at least one non-numerical character, so a tag
-- made only of digits is not a tag and comes back empty. The result is
-- idempotent. The caller drops the empty ones.
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
    if s:match("^%d+$") then
        return ""
    end
    return s
end

--- Split a comma separated list into valid Obsidian tags. Every part
-- goes through sanitizeTag, empty parts are dropped and duplicates are
-- removed case-insensitively, keeping the first spelling the reader
-- used. The result is what the book's own menu stores and what both the
-- tags list and the managed-tags ledger write. The second return value
-- names the parts that were made only of digits: they are not tags for
-- Obsidian, so the menu can say they were ignored.
function render.parseTagList(text)
    local out, seen, rejected, seen_rejected = {}, {}, {}, {}
    if type(text) ~= "string" then
        return out, rejected
    end
    for part in text:gmatch("[^,\n]+") do
        local tag = render.sanitizeTag(part)
        if tag ~= "" then
            local key = tag:lower()
            if not seen[key] then
                seen[key] = true
                out[#out + 1] = tag
            end
        else
            local raw = part:gsub("^%s+", ""):gsub("%s+$", "")
            local key = raw:lower()
            if raw:match("%d") and not seen_rejected[key] then
                seen_rejected[key] = true
                rejected[#rejected + 1] = raw
            end
        end
    end
    return out, rejected
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

-- URL-encode spaces and characters that break a standard Markdown link
-- target `[label](target.md)`, while keeping UTF-8 and path slashes.
function render.encodeLinkTarget(s)
    s = tostring(s or "")
    s = s:gsub("%%", "%%25")
    s = s:gsub(" ", "%%20")
    s = s:gsub("%(", "%%28")
    s = s:gsub("%)", "%%29")
    s = s:gsub("%[", "%%5B")
    s = s:gsub("%]", "%%5D")
    s = s:gsub("#", "%%23")
    return s
end

-- Format a book link: in an index table uses an escaped pipe (`[[link\|title]]`)
-- so table columns don't break; in headings or outside tables uses an unescaped
-- pipe (`[[link|title]]`); or a standard Markdown link (`[title](link.md)`).
function render.bookLink(link, title, format, in_table)
    local raw_link = tostring(link or "")
    local alias = render.alias(title)
    if format == "markdown" then
        local label = alias ~= "" and alias or render.alias(raw_link)
        local target = raw_link
        if target:sub(-3):lower() ~= ".md" then
            target = target .. ".md"
        end
        return "[" .. label .. "](" .. render.encodeLinkTarget(target) .. ")"
    end
    local pipe = in_table == false and "|" or "\\|"
    return alias ~= "" and ("[[" .. raw_link .. pipe .. alias .. "]]")
        or ("[[" .. raw_link .. "]]")
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

-- Wrap the quote in styled delimiters (e.g. bold "**", highlight "==",
-- or with a prefix like "⭐ "), paragraph by paragraph: emphasis spans a
-- soft line break but never an empty line, so a quote holding one is wrapped
-- once per paragraph. The edges are trimmed first (CommonMark does not
-- open "** text" nor close "text **"). A paragraph that already carries
-- delimiters at its edges or check_delim inside is left plain: wrapping it
-- would break the syntax. Works on `lines` in place.
local function wrapStyled(lines, open_delim, close_delim, check_delim, prefix_first)
    local i = 1
    local first_paragraph = true
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
            local can_wrap = true
            if check_delim and joined:find(check_delim, 1, true) then
                can_wrap = false
            end
            if first:sub(1, 1) == open_delim:sub(1, 1) or last:sub(-1) == close_delim:sub(-1) then
                can_wrap = false
            end
            local pfx = (first_paragraph and prefix_first) or ""
            if can_wrap then
                if i == j then
                    lines[i] = pfx .. open_delim .. rtrim(first) .. close_delim
                else
                    lines[i] = pfx .. open_delim .. first
                    lines[j] = last .. close_delim
                end
            elseif pfx ~= "" then
                lines[i] = pfx .. lines[i]
            end
            first_paragraph = false
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
    published, rating, review,                 -- optional, imported book info
    date_started, date_finished,               -- optional, imported book info
    collections = { ... },                     -- optional, imported book info
    keywords = { ... },                        -- optional, appended to tags
    tags = { ... },                            -- optional, chosen per book
    tags_managed = true,                       -- write the managed-tags ledger
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
         special_marker = "callout" }          -- or "bold", while callout is off
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
    local valid_markers = {
        callout = true,
        alert = true,
        highlight = true,
        highlight_bold = true,
        star_bold = true,
        bold = true,
    }
    local marker_global = opts.special_marker
    if not valid_markers[marker_global] then
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
    -- imported book information: only present when the reader imported
    -- this one book from its menu, so a normal export is unchanged
    if book.published then
        add("published: " .. yamlQuote(book.published))
    end
    if book.rating then
        add("rating: " .. tostring(book.rating))
    end
    if book.review then
        add("review: " .. yamlQuote(book.review))
    end
    if book.date_started then
        add("date_started: " .. yamlQuote(book.date_started))
    end
    if book.date_finished then
        add("date_finished: " .. yamlQuote(book.date_finished))
    end
    if book.collections and #book.collections > 0 then
        add("collections:")
        for __, collection in ipairs(book.collections) do
            add("  - " .. yamlListItem(collection))
        end
    end
    add("tags:")
    local seen_tags = {}
    local function addTag(tag)
        tag = render.sanitizeTag(tag)
        if tag ~= "" then
            local key = tag:lower()
            if not seen_tags[key] then
                seen_tags[key] = true
                add("  - " .. yamlListItem(tag))
            end
        end
    end
    addTag("ebook")
    addTag(_("highlights"))
    for __, kw in ipairs(book.keywords or {}) do
        addTag(kw)
    end
    -- Tags chosen from the book's own menu. `tomedown_book_tags` below
    -- is the ledger of what this plugin owns: the next merge drops an
    -- old managed tag when it is gone from here, while tags the reader
    -- wrote by hand stay. The ledger of chosen tags is written in every
    -- file, so turning Keep my notes on later still knows what belongs
    -- to the menu; the empty ledger is the signal for a clear and needs
    -- markers, because without them the whole file is replaced and
    -- there is nothing to remove.
    local managed, seen_managed = {}, {}
    if book.tags_managed then
        for __, tag in ipairs(book.tags or {}) do
            tag = render.sanitizeTag(tag)
            if tag ~= "" then
                local key = tag:lower()
                if not seen_managed[key] then
                    seen_managed[key] = true
                    managed[#managed + 1] = tag
                end
            end
        end
    end
    for __, tag in ipairs(managed) do
        addTag(tag)
    end
    if book.tags_managed and (#managed > 0 or markers) then
        if #managed > 0 then
            add("tomedown_book_tags:")
            for __, tag in ipairs(managed) do
                add("  - " .. yamlListItem(tag))
            end
        else
            add("tomedown_book_tags: []")
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
    local use_footnotes = opts.note_style == "footnote"
    local footnotes = {}

    for __, a in ipairs(annotations) do
        if with_chapters then
            local chapter = annotationChapter(a, opts.no_chapter_label)
            if chapter ~= current_chapter then
                heading("# " .. chapter)
                current_chapter = chapter
            end
        end

        add("")
        -- A Special Highlight is marked according to special_marker
        -- (callout, alert, highlight, highlight_bold, star_bold, bold);
        -- the global setting turns every highlight into a callout.
        local marker = marker_global
        local is_special = a.special and not opts.callout
        local as_callout = opts.callout or (is_special and marker == "callout")
        local as_alert = is_special and marker == "alert"
        if as_callout then
            add("> [!highlight]")
        elseif as_alert then
            add("> [!IMPORTANT]")
        end
        local text = tostring(a.text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
        local quote_lines = {}
        for line in (text .. "\n"):gmatch("(.-)\n") do
            quote_lines[#quote_lines + 1] = line
        end
        if is_special then
            if marker == "bold" then
                wrapStyled(quote_lines, "**", "**", "**", nil)
            elseif marker == "highlight" then
                wrapStyled(quote_lines, "==", "==", "==", nil)
            elseif marker == "highlight_bold" then
                wrapStyled(quote_lines, "==**", "**==", "**", nil)
            elseif marker == "star_bold" then
                wrapStyled(quote_lines, "**", "**", "**", "⭐ ")
            end
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
        if use_footnotes and note_lines then
            local fn_idx = #footnotes + 1
            footnotes[fn_idx] = note_lines
            if #meta > 0 then
                add("- " .. table.concat(meta, " · ") .. " [^" .. fn_idx .. "]")
            else
                add("- [^" .. fn_idx .. "]")
            end
        else
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

    if #footnotes > 0 then
        if open then
            add("")
            add("---")
        end
        for fn_idx, lines in ipairs(footnotes) do
            add("")
            local first = true
            for __, line in ipairs(lines) do
                if line:match("^%s*$") then
                    add("")
                elseif first then
                    add("[^" .. fn_idx .. "]: " .. line)
                    first = false
                else
                    add("    " .. line)
                end
            end
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
opts = { title, exported, show_covers, index_layout }
The books land in two tables: those that belong to a series, and the
rest, each under its own heading. The columns adapt to what each group
holds: Series only on the series books, Author, Status and Last read
only when at least one book of the group has them; Book and Highlights
are always there (with the special count in the cell), the cover column
only with opts.show_covers. Tags either sit under the book title, with
a rule between the two (the default), or in a column of their own; the
date can be folded into the status cell for the narrow column layout.
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
        local empty = _("No exported books with highlights.")
        if (tonumber(opts.hidden_books) or 0) > 0 then
            empty = _("Every exported book is hidden from the index.")
        end
        add("_" .. empty .. "_")
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

    -- How the table carries the tags and the last read date. The
    -- default keeps the tags under the book title, where they cannot
    -- widen the table; the two "tags_column" layouts are the older
    -- shape, with the compact one folding the date into the status.
    local layout = opts.index_layout
    if layout ~= "tags_column" and layout ~= "tags_column_compact" then
        layout = "tags_below"
    end
    local tags_below = layout == "tags_below"
    local merged_dates = layout == "tags_column_compact"

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

    -- The books outside a series are the "My books" table, and its
    -- order is the reader's: the four choices in Settings. Series books
    -- keep their own order above and are never touched by this. Ties
    -- fall back to author and title, so two exports always agree.
    local order = opts.index_order
    if order ~= "title" and order ~= "last_read" and order ~= "highlights" then
        order = "author"
    end
    local function text(b, key)
        return tostring(b[key] or ""):lower()
    end
    local function byAuthor(a, b)
        local aa, ba = text(a, "author"), text(b, "author")
        if aa ~= ba then
            return aa < ba
        end
        local at, bt = text(a, "title"), text(b, "title")
        if at ~= bt then
            return at < bt
        end
        return tostring(a.link or "") < tostring(b.link or "")
    end
    table.sort(plain_books, function(a, b)
        if order == "title" then
            local at, bt = text(a, "title"), text(b, "title")
            if at ~= bt then
                return at < bt
            end
            return byAuthor(a, b)
        elseif order == "last_read" then
            local aa = tonumber(a.last_read_sort) or 0
            local bb = tonumber(b.last_read_sort) or 0
            if aa ~= bb then
                return aa > bb
            end
            return byAuthor(a, b)
        elseif order == "highlights" then
            local aa = tonumber(a.count) or 0
            local bb = tonumber(b.count) or 0
            if aa ~= bb then
                return aa > bb
            end
            return byAuthor(a, b)
        end
        return byAuthor(a, b)
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
    -- the index shows the tags chosen from the book menu, as the
    -- clickable #tag Obsidian understands; the entries are sanitized
    -- again because an older file or a test may hand in raw values.
    -- A table cell does not wrap, so a long list is broken into short
    -- lines here: one long line is what makes the table scroll.
    local tag_line_width = 24
    local function tagsLines(tags)
        if type(tags) ~= "table" then
            return {}
        end
        local seen, lines, current = {}, {}, nil
        for __, tag in ipairs(tags) do
            tag = render.sanitizeTag(tag)
            if tag ~= "" then
                local key = tag:lower()
                if not seen[key] then
                    seen[key] = true
                    local piece = "#" .. tag
                    if current == nil then
                        current = piece
                    elseif #current + 1 + #piece <= tag_line_width then
                        current = current .. " " .. piece
                    else
                        lines[#lines + 1] = current
                        current = piece
                    end
                end
            end
        end
        if current ~= nil then
            lines[#lines + 1] = current
        end
        return lines
    end
    -- A thin rule with room above and below, used when the tags sit
    -- under the title instead of in a column of their own.
    local tag_separator = '<hr style="margin:12px 0 10px 0;border:0;'
        .. 'border-top:1px solid rgba(128,128,128,0.45)">'

    local function addTable(list, with_series)
        local has_author = any_filled(list, "author")
        -- the status cell keeps the word over the bar and the percentage
        -- glued to it; the date is a column of its own, so nothing stacks
        -- three lines deep inside one cell
        local has_status = any_filled(list, "status")
            or any_filled(list, "progress")
            or any_filled(list, "rating")
        local has_last_read = any_filled(list, "last_read")
        local has_tags = false
        if not tags_below then
            for __, b in ipairs(list) do
                if #tagsLines(b.tags) > 0 then
                    has_tags = true
                    break
                end
            end
        end
        -- the compact layout has one column for both facts; when only
        -- one of them is present, the title drops the missing half
        local one_date_column = merged_dates and (has_status or has_last_read)
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
        if has_tags then
            column(_("Tags"))
        end
        if one_date_column then
            local title
            if has_status and has_last_read then
                title = _("Status") .. " · " .. _("Last read")
            elseif has_status then
                title = _("Status")
            else
                title = _("Last read")
            end
            column(title)
        else
            if has_status then
                column(_("Status"))
            end
            if has_last_read then
                column(_("Last read"))
            end
        end
        column(_("Highlights"), "---:")
        add("| " .. table.concat(header, " | ") .. " |")
        add("|" .. table.concat(align, "|") .. "|")

        for __, b in ipairs(list) do
            local link = render.bookLink(b.link, b.title, opts.index_links)
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
            local tag_lines = tagsLines(b.tags)
            local book_cell = link
            if tags_below and #tag_lines > 0 then
                book_cell = link .. tag_separator
                    .. table.concat(tag_lines, "<br>")
            end
            -- word over the bar, the percentage glued to the bar with a
            -- no-break space so Obsidian can never drop it on its own line;
            -- nothing to show is a dash, as it always was
            local date_text = filled(b.last_read)
                and render.fmtDate(tostring(b.last_read)) or nil
            local rating_stars = render.stars(b.rating)
            local status_cell = "—"
            if one_date_column then
                local parts = {}
                if b.status and status_labels[b.status] then
                    parts[#parts + 1] = status_labels[b.status]
                end
                if date_text then
                    if #parts > 0 then
                        parts[1] = parts[1] .. " · " .. date_text
                    else
                        parts[1] = date_text
                    end
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
                if rating_stars then
                    parts[#parts + 1] = rating_stars
                end
                if #parts > 0 then
                    status_cell = table.concat(parts, "<br>")
                end
            elseif has_status then
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
                if rating_stars then
                    parts[#parts + 1] = rating_stars
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
            cells[#cells + 1] = book_cell
            if has_author then
                cells[#cells + 1] = author
            end
            if with_series then
                cells[#cells + 1] = series
            end
            if has_tags then
                local tag_text = table.concat(tag_lines, "<br>")
                cells[#cells + 1] = tag_text ~= "" and tag_text or "—"
            end
            if one_date_column then
                cells[#cells + 1] = status_cell
            else
                if has_status then
                    cells[#cells + 1] = status_cell
                end
                if has_last_read then
                    cells[#cells + 1] = date_text or "—"
                end
            end
            cells[#cells + 1] = count_txt
            add("| " .. table.concat(cells, " | ") .. " |")
        end
    end

    -- A shortcut for the books being read: same table, repeated on
    -- purpose, sorted by the last time they were opened. It sits above
    -- the full index and disappears when nothing is being read.
    if opts.reading_now ~= false then
        local reading = {}
        for __, b in ipairs(books) do
            if b.status == "reading" then
                reading[#reading + 1] = b
            end
        end
        table.sort(reading, function(a, b)
            local aa = tonumber(a.last_read_sort) or 0
            local bb = tonumber(b.last_read_sort) or 0
            if aa ~= bb then
                return aa > bb
            end
            return byAuthor(a, b)
        end)
        if #reading > 0 then
            add("### " .. _("Reading now"))
            add("")
            addTable(reading, any_filled(reading, "series"))
            add("")
        end
    end

    -- Each group keeps a heading even when it is alone: the second
    -- table used to arrive with no title at all, which looked like a
    -- duplicate of the one above.
    if #series_books > 0 then
        add("### " .. _("Series books"))
        add("")
        addTable(series_books, true)
        add("")
    end
    if #plain_books > 0 then
        add("### " .. _("My books"))
        add("")
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

--[[
books = {
    {
        link, title, author,
        annotations = {
            { text, note, chapter, page, date, sort_time, sort_page, special },
            ...
        },
    },
    ...
}
opts = {
    title, exported, index_links, callout, special_marker, note_style,
}
Builds a consolidated chronological reading digest (`00 - Reading Digest.md`),
grouping highlights across all books by day (newest day first, and newest
highlight first within each day).
]]
function render.buildDigestMd(books, opts)
    opts = opts or {}
    local title = opts.title or _("Reading digest")
    local out = {}
    local function add(s)
        out[#out + 1] = s
    end

    local items = {}
    local book_seen = {}
    local total_books = 0
    local total_special = 0
    for __, b in ipairs(books or {}) do
        local anns = b.annotations or {}
        if #anns > 0 then
            local bkey = tostring(b.link or b.title or "")
            if not book_seen[bkey] then
                book_seen[bkey] = true
                total_books = total_books + 1
            end
        end
        for ___, a in ipairs(anns) do
            if a.special then
                total_special = total_special + 1
            end
            local raw_dt = tostring(a.sort_time or "")
            local day_iso = raw_dt:match("^(%d%d%d%d%-%d%d%-%d%d)")
            local day_label
            if day_iso then
                day_label = render.fmtDate(day_iso)
            elseif type(a.date) == "string" and a.date ~= "" then
                day_label = a.date:match("^(%d%d/%d%d/%d%d%d%d)") or a.date
                local d, m, y = day_label:match("^(%d%d)/(%d%d)/(%d%d%d%d)$")
                if d and m and y then
                    day_iso = y .. "-" .. m .. "-" .. d
                end
            end
            items[#items + 1] = {
                book_link = b.link or b.base or b.title or "",
                book_title = b.title or b.link or "",
                book_author = b.author,
                text = a.text,
                note = a.note,
                chapter = a.chapter,
                page = a.page,
                date = a.date,
                special = a.special,
                sort_time = raw_dt,
                sort_page = tonumber(a.sort_page) or 0,
                day_key = day_iso or "0000-00-00",
                day_label = day_label or _("Undated"),
            }
        end
    end

    table.sort(items, function(a, b)
        if a.day_key ~= b.day_key then
            return a.day_key > b.day_key
        end
        if a.sort_time ~= b.sort_time then
            return a.sort_time > b.sort_time
        end
        local bt_a = tostring(a.book_title or ""):lower()
        local bt_b = tostring(b.book_title or ""):lower()
        if bt_a ~= bt_b then
            return bt_a < bt_b
        end
        if a.sort_page ~= b.sort_page then
            return a.sort_page < b.sort_page
        end
        return tostring(a.text or "") < tostring(b.text or "")
    end)

    add("---")
    add('tomedown: "' .. render.FORMAT_VERSION .. '"')
    add("title: " .. yamlQuote(title))
    add("exported: " .. yamlQuote(opts.exported or os.date("%Y-%m-%d")))
    add("highlights: " .. tostring(#items))
    add("tags:")
    add("  - ebook")
    add("  - " .. _("digest"))
    add("---")
    add("")
    add("# " .. title)
    add("")
    add('> *"' .. _("Welcome to the quiet space where authors' thoughts linger, and your own reflections take shape.") .. '"*')
    add("")
    add("---")
    add("")

    if #items == 0 then
        add("_" .. _("No exported books with highlights.") .. "_")
        add("")
        return table.concat(out, "\n") .. "\n"
    end

    local books_txt = total_books == 1 and _("%1 book") or _("%1 books")
    local highlights_txt = #items == 1 and _("%1 highlight")
        or _("%1 highlights")
    local stats = "**" .. (books_txt:gsub("%%1", tostring(total_books)))
        .. "** · **" .. (highlights_txt:gsub("%%1", tostring(#items)))
        .. "**"
    if total_special > 0 then
        stats = stats .. " · **★ "
            .. (_("%1 special"):gsub("%%1", tostring(total_special))) .. "**"
    end
    add(stats)

    local valid_markers = {
        callout = true,
        alert = true,
        highlight = true,
        highlight_bold = true,
        star_bold = true,
        bold = true,
    }
    local marker_global = opts.special_marker
    if not valid_markers[marker_global] then
        marker_global = "callout"
    end
    local use_footnotes = opts.note_style == "footnote"
    local footnotes = {}

    local current_day = nil
    local current_book = nil

    for __, item in ipairs(items) do
        if item.day_key ~= current_day then
            if current_day ~= nil then
                add("")
                add("---")
            end
            add("")
            add("## " .. item.day_label)
            current_day = item.day_key
            current_book = nil
        end

        local book_id = tostring(item.book_link) .. "\31" .. tostring(item.book_title)
        if book_id ~= current_book then
            add("")
            local link = render.bookLink(item.book_link, item.book_title, opts.index_links, false)
            if item.book_author and tostring(item.book_author) ~= "" then
                add("### " .. link .. " — *" .. tostring(item.book_author) .. "*")
            else
                add("### " .. link)
            end
            current_book = book_id
        end

        add("")
        local marker = marker_global
        local is_special = item.special and not opts.callout
        local as_callout = opts.callout or (is_special and marker == "callout")
        local as_alert = is_special and marker == "alert"
        if as_callout then
            add("> [!highlight]")
        elseif as_alert then
            add("> [!IMPORTANT]")
        end
        local text = tostring(item.text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
        local quote_lines = {}
        for line in (text .. "\n"):gmatch("(.-)\n") do
            quote_lines[#quote_lines + 1] = line
        end
        if is_special then
            if marker == "bold" then
                wrapStyled(quote_lines, "**", "**", "**", nil)
            elseif marker == "highlight" then
                wrapStyled(quote_lines, "==", "==", "==", nil)
            elseif marker == "highlight_bold" then
                wrapStyled(quote_lines, "==**", "**==", "**", nil)
            elseif marker == "star_bold" then
                wrapStyled(quote_lines, "**", "**", "**", "⭐ ")
            end
        end
        for __, line in ipairs(quote_lines) do
            add("> " .. line)
        end
        add("")

        local meta = {}
        if item.chapter and tostring(item.chapter) ~= "" then
            meta[#meta + 1] = "*" .. tostring(item.chapter) .. "*"
        end
        if item.page and tostring(item.page) ~= "" then
            meta[#meta + 1] = "**p. " .. tostring(item.page) .. "**"
        end
        if item.date and tostring(item.date) ~= "" then
            meta[#meta + 1] = tostring(item.date)
        end

        local note_lines
        if item.note then
            local body = tostring(item.note):gsub("\r\n", "\n"):gsub("\r", "\n")
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

        if use_footnotes and note_lines then
            local fn_idx = #footnotes + 1
            footnotes[fn_idx] = note_lines
            if #meta > 0 then
                add("- " .. table.concat(meta, " · ") .. " [^" .. fn_idx .. "]")
            else
                add("- [^" .. fn_idx .. "]")
            end
        else
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
        end
    end

    if #footnotes > 0 then
        add("")
        add("---")
        for fn_idx, lines in ipairs(footnotes) do
            add("")
            local first = true
            for __, line in ipairs(lines) do
                if line:match("^%s*$") then
                    add("")
                elseif first then
                    add("[^" .. fn_idx .. "]: " .. line)
                    first = false
                else
                    add("    " .. line)
                end
            end
        end
    end

    if out[#out] ~= "" then
        add("")
    end
    return table.concat(out, "\n") .. "\n"
end

return render
