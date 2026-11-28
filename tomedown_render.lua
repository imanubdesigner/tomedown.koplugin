--[[
Markdown text building for tomedown.koplugin.

Nearly pure module: it depends on tomedown_i18n (the plugin's po) and
ffi/sha2 for the block digests (the test suite stubs it), so it can
also be tested with a standard Lua interpreter.
]]

local _ = require("tomedown_i18n")
local md5 = require("ffi/sha2").md5
local render = {}

local COLOR_LABELS = {
    yellow = function() return _("Yellow") end,
    red = function() return _("Red") end,
    orange = function() return _("Orange") end,
    green = function() return _("Green") end,
    blue = function() return _("Blue") end,
    purple = function() return _("Purple") end,
    pink = function() return _("Pink") end,
    gray = function() return _("Gray") end,
    grey = function() return _("Gray") end,
    olive = function() return _("Olive") end,
    cyan = function() return _("Cyan") end,
}

local function formatHighlightColor(color, aliases)
    if type(color) ~= "string" then
        return nil
    end
    local trimmed = color:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" then
        return nil
    end
    local key = trimmed:lower()
    if type(aliases) == "table" then
        local mapped = aliases[key]
        if type(mapped) == "string" then
            mapped = mapped:gsub("^%s+", ""):gsub("%s+$", "")
            if mapped ~= "" then
                return mapped
            end
        end
    end
    local label_fn = COLOR_LABELS[key]
    if label_fn then
        return label_fn()
    end
    return key:sub(1, 1):upper() .. key:sub(2)
end

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

render.FRONTMATTER_KEYS = {
    "title", "author", "cover", "series", "series_index",
    "language", "pages", "exported", "highlights", "special",
    "status", "progress", "custom",
    "published", "rating", "review", "date_started", "date_finished",
    "collections", "tags",
}

render.HIDEABLE_FRONTMATTER_KEYS = {
    "cover", "series", "language", "pages", "exported",
    "highlights", "special", "status", "progress",
}

local HIDEABLE_FRONTMATTER_SET = {}
for __, k in ipairs(render.HIDEABLE_FRONTMATTER_KEYS) do
    HIDEABLE_FRONTMATTER_SET[k] = true
end

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

-- Reading bar for the index cell: five cells, the filled ones rounded
-- from the percentage (each cell represents 20%), and a single filled cell
-- for any progress below 10% so a book just started never shows an empty bar.
-- The percentage rides right after it, joined by a no-break space: render.progressPct.
function render.progressBar(progress)
    if progress == nil then
        return nil
    end
    local pct = tonumber(tostring(progress):match("%d+"))
    if not pct then
        return nil
    end
    local on = math.floor(pct / 20 + 0.5)
    if on < 1 and pct > 0 then
        on = 1
    elseif on > 5 then
        on = 5
    end
    return string.rep("▰", on) .. string.rep("▱", 5 - on)
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
    -- Split on commas, newlines, Calibre subject facet delimiters (--),
    -- and natural language conjunctions (and, &).
    -- When splitting on conjunctions, capitalize the word immediately
    -- following so LCSH compound phrases (e.g. "Detective and mystery stories")
    -- yield consistent capitalized tags ("Detective", "Mystery-stories").
    local normalized = text:gsub("%-%-", ", ")
        :gsub("%s+[aA][nN][dD]%s+(%a)", function(c) return ", " .. c:upper() end)
        :gsub("%s+&%s+(%a)", function(c) return ", " .. c:upper() end)
        :gsub("%s+[aA][nN][dD]%s+", ", ")
        :gsub("%s+&%s+", ", ")
    for part in normalized:gmatch("[^,\n]+") do
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

local SHORT_MONTHS = {
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
}

-- "2026-11-16" or "16/11/2026" -> "16 Nov 2026"
function render.fmtDateLiterary(dt)
    if type(dt) ~= "string" then
        return ""
    end
    local y, m, d = dt:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
    if not y then
        d, m, y = dt:match("^(%d%d)/(%d%d)/(%d%d%d%d)")
    end
    if y and m and d then
        local m_idx = tonumber(m)
        local d_num = tonumber(d)
        local m_name = m_idx and SHORT_MONTHS[m_idx]
        if m_name and d_num then
            return tostring(d_num) .. " " .. m_name .. " " .. y
        end
    end
    return dt
end

-- "2026-11-16 09:29:12" -> "16 Nov 2026 | 09:29"
function render.fmtDateTime(dt)
    if type(dt) ~= "string" then
        return ""
    end
    local y, m, d, hhmm = dt:match("^(%d%d%d%d)-(%d%d)-(%d%d)[ T](%d%d:%d%d)")
    if not y then
        d, m, y, hhmm = dt:match("^(%d%d)/(%d%d)/(%d%d%d%d)[ T](%d%d:%d%d)")
    end
    if y and m and d and hhmm then
        return render.fmtDateLiterary(y .. "-" .. m .. "-" .. d) .. " | " .. hhmm
    end
    return render.fmtDateLiterary(dt)
end

-- "2026-11-16 09:41:20" or "16/11/2026 09:41" or "16 Nov 2026 | 09:41" -> "09:41"
function render.fmtTimeOnly(dt)
    if type(dt) ~= "string" then
        return ""
    end
    local hhmm = dt:match("[ T|]%s*(%d%d:%d%d)") or dt:match("^(%d%d:%d%d)$")
    return hhmm or ""
end

--- Strip HTML tags and decode common HTML entities from an EPUB description.
function render.cleanSynopsis(raw)
    if type(raw) ~= "string" or raw == "" then
        return nil
    end
    local s = raw:gsub("\r\n", "\n"):gsub("\r", "\n")
    s = s:gsub("<[bB][rR]%s*/?>", "\n")
    s = s:gsub("</[pP]>", "\n\n")
    s = s:gsub("</[dD][iI][vV]>", "\n")
    s = s:gsub("<[^>]+>", "")
    s = s:gsub("&nbsp;", " ")
        :gsub("&amp;", "&")
        :gsub("&quot;", '"')
        :gsub("&#39;", "'")
        :gsub("&apos;", "'")
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
    local lines = {}
    for line in (s .. "\n"):gmatch("(.-)\n") do
        local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" then
            lines[#lines + 1] = trimmed
        elseif #lines > 0 and lines[#lines] ~= "" then
            lines[#lines + 1] = ""
        end
    end
    while #lines > 0 and lines[#lines] == "" do
        table.remove(lines)
    end
    if #lines == 0 then
        return nil
    end
    return table.concat(lines, "\n")
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
    s = s:gsub("%^", "%%5E")
    s = s:gsub("|", "%%7C")
    return s
end

local function formatYamlDate(val, default_today)
    local s = val ~= nil and tostring(val) or (default_today and os.date("%Y-%m-%d") or "")
    if s:match("^%d%d%d%d%-%d%d%-%d%d$") then
        return s
    end
    return yamlQuote(s)
end

local function isPlainSingleLineNote(note_lines)
    if #note_lines ~= 1 then
        return false
    end
    local s = note_lines[1]
    if s:find("[*_`~%[%]]")
            or s:match("^[-*+]%s")
            or s:match("^%d+%.%s")
            or s:match("^#") then
        return false
    end
    return true
end

local function renderInlineNote(add, note_lines, has_top_bullet, em_char)
    local em = em_char or "*"
    local head = has_top_bullet and "  - " or "- "
    local pad = has_top_bullet and "    " or "  "
    local label = "**" .. _("Note") .. "**"
    if isPlainSingleLineNote(note_lines) then
        add(head .. label .. " — " .. em .. note_lines[1] .. em)
        return
    end
    local first_line = note_lines[1] or ""
    if first_line:match("^[-*+]%s") or first_line:match("^%d+%.%s") then
        add(head .. label)
        for __, line in ipairs(note_lines) do
            if line:match("^%s*$") then
                add("")
            else
                add(pad .. line)
            end
        end
        return
    end
    local first = true
    for __, line in ipairs(note_lines) do
        if line:match("^%s*$") then
            add("")
        elseif first then
            add(head .. label .. " — " .. line)
            first = false
        else
            add(pad .. line)
        end
    end
end

local function renderCalloutNote(add, note_lines)
    add("")
    add("> [!note] " .. _("Note"))
    for __, line in ipairs(note_lines) do
        if line:match("^%s*$") then
            add(">")
        else
            add("> " .. line)
        end
    end
end

-- Format a book link: in an index table uses an escaped pipe (`[[link\|title]]`)
-- so table columns don't break; in headings or outside tables uses an unescaped
-- pipe (`[[link|title]]`); or a standard Markdown link (`[title](link.md)`).
-- Falls back to an encoded Markdown link in Obsidian too when `link` carries
-- characters that break wikilink target resolution (`#`, `^`, `[`, `]`, `|`).
function render.bookLink(link, title, format, in_table)
    local raw_link = tostring(link or "")
    local alias = render.alias(title)
    if format == "markdown" or raw_link:find("[#%^[%]|]") then
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
    for ann_idx, a in ipairs(annotations) do
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
    for ann_idx, a in ipairs(annotations) do
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
    for ann_idx, a in ipairs(annotations) do
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
    local is_pure_cm = (opts.markdown_style == "commonmark")
    local is_std = (opts.markdown_style == "standard" or is_pure_cm)
    local em = is_pure_cm and "_" or "*"
    local marker_global = opts.special_marker
    if not valid_markers[marker_global] then
        marker_global = "callout"
    end
    if is_std and (marker_global == "callout" or marker_global == "alert"
            or marker_global == "highlight" or marker_global == "highlight_bold") then
        marker_global = "bold"
    end
    local function add(s)
        out[#out + 1] = s
    end
    if opts.block_ids then
        render.assignBlockIds(annotations)
    end

    local fm_hidden = type(opts.fm_hidden) == "table" and opts.fm_hidden or nil
    local function isHidden(key)
        if not fm_hidden or key == "tomedown" then
            return false
        end
        if key == "series_index" then
            return fm_hidden.series == true or fm_hidden.series_index == true
        end
        return HIDEABLE_FRONTMATTER_SET[key] == true and fm_hidden[key] == true
    end

    local fm_blocks = {}
    fm_blocks.title = { "title: " .. yamlQuote(book.title) }
    fm_blocks.author = { "author: " .. yamlQuote(book.author) }
    if opts.cover and not isHidden("cover") then
        fm_blocks.cover = { "cover: " .. yamlQuote(opts.cover) }
    end
    if book.series and not isHidden("series") then
        fm_blocks.series = { "series: " .. yamlQuote(book.series) }
    end
    if book.series and not isHidden("series_index")
            and book.series_index ~= nil and tostring(book.series_index) ~= "" then
        if type(book.series_index) == "number" then
            fm_blocks.series_index = { "series_index: " .. tostring(book.series_index) }
        else
            fm_blocks.series_index = { "series_index: " .. yamlQuote(book.series_index) }
        end
    end
    if book.language and not isHidden("language") then
        fm_blocks.language = { "language: " .. yamlQuote(book.language) }
    end
    if book.pages ~= nil and not isHidden("pages") then
        fm_blocks.pages = { "pages: " .. tostring(book.pages) }
    end
    if not isHidden("exported") then
        fm_blocks.exported = { "exported: " .. formatYamlDate(book.exported, true) }
    end
    if not isHidden("highlights") then
        fm_blocks.highlights = { "highlights: " .. tostring(count) }
    end
    if not isHidden("special") then
        fm_blocks.special = { "special: " .. tostring(special_count) }
    end
    if book.status and not isHidden("status") then
        fm_blocks.status = { "status: " .. yamlQuote(book.status) }
    end
    if book.progress and not isHidden("progress") then
        fm_blocks.progress = { "progress: " .. yamlQuote(book.progress) }
    end
    local explicit_order_set = {}
    if type(opts.fm_order) == "table" then
        for __, k in ipairs(opts.fm_order) do
            if type(k) == "string" then
                explicit_order_set[k:lower()] = true
            end
        end
    end
    if not isHidden("custom") and type(opts.custom_fields) == "table" then
        local custom_lines = {}
        for __, field in ipairs(opts.custom_fields) do
            if type(field) == "table" and field.key and field.key ~= "" then
                local k = field.key
                local lk = k:lower()
                if not (fm_hidden and fm_hidden[lk] == true) and not fm_blocks[lk] then
                    local v = tostring(field.val or "")
                    local qv
                    if v:match('^".*"$') or v:match("^'.*'$")
                            or v:match("^%-?%d+%.?%d*$")
                            or v == "true" or v == "false" or v == "null"
                            or (v:match("^%[.*%]$")
                                and not v:gsub('"[^"]*"', ""):gsub("'[^']*'", ""):find("[[", 1, true)) then
                        qv = v
                    else
                        qv = yamlQuote(v)
                    end
                    local line = k .. ": " .. qv
                    if explicit_order_set[lk] then
                        fm_blocks[lk] = { line }
                    else
                        custom_lines[#custom_lines + 1] = line
                    end
                end
            end
        end
        if #custom_lines > 0 then
            fm_blocks.custom = custom_lines
        end
    end
    -- imported book information: only present when the reader imported
    -- this one book from its menu, so a normal export is unchanged
    if book.published then
        fm_blocks.published = { "published: " .. yamlQuote(book.published) }
    end
    if book.rating then
        fm_blocks.rating = { "rating: " .. tostring(book.rating) }
    end
    if book.review then
        fm_blocks.review = { "review: " .. yamlQuote(book.review) }
    end
    if book.date_started then
        fm_blocks.date_started = { "date_started: " .. formatYamlDate(book.date_started, false) }
    end
    if book.date_finished then
        fm_blocks.date_finished = { "date_finished: " .. formatYamlDate(book.date_finished, false) }
    end
    if book.collections and #book.collections > 0 then
        local col_lines = { "collections:" }
        for __, collection in ipairs(book.collections) do
            col_lines[#col_lines + 1] = "  - " .. yamlListItem(collection)
        end
        fm_blocks.collections = col_lines
    end
    local tag_lines = { "tags:" }
    local seen_tags = {}
    local function addTag(tag)
        tag = render.sanitizeTag(tag)
        if tag ~= "" then
            local key = tag:lower()
            if not seen_tags[key] then
                seen_tags[key] = true
                tag_lines[#tag_lines + 1] = "  - " .. yamlListItem(tag)
            end
        end
    end
    addTag("ebook")
    addTag(_("highlights"))
    for __, kw in ipairs(book.keywords or {}) do
        local sub_tags = render.parseTagList(kw)
        for __, t in ipairs(sub_tags) do
            addTag(t)
        end
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
    fm_blocks.tags = tag_lines

    local key_order = {}
    local seen_order = {}
    local explicit_series_index = false
    if type(opts.fm_order) == "table" then
        for __, k in ipairs(opts.fm_order) do
            if k == "series_index" then
                explicit_series_index = true
            end
        end
        for __, k in ipairs(opts.fm_order) do
            if type(k) == "string" and k ~= "tomedown" and not seen_order[k] then
                seen_order[k] = true
                key_order[#key_order + 1] = k
                if k == "series" and not explicit_series_index and not seen_order.series_index then
                    seen_order.series_index = true
                    key_order[#key_order + 1] = "series_index"
                end
            end
        end
    end
    for __, k in ipairs(render.FRONTMATTER_KEYS) do
        if not seen_order[k] then
            seen_order[k] = true
            key_order[#key_order + 1] = k
        end
    end

    local fm_enabled = opts.fm_enabled ~= false or markers
    if fm_enabled then
        add("---")
        add('tomedown: "' .. render.FORMAT_VERSION .. '"')
        for __, k in ipairs(key_order) do
            local block = fm_blocks[k]
            if block then
                for __, line in ipairs(block) do
                    add(line)
                end
            end
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
    else
        add("# " .. tostring(book.title or ""))
        if book.author and tostring(book.author) ~= "" and tostring(book.author) ~= "N/A" then
            add(em .. tostring(book.author) .. em)
        end
    end
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
        if is_pure_cm then
            local alt = render.alias(book.title or _("Cover"))
            add("![" .. alt .. "](" .. render.encodeLinkTarget(opts.cover) .. ")")
        elseif is_std then
            local csrc = tostring(opts.cover):gsub('"', "&quot;")
            add('<p align="center"><img src="' .. csrc .. '" alt="" width="240"></p>')
        else
            add('<p align="center">' .. render.coverImg(opts.cover, 400, 533) .. "</p>")
        end
        -- second rule frames the cover above the count
        add("")
        add("---")
    end

    local has_book_heading = opts.book_heading == true and fm_enabled
    if has_book_heading then
        add("")
        add("# " .. tostring(book.title or ""))
        local sub_parts = {}
        if book.author and tostring(book.author) ~= "" and tostring(book.author) ~= "N/A" then
            sub_parts[#sub_parts + 1] = (_("by %1"):gsub("%%1", tostring(book.author)))
        end
        if book.series and tostring(book.series) ~= "" then
            local s = em .. tostring(book.series)
            if book.series_index ~= nil and tostring(book.series_index) ~= "" then
                s = s .. " (#" .. tostring(book.series_index) .. ")"
            end
            s = s .. em
            sub_parts[#sub_parts + 1] = s
        end
        if #sub_parts > 0 then
            add("### " .. table.concat(sub_parts, " · "))
        end
        add("")
        add("---")
    end

    local function validBookStyle(s)
        if s == "emoji" or s == "badges" or s == "editorial" then
            return s
        end
        return "minimal"
    end
    local base_book_style = validBookStyle(opts.book_visual_style)
    local dash_style = opts.dashboard_style and validBookStyle(opts.dashboard_style) or base_book_style
    local syn_style = opts.synopsis_style and validBookStyle(opts.synopsis_style) or base_book_style
    local btags_style = opts.body_tags_style and validBookStyle(opts.body_tags_style) or base_book_style
    local show_style = opts.showcase_style and validBookStyle(opts.showcase_style) or base_book_style

    local has_card_extras = false
    if opts.reading_dashboard == true then
        local status_words = {
            reading = _("Reading"),
            complete = _("Complete"),
            abandoned = _("Abandoned"),
        }
        local dash_pfx = is_std and "- " or "> - "
        local dash_title = _("Reading dashboard")
        local dash_heading
        if dash_style == "emoji" then
            dash_heading = "📊 " .. dash_title
        elseif dash_style == "badges" then
            dash_heading = "`" .. dash_title:upper() .. "`"
        else
            dash_heading = dash_title
        end
        add("")
        if is_std then
            add("### " .. dash_heading)
            add("")
        else
            add("> [!book] " .. dash_heading)
        end
        local detail_parts = {}
        if book.progress and tostring(book.progress) ~= ""
                and (book.status ~= "complete" or render.progressPct(book.progress) == "100%") then
            detail_parts[#detail_parts + 1] = tostring(book.progress)
        end
        if book.pages and tonumber(book.pages) and tonumber(book.pages) > 0 then
            detail_parts[#detail_parts + 1] = tostring(book.pages) .. " " .. _("pages")
        end
        local st_parts = {}
        if dash_style == "badges" then
            if book.status and status_words[book.status] then
                st_parts[#st_parts + 1] = "`" .. status_words[book.status]:upper() .. "`"
            end
            for __, dp in ipairs(detail_parts) do
                st_parts[#st_parts + 1] = "`" .. dp:upper() .. "`"
            end
            if #st_parts > 0 then
                add(dash_pfx .. "**" .. _("Status") .. ":** " .. table.concat(st_parts, " · "))
            end
        else
            if book.status and status_words[book.status] then
                local ico = ""
                if dash_style == "emoji" then
                    ico = book.status == "reading" and "🟡 "
                        or (book.status == "complete" and "🟢 " or "⚪ ")
                elseif dash_style == "minimal" then
                    ico = book.status == "reading" and "◐ "
                        or (book.status == "complete" and "● " or "○ ")
                end
                st_parts[#st_parts + 1] = ico .. "**" .. status_words[book.status] .. "**"
            end
            if #detail_parts > 0 then
                st_parts[#st_parts + 1] = "(" .. table.concat(detail_parts, " · ") .. ")"
            end
            if #st_parts > 0 then
                add(dash_pfx .. "**" .. _("Status") .. ":** " .. table.concat(st_parts, " "))
            end
        end
        local r_stars = render.stars(book.rating)
        if r_stars then
            if dash_style == "emoji" then
                add(dash_pfx .. "**" .. _("Rating") .. ":** ⭐ " .. r_stars .. " (" .. tostring(book.rating) .. "/5)")
            elseif dash_style == "badges" then
                add(dash_pfx .. "**" .. _("Rating") .. ":** " .. r_stars .. " `" .. tostring(book.rating) .. "/5`")
            else
                add(dash_pfx .. "**" .. _("Rating") .. ":** " .. r_stars .. " (" .. tostring(book.rating) .. "/5)")
            end
        end
        if book.date_started or book.date_finished then
            local d_parts = {}
            if book.date_started then
                d_parts[#d_parts + 1] = render.fmtDateLiterary(tostring(book.date_started))
            end
            if book.date_finished then
                d_parts[#d_parts + 1] = render.fmtDateLiterary(tostring(book.date_finished))
            end
            add(dash_pfx .. "**" .. _("Reading dates") .. ":** " .. table.concat(d_parts, " → "))
        end
        local link_fmt = is_std and "markdown" or opts.index_links
        local nav_links = {}
        if opts.with_index ~= false then
            nav_links[#nav_links + 1] = render.bookLink("00 - Index", "← " .. _("Book index"), link_fmt, false)
        end
        if opts.with_digest == true then
            nav_links[#nav_links + 1] = render.bookLink("00 - Reading Digest", _("Reading digest") .. " →", link_fmt, false)
        end
        if #nav_links > 0 then
            local nav_label = opts.with_index ~= false and _("Index") or _("Reading digest")
            add(dash_pfx .. "**" .. nav_label .. ":** " .. table.concat(nav_links, " · "))
        end
        has_card_extras = true
    end

    if opts.book_synopsis == true then
        local syn = render.cleanSynopsis(book.description)
        if syn then
            local syn_mode = opts.synopsis_mode
            if syn_mode ~= "short" and syn_mode ~= "collapsed_short" and syn_mode ~= "expanded" then
                syn_mode = "collapsed"
            end
            if syn_mode == "short" or syn_mode == "collapsed_short" then
                local flat = syn:gsub("%s*\n+%s*", " "):gsub("%s+", " ")
                if #flat > 300 then
                    local head = flat:sub(1, 300)
                    local sent_end = head:match("^(.+[%.%!%?])%s")
                    if sent_end and #sent_end >= 120 then
                        syn = sent_end .. " …"
                    else
                        local word_cut = head:match("^(.+)%s+%S*$") or head
                        word_cut = word_cut:gsub("[,;:%-%s]+$", "")
                        syn = word_cut .. "…"
                    end
                else
                    syn = flat
                end
            end
            local is_folded = (syn_mode == "collapsed" or syn_mode == "collapsed_short")
            local syn_title = _("Book synopsis")
            local syn_heading
            if syn_style == "emoji" then
                syn_heading = "📖 " .. syn_title
            elseif syn_style == "badges" then
                syn_heading = "`" .. syn_title:upper() .. "`"
            elseif syn_style == "editorial" then
                syn_heading = syn_title
            else
                syn_heading = "§ " .. syn_title
            end
            add("")
            if is_std then
                if is_folded and not is_pure_cm then
                    local sum_html = syn_style == "badges"
                        and ("<code>" .. syn_title:upper() .. "</code>")
                        or ("<b>" .. syn_heading .. "</b>")
                    local p_list = {}
                    for line in (syn .. "\n"):gmatch("(.-)\n") do
                        if line ~= "" then
                            local esc = line:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
                            p_list[#p_list + 1] = "<p>" .. esc .. "</p>"
                        end
                    end
                    add("<details>")
                    add("<summary>" .. sum_html .. "</summary>")
                    add("<blockquote>" .. table.concat(p_list, "") .. "</blockquote>")
                    add("</details>")
                else
                    add("### " .. syn_heading)
                    add("")
                    for line in (syn .. "\n"):gmatch("(.-)\n") do
                        add(line == "" and ">" or ("> " .. line))
                    end
                end
            else
                local fold_sign = is_folded and "-" or "+"
                add("> [!abstract]" .. fold_sign .. " " .. syn_heading)
                for line in (syn .. "\n"):gmatch("(.-)\n") do
                    add(line == "" and ">" or ("> " .. line))
                end
            end
            has_card_extras = true
        end
    end

    if opts.body_tags == true then
        local btags, bseen = {}, {}
        local function addBodyTag(raw_t)
            for __, st in ipairs(render.parseTagList(tostring(raw_t or ""))) do
                local k = st:lower()
                if not bseen[k] then
                    bseen[k] = true
                    btags[#btags + 1] = "#" .. st
                end
            end
        end
        for __, kw in ipairs(book.keywords or {}) do
            addBodyTag(kw)
        end
        for __, tg in ipairs(book.tags or {}) do
            addBodyTag(tg)
        end
        if #btags > 0 then
            add("")
            if btags_style == "badges" then
                add("`" .. table.concat(btags, "` `") .. "`")
            elseif btags_style == "editorial" then
                add(em .. _("Tags") .. ":" .. em .. " " .. table.concat(btags, " · "))
            elseif btags_style == "emoji" then
                add("🏷️ " .. table.concat(btags, " · "))
            else
                add("▪ " .. em .. table.concat(btags, em .. " · " .. em) .. em)
            end
            has_card_extras = true
        end
    end

    if has_card_extras then
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
        local ostyle = opts.overview_style or "inline"
        add("")
        if ostyle == "blockquote" then
            add("> **" .. headline .. "**")
        elseif ostyle == "callout" then
            if is_std then
                add("> **" .. headline .. "**")
            else
                add("> [!summary] " .. _("Overview"))
                add("> **" .. headline .. "**")
            end
        elseif ostyle == "table" then
            if special_count > 0 then
                add("| " .. _("Highlights") .. " | " .. _("Special") .. " |")
                add("|:---:|:---:|")
                add("| " .. tostring(count) .. " | ★ " .. tostring(special_count) .. " |")
            else
                add("| " .. _("Highlights") .. " |")
                add("|:---:|")
                add("| " .. tostring(count) .. " |")
            end
        elseif has_book_heading then
            add("### **" .. headline .. "**")
        else
            add("# **" .. headline .. "**")
        end
        add("")
        add("---")
    end

    if opts.special_showcase == true and special_count > 0 then
        local show_heading
        if show_style == "emoji" then
            show_heading = "⭐ " .. _("Special highlights") .. " (" .. tostring(special_count) .. ")"
        elseif show_style == "badges" then
            show_heading = _("Special highlights") .. " `(" .. tostring(special_count) .. ")`"
        elseif show_style == "editorial" then
            show_heading = _("Special highlights") .. " (" .. tostring(special_count) .. ")"
        else
            show_heading = "★ " .. _("Special highlights") .. " (" .. tostring(special_count) .. ")"
        end
        add("")
        if is_std then
            add("### " .. show_heading)
            add("")
        else
            add("> [!highlight]- " .. show_heading)
        end
        local first_sp = true
        for ann_idx, a in ipairs(annotations) do
            if a.special then
                if not first_sp then
                    if is_std then
                        add("")
                    else
                        add(">")
                        add("> ---")
                        add(">")
                    end
                end
                first_sp = false
                local stext = tostring(a.text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
                for line in (stext .. "\n"):gmatch("(.-)\n") do
                    add("> “" .. line .. "”")
                end
                local ref = {}
                if a.chapter and tostring(a.chapter) ~= "" then
                    ref[#ref + 1] = tostring(a.chapter)
                end
                if a.page and tostring(a.page) ~= "" then
                    ref[#ref + 1] = "p. " .. tostring(a.page)
                end
                if opts.block_ids and a.id and not is_std then
                    local ref_label = #ref > 0 and render.alias(table.concat(ref, " · ")) or ""
                    if ref_label ~= "" then
                        add("> — [[#^" .. a.id .. "|" .. ref_label .. "]]")
                    else
                        add("> — [[#^" .. a.id .. "|→]]")
                    end
                elseif #ref > 0 then
                    add("> — " .. em .. table.concat(ref, " · ") .. em)
                end
            end
        end
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

    local chapter_mode = opts.chapter_headings or "h1"
    local sep_mode = opts.highlight_separator or "none"
    local is_editorial_sep = (sep_mode == "editorial_dots" or sep_mode == "editorial_line")
    local sep_str = (sep_mode == "line" or sep_mode == "editorial_line") and "---"
        or ((sep_mode == "dots" or sep_mode == "editorial_dots") and "· · ·" or nil)
    local chapter_prefix = "# "
    if chapter_mode == "h2" or (chapter_mode == "h1" and (sep_mode == "line" or sep_mode == "editorial_line")) then
        chapter_prefix = "## "
    elseif chapter_mode == "h3" then
        chapter_prefix = "### "
    end
    local with_chapters = chapter_mode ~= "none" and hasAnyChapter(annotations)
    local current_chapter = nil
    local use_footnotes = opts.note_style == "footnote"
    local use_note_callout = not is_std and opts.note_style == "callout"
    local details_mode = opts.highlight_details or "page_date"
    local show_page = details_mode == "page_date" or details_mode == "page_only"
    local show_date = details_mode == "page_date" or details_mode == "date_only"
    local show_context = opts.highlight_context == true
    local show_color = opts.highlight_color == true
    local color_aliases = opts.color_aliases
    local footnotes = {}

    local function formatContext(a)
        if type(a.context) == "string" then
            local c = a.context:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
            if c ~= "" then
                return c
            end
        end
        local prev = type(a.context_prev) == "string"
            and a.context_prev:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "") or ""
        local nxt = type(a.context_next) == "string"
            and a.context_next:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "") or ""
        if prev ~= "" and nxt ~= "" then
            return "…" .. prev .. " … " .. nxt .. "…"
        elseif prev ~= "" then
            return "…" .. prev .. " …"
        elseif nxt ~= "" then
            return "… " .. nxt .. "…"
        end
        return nil
    end

    for ann_idx, a in ipairs(annotations) do
        if with_chapters then
            local chapter = annotationChapter(a, opts.no_chapter_label)
            if chapter ~= current_chapter then
                heading(chapter_prefix .. chapter)
                current_chapter = chapter
            end
        end

        add("")
        -- A Special Highlight is marked according to special_marker
        -- (callout, alert, highlight, highlight_bold, star_bold, bold);
        -- the global setting turns every highlight into a callout.
        local marker = marker_global
        local is_special = a.special and not opts.callout
        local as_callout = not is_std and (opts.callout or (is_special and marker == "callout"))
        local as_alert = not is_std and (is_special and marker == "alert")
        if a.handwritten then
            if a.drawing and tostring(a.drawing) ~= "" then
                local alt = _("Handwritten note")
                if a.page and tostring(a.page) ~= "" then
                    alt = alt .. " · p. " .. tostring(a.page)
                end
                local img_md = "![" .. alt .. "](" .. render.encodeLinkTarget(a.drawing) .. ")"
                if as_callout then
                    add("> [!highlight]")
                    add("> " .. img_md)
                elseif as_alert then
                    add("> [!IMPORTANT]")
                    add("> " .. img_md)
                else
                    add(img_md)
                end
            else
                if as_callout then
                    add("> [!highlight]")
                elseif as_alert then
                    add("> [!IMPORTANT]")
                end
                add("> ✍️ " .. tostring(a.text or _("Handwritten note")))
            end
        else
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
        end
        -- Obsidian block ID: the end of the last line of the quote (or
        -- of the callout), after any closing emphasis. Checked in
        -- Obsidian: a link jumps to, and an embed shows, the whole
        -- quote, multi-paragraph and callout included.
        if opts.block_ids and a.id and not is_std then
            out[#out] = out[#out] .. " ^" .. a.id
        end

        local meta = {}
        if show_page and a.page and tostring(a.page) ~= "" then
            meta[#meta + 1] = "**p. " .. tostring(a.page) .. "**"
        end
        if show_date and a.date and tostring(a.date) ~= "" then
            meta[#meta + 1] = tostring(a.date)
        end
        if a.handwritten then
            meta[#meta + 1] = "✍️ " .. _("Handwritten note")
        elseif show_color then
            local col_label = formatHighlightColor(a.color, color_aliases)
            if col_label then
                meta[#meta + 1] = col_label
            end
        end
        local ctx_line = show_context and formatContext(a) or nil
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
        if is_editorial_sep and not a.handwritten then
            local ed_meta = {}
            if show_page and a.page and tostring(a.page) ~= "" then
                ed_meta[#ed_meta + 1] = "p. " .. tostring(a.page)
            end
            if show_date and a.date and tostring(a.date) ~= "" then
                ed_meta[#ed_meta + 1] = tostring(a.date)
            end
            if show_color then
                local col_label = formatHighlightColor(a.color, color_aliases)
                if col_label then
                    ed_meta[#ed_meta + 1] = col_label
                end
            end
            local fn_ref
            if use_footnotes and note_lines then
                footnotes[#footnotes + 1] = note_lines
                fn_ref = "[^" .. #footnotes .. "]"
                note_lines = nil
            end
            if #ed_meta > 0 then
                local attr = "> — " .. em .. table.concat(ed_meta, " · ") .. em
                if fn_ref then
                    attr = attr .. " " .. fn_ref
                end
                add(attr)
            elseif fn_ref then
                add("> — " .. fn_ref)
            end
            if ctx_line then
                add("")
                add("**" .. _("Context:") .. "** " .. em .. ctx_line .. em)
            end
            if note_lines then
                add("")
                if use_note_callout then
                    add("> [!note] " .. _("Note"))
                    for __, line in ipairs(note_lines) do
                        add("> " .. line)
                    end
                elseif #note_lines == 1 then
                    add("**" .. _("Note:") .. "** " .. note_lines[1])
                else
                    add("**" .. _("Note:") .. "**")
                    for __, line in ipairs(note_lines) do
                        add(line)
                    end
                end
            end
        elseif #meta > 0 or ctx_line or note_lines or details_mode ~= "none" then
            add("")
            local has_top_bullet = #meta > 0
            if use_footnotes and note_lines then
                local fn_idx = #footnotes + 1
                footnotes[fn_idx] = note_lines
                if #meta > 0 then
                    add("- " .. table.concat(meta, " · ") .. " [^" .. fn_idx .. "]")
                else
                    add("- [^" .. fn_idx .. "]")
                end
                has_top_bullet = true
                if ctx_line then
                    add("  - **" .. _("Context:") .. "** " .. em .. ctx_line .. em)
                end
            elseif use_note_callout and note_lines then
                if #meta > 0 or ctx_line then
                    if #meta > 0 then
                        add("- " .. table.concat(meta, " · "))
                    end
                    if ctx_line then
                        local chead = has_top_bullet and "  - " or "- "
                        add(chead .. "**" .. _("Context:") .. "** " .. em .. ctx_line .. em)
                    end
                end
                renderCalloutNote(add, note_lines)
            else
                if #meta > 0 then
                    add("- " .. table.concat(meta, " · "))
                end
                if ctx_line then
                    local chead = has_top_bullet and "  - " or "- "
                    add(chead .. "**" .. _("Context:") .. "** " .. em .. ctx_line .. em)
                    has_top_bullet = true
                end
                if note_lines then
                    renderInlineNote(add, note_lines, has_top_bullet, em)
                elseif not has_top_bullet then
                    add("- …")
                end
            end
        end
        if sep_str and ann_idx < #annotations then
            local next_a = annotations[ann_idx + 1]
            local same_chapter = not with_chapters
                or (annotationChapter(next_a, opts.no_chapter_label) == current_chapter)
            if same_chapter then
                add("")
                add(sep_str)
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
    add("exported: " .. formatYamlDate(opts.exported, true))
    add("tags:")
    add("  - ebook")
    local idx_tag = render.sanitizeTag(_("index"))
    if idx_tag ~= "" and idx_tag:lower() ~= "ebook" then
        add("  - " .. yamlListItem(idx_tag))
    end
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
    local completed_count, reading_count = 0, 0
    for __, b in ipairs(books) do
        total_highlights = total_highlights + (tonumber(b.count) or 0)
        total_special = total_special + (tonumber(b.special) or 0)
        if b.status == "complete" then
            completed_count = completed_count + 1
        elseif b.status == "reading" then
            reading_count = reading_count + 1
        end
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
    local idx_pure_cm = (opts.markdown_style == "commonmark")
    local idx_std = (opts.markdown_style == "standard" or idx_pure_cm)
    local idx_em = idx_pure_cm and "_" or "*"
    local idx_style = opts.index_style
    if idx_style ~= "emoji" and idx_style ~= "badges" and idx_style ~= "editorial" then
        idx_style = "minimal"
    end
    if opts.index_dashboard == true then
        local pfx = idx_std and "- " or "> "
        if idx_std then
            add("### " .. _("Library dashboard"))
            add("")
        else
            add("> [!summary] " .. _("Library dashboard"))
        end
        local b_line, h_line
        if idx_style == "badges" then
            b_line = "`" .. (books_txt:gsub("%%1", tostring(#books))):upper() .. "`"
            if completed_count > 0 then
                b_line = b_line .. " · `" .. tostring(completed_count) .. " " .. _("Complete"):upper() .. "`"
            end
            if reading_count > 0 then
                b_line = b_line .. " · `" .. tostring(reading_count) .. " " .. _("Reading"):upper() .. "`"
            end
            h_line = "`" .. (highlights_txt:gsub("%%1", tostring(total_highlights))):upper() .. "`"
            if total_special > 0 then
                h_line = h_line .. " · `★ "
                    .. (_("%1 special"):gsub("%%1", tostring(total_special))):upper() .. "`"
            end
        elseif idx_style == "editorial" then
            b_line = "**" .. (books_txt:gsub("%%1", tostring(#books))) .. "**"
            if completed_count > 0 then
                b_line = b_line .. " · **" .. tostring(completed_count) .. " " .. _("Complete") .. "**"
            end
            if reading_count > 0 then
                b_line = b_line .. " · **" .. tostring(reading_count) .. " " .. _("Reading") .. "**"
            end
            h_line = "**" .. (highlights_txt:gsub("%%1", tostring(total_highlights))) .. "**"
            if total_special > 0 then
                h_line = h_line .. " · **"
                    .. (_("%1 special"):gsub("%%1", tostring(total_special))) .. "**"
            end
        else
            local c_ico = idx_style == "minimal" and "● " or "🟢 "
            local r_ico = idx_style == "minimal" and "◐ " or "🟡 "
            b_line = "**" .. (books_txt:gsub("%%1", tostring(#books))) .. "**"
            if completed_count > 0 then
                b_line = b_line .. " · **" .. c_ico .. tostring(completed_count) .. " " .. _("Complete") .. "**"
            end
            if reading_count > 0 then
                b_line = b_line .. " · **" .. r_ico .. tostring(reading_count) .. " " .. _("Reading") .. "**"
            end
            h_line = "**" .. (highlights_txt:gsub("%%1", tostring(total_highlights))) .. "**"
            if total_special > 0 then
                h_line = h_line .. " · **★ "
                    .. (_("%1 special"):gsub("%%1", tostring(total_special))) .. "**"
            end
        end
        add(pfx .. b_line)
        add(pfx .. h_line)
        if opts.with_digest ~= false then
            local digest_link = render.bookLink("00 - Reading Digest", _("Reading digest") .. " →",
                idx_std and "markdown" or opts.index_links, false)
            add(pfx .. digest_link)
        end
        add("")
    else
        if opts.with_digest == true then
            local digest_link = render.bookLink("00 - Reading Digest", _("Reading digest") .. " →",
                idx_std and "markdown" or opts.index_links, false)
            add(stats .. " · " .. digest_link)
        else
            add(stats)
        end
        add("")
    end

    if opts.index_tag_cloud == true then
        local tag_counts, tag_names = {}, {}
        for __, b in ipairs(books) do
            local seen_in_book = {}
            for ___, raw_t in ipairs(b.tags or {}) do
                for ____, st in ipairs(render.parseTagList(tostring(raw_t or ""))) do
                    local k = st:lower()
                    if not seen_in_book[k] then
                        seen_in_book[k] = true
                        tag_counts[k] = (tag_counts[k] or 0) + 1
                        if not tag_names[k] then
                            tag_names[k] = st
                        end
                    end
                end
            end
        end
        local sorted_tags = {}
        for k, cnt in pairs(tag_counts) do
            sorted_tags[#sorted_tags + 1] = { key = k, name = tag_names[k], count = cnt }
        end
        table.sort(sorted_tags, function(a, b)
            if a.count ~= b.count then
                return a.count > b.count
            end
            return a.key < b.key
        end)
        if #sorted_tags > 0 then
            local cloud_parts = {}
            if idx_std then
                if idx_style == "badges" then
                    for __, item in ipairs(sorted_tags) do
                        cloud_parts[#cloud_parts + 1] = "`" .. item.name .. " (" .. tostring(item.count) .. ")`"
                    end
                    add("> " .. table.concat(cloud_parts, " "))
                elseif idx_style == "editorial" then
                    for __, item in ipairs(sorted_tags) do
                        cloud_parts[#cloud_parts + 1] = "#" .. item.name .. " " .. idx_em .. "(" .. tostring(item.count) .. ")" .. idx_em
                    end
                    add("> " .. idx_em .. _("Tags") .. ":" .. idx_em .. " " .. table.concat(cloud_parts, " · "))
                elseif idx_style == "emoji" then
                    for __, item in ipairs(sorted_tags) do
                        cloud_parts[#cloud_parts + 1] = "#" .. item.name .. " (" .. tostring(item.count) .. ")"
                    end
                    add("> 🏷️ " .. table.concat(cloud_parts, " · "))
                else
                    for __, item in ipairs(sorted_tags) do
                        cloud_parts[#cloud_parts + 1] = idx_em .. "#" .. item.name .. idx_em .. " (" .. tostring(item.count) .. ")"
                    end
                    add("> ▪ " .. table.concat(cloud_parts, " · "))
                end
            else
                if idx_style == "badges" then
                    for __, item in ipairs(sorted_tags) do
                        cloud_parts[#cloud_parts + 1] = "`#" .. item.name .. " (" .. tostring(item.count) .. ")`"
                    end
                    add(table.concat(cloud_parts, " "))
                elseif idx_style == "editorial" then
                    for __, item in ipairs(sorted_tags) do
                        cloud_parts[#cloud_parts + 1] = "#" .. item.name .. " *(" .. tostring(item.count) .. ")*"
                    end
                    add("*" .. _("Tags") .. ":* " .. table.concat(cloud_parts, " · "))
                elseif idx_style == "emoji" then
                    for __, item in ipairs(sorted_tags) do
                        cloud_parts[#cloud_parts + 1] = "#" .. item.name .. " (" .. tostring(item.count) .. ")"
                    end
                    add("🏷️ " .. table.concat(cloud_parts, " · "))
                else
                    for __, item in ipairs(sorted_tags) do
                        cloud_parts[#cloud_parts + 1] = "*#" .. item.name .. "* (" .. tostring(item.count) .. ")"
                    end
                    add("▪ " .. table.concat(cloud_parts, " · "))
                end
            end
            add("")
        end
    end

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
    -- Each tag pill is wrapped in a span with white-space:nowrap so
    -- hyphens never break across lines, while the outer container gives
    -- vertical line-height breathing room for natural multi-line wrapping.
    local tags_mode = opts.index_tags_mode or "all"
    local function tagsPillsHtml(tags, mode_override)
        if type(tags) ~= "table" then
            return ""
        end
        local mode = mode_override or tags_mode
        local seen, pills = {}, {}
        for __, raw_tag in ipairs(tags) do
            local str = tostring(raw_tag or "")
            local norm_tag = str:gsub("%-%-", ", ")
                :gsub("%s+[aA][nN][dD]%s+(%a)", function(c) return ", " .. c:upper() end)
                :gsub("%s+&%s+(%a)", function(c) return ", " .. c:upper() end)
                :gsub("%s+[aA][nN][dD]%s+", ", ")
                :gsub("%s+&%s+", ", ")
            for part in norm_tag:gmatch("[^,\n]+") do
                local tag = render.sanitizeTag(part)
                if tag ~= "" then
                    local key = tag:lower()
                    if not seen[key] then
                        seen[key] = true
                        if idx_std then
                            pills[#pills + 1] = "#" .. tag
                        else
                            pills[#pills + 1] = '<span style="white-space:nowrap">#' .. tag .. '</span>'
                        end
                    end
                end
            end
        end
        if #pills == 0 then
            return ""
        end
        if idx_std then
            if (mode == "first_3" or mode == "collapsible") and #pills > 3 then
                local head = { pills[1], pills[2], pills[3] }
                local extra = #pills - 3
                return idx_em .. table.concat(head, " ") .. " +" .. tostring(extra) .. idx_em
            end
            return idx_em .. table.concat(pills, " ") .. idx_em
        end
        if mode == "first_3" and #pills > 3 then
            local head = { pills[1], pills[2], pills[3] }
            local extra = #pills - 3
            return '<span style="line-height:1.9;display:inline-block">'
                .. table.concat(head, " ")
                .. ' <span style="opacity:0.65;white-space:nowrap">+' .. tostring(extra) .. '</span></span>'
        elseif mode == "collapsible" and #pills > 3 then
            local head = { pills[1], pills[2], pills[3] }
            local rest = {}
            for i = 4, #pills do
                rest[#rest + 1] = pills[i]
            end
            local extra = #pills - 3
            return '<span style="line-height:1.9;display:inline-block">'
                .. table.concat(head, " ")
                .. ' <details style="display:inline"><summary style="display:inline;cursor:pointer;opacity:0.75">+'
                .. tostring(extra) .. '</summary> ' .. table.concat(rest, " ") .. '</details></span>'
        end
        return '<span style="line-height:1.9;display:inline-block">'
            .. table.concat(pills, " ") .. '</span>'
    end
    render.tagsPillsHtml = tagsPillsHtml
    -- A thin rule with room above and below in Obsidian; a clean <br> in
    -- Standard Markdown so GFM editors like MarkText don't show raw <hr> HTML.
    local tag_separator = idx_std and "<br>"
        or ('<hr style="margin:12px 0 10px 0;border:0;'
            .. 'border-top:1px solid rgba(128,128,128,0.45)">')

    local function formatStatus(status)
        if not status or not status_labels[status] then
            return nil
        end
        if idx_style == "badges" then
            return "`" .. status_labels[status]:upper() .. "`"
        elseif idx_style == "editorial" then
            return "**" .. status_labels[status] .. "**"
        elseif idx_style == "emoji" then
            local ico = status == "reading" and "🟡 "
                or (status == "complete" and "🟢 " or "⚪ ")
            return ico .. status_labels[status]
        else
            local ico = status == "reading" and "◐ "
                or (status == "complete" and "● " or "○ ")
            return ico .. status_labels[status]
        end
    end

    local function formatProgress(progress)
        local bar = render.progressBar(progress)
        local pct = render.progressPct(progress)
        if idx_style == "badges" then
            return pct and ("`" .. pct .. "`") or nil
        elseif idx_style == "editorial" then
            return pct
        end
        if bar and pct then
            return bar .. (idx_pure_cm and " " or "&nbsp;") .. pct
        end
        return bar or pct
    end

    local function addTable(list, with_series)
        if idx_std then
            local has_covers = (not idx_pure_cm) and with_covers and any_filled(list, "cover")
            if has_covers then
                add("| | |")
                add("|:---|:---|")
            end
            for i, b in ipairs(list) do
                local link = render.bookLink(b.link, b.title, "markdown", false)
                local head = "**" .. link .. "**"
                local head_meta = {}
                if filled(b.author) then
                    local a = tostring(b.author):gsub("[\r\n]+", " ")
                    if has_covers then
                        a = a:gsub("|", "\\|")
                    end
                    head_meta[#head_meta + 1] = idx_em .. a .. idx_em
                end
                if filled(b.series) then
                    local series = tostring(b.series):gsub("[\r\n]+", " ")
                    if filled(b.series_index) then
                        series = series .. " #" .. tostring(b.series_index)
                    end
                    if has_covers then
                        series = series:gsub("|", "\\|")
                    end
                    head_meta[#head_meta + 1] = idx_em .. series .. idx_em
                end
                if #head_meta > 0 then
                    head = head .. " — " .. table.concat(head_meta, " · ")
                end

                local meta = {}
                local pct = render.progressPct(b.progress)
                -- A book marked Complete in KOReader can still carry an older
                -- partial percent_finished (e.g. 18%); omit partial progress
                -- so Complete cards never contradict themselves.
                local show_prog = not (b.status == "complete" and pct ~= "100%")
                local st_txt = formatStatus(b.status)
                local prog_txt = show_prog and formatProgress(b.progress) or nil
                if idx_style == "editorial" then
                    if st_txt and prog_txt then
                        meta[#meta + 1] = st_txt .. " (" .. prog_txt .. ")"
                    elseif st_txt then
                        meta[#meta + 1] = st_txt
                    elseif prog_txt then
                        meta[#meta + 1] = prog_txt
                    end
                else
                    if st_txt then
                        meta[#meta + 1] = st_txt
                    end
                    if prog_txt then
                        meta[#meta + 1] = prog_txt
                    end
                end
                local rating_stars = render.stars(b.rating)
                if rating_stars then
                    meta[#meta + 1] = rating_stars
                end
                local date_text = filled(b.last_read)
                    and render.fmtDate(tostring(b.last_read)) or nil
                if date_text then
                    meta[#meta + 1] = _("Last read") .. ": " .. date_text
                end
                local cnt = tonumber(b.count) or 0
                local hl_txt = (cnt == 1 and _("%1 highlight") or _("%1 highlights"))
                    :gsub("%%1", tostring(cnt))
                meta[#meta + 1] = "**" .. hl_txt .. "**"
                local special = tonumber(b.special) or 0
                if special > 0 then
                    meta[#meta + 1] = "★" .. tostring(special)
                end

                local body_parts = {}
                if #meta > 0 then
                    body_parts[#body_parts + 1] = table.concat(meta, " · ")
                end
                local tag_md = tagsPillsHtml(b.tags)
                if tag_md ~= "" then
                    body_parts[#body_parts + 1] = tag_md
                end

                if idx_pure_cm then
                    if i > 1 then
                        add("")
                        add("---")
                        add("")
                    end
                    add("- " .. head)
                    if with_covers and filled(b.cover) then
                        local calt = render.alias(b.title or _("Cover"))
                        add("  - ![" .. calt .. "](" .. render.encodeLinkTarget(b.cover) .. ")")
                    end
                    for __, bp in ipairs(body_parts) do
                        add("  - " .. bp)
                    end
                elseif has_covers then
                    local cover_cell = filled(b.cover)
                        and string.format('<img src="%s" alt="" width="120">',
                            tostring(b.cover):gsub('"', "&quot;"))
                        or ""
                    local right_cell = #body_parts > 0
                        and (head .. "<br><br>" .. table.concat(body_parts, "<br>"))
                        or head
                    add("| " .. cover_cell .. " | " .. right_cell .. " |")
                else
                    if i > 1 then
                        add("")
                        add("---")
                        add("")
                    end
                    add("- " .. head)
                    if #body_parts > 0 then
                        add("  " .. table.concat(body_parts, "<br>"))
                    end
                end
            end
            return
        end

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
                if tagsPillsHtml(b.tags) ~= "" then
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
            local tag_html = tagsPillsHtml(b.tags)
            local book_cell = link
            if tags_below and tag_html ~= "" then
                book_cell = link .. tag_separator .. tag_html
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
                local st_txt = formatStatus(b.status)
                if st_txt then
                    parts[#parts + 1] = st_txt
                end
                if date_text then
                    if #parts > 0 then
                        parts[1] = parts[1] .. " · " .. date_text
                    else
                        parts[1] = date_text
                    end
                end
                local prog_txt = formatProgress(b.progress)
                if prog_txt then
                    parts[#parts + 1] = prog_txt
                end
                if rating_stars then
                    parts[#parts + 1] = rating_stars
                end
                if #parts > 0 then
                    status_cell = table.concat(parts, "<br>")
                end
            elseif has_status then
                local parts = {}
                local st_txt = formatStatus(b.status)
                if st_txt then
                    parts[#parts + 1] = st_txt
                end
                local prog_txt = formatProgress(b.progress)
                if prog_txt then
                    parts[#parts + 1] = prog_txt
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
                cells[#cells + 1] = b.cover and render.coverImg(b.cover, 90, 120)
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
                cells[#cells + 1] = tag_html ~= "" and tag_html or "—"
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

    local function addSectionHeading(emoji_icon, min_icon, title, count)
        local h_pfx = idx_std and "## " or "### "
        if idx_std then
            add("---")
            add("")
        end
        if idx_style == "badges" then
            add(h_pfx .. title .. " `(" .. tostring(count) .. ")`")
        elseif idx_style == "editorial" then
            add(h_pfx .. title .. " (" .. tostring(count) .. ")")
        elseif idx_style == "emoji" then
            add(h_pfx .. emoji_icon .. " " .. title .. " (" .. tostring(count) .. ")")
        else
            local prefix = min_icon ~= "" and (min_icon .. " ") or ""
            add(h_pfx .. prefix .. title .. " (" .. tostring(count) .. ")")
        end
        add("")
    end

    if opts.completed_books == true then
        local completed = {}
        for __, b in ipairs(books) do
            if b.status == "complete" then
                completed[#completed + 1] = b
            end
        end
        table.sort(completed, function(a, b)
            local aa = tonumber(a.last_read_sort) or 0
            local bb = tonumber(b.last_read_sort) or 0
            if aa ~= bb then
                return aa > bb
            end
            return byAuthor(a, b)
        end)
        if #completed > 0 then
            addSectionHeading("🟢", "✓", _("Completed books"), #completed)
            addTable(completed, any_filled(completed, "series"))
            add("")
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
            addSectionHeading("🟡", "▸", _("Reading now"), #reading)
            addTable(reading, any_filled(reading, "series"))
            add("")
        end
    end

    -- Each group keeps a heading even when it is alone: the second
    -- table used to arrive with no title at all, which looked like a
    -- duplicate of the one above.
    if #series_books > 0 then
        addSectionHeading("📚", "§", _("Series books"), #series_books)
        addTable(series_books, true)
        add("")
    end
    if #plain_books > 0 then
        addSectionHeading("📖", "▪", _("My books"), #plain_books)
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
        local book_wants_ids = (opts.markdown_style ~= "standard" and opts.markdown_style ~= "commonmark")
            and ((opts.block_ids and b.has_block_ids ~= false) or b.has_block_ids == true)
        if #anns > 0 then
            local bkey = tostring(b.link or b.title or "")
            if not book_seen[bkey] then
                book_seen[bkey] = true
                total_books = total_books + 1
            end
            if book_wants_ids then
                render.assignBlockIds(anns)
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
                day_label = render.fmtDateLiterary(day_iso)
            elseif type(a.date) == "string" and a.date ~= "" then
                local raw_day = a.date:match("^(%d%d/%d%d/%d%d%d%d)") or a.date
                local d, m, y = raw_day:match("^(%d%d)/(%d%d)/(%d%d%d%d)$")
                if d and m and y then
                    day_iso = y .. "-" .. m .. "-" .. d
                    day_label = render.fmtDateLiterary(day_iso)
                else
                    day_label = render.fmtDateLiterary(raw_day)
                end
            end
            local time_only = render.fmtTimeOnly(raw_dt ~= "" and raw_dt or a.date)
            items[#items + 1] = {
                book_link = b.link or b.base or b.title or "",
                book_title = b.title or b.link or "",
                id = book_wants_ids and a.id or nil,
                book_author = b.author,
                text = a.text,
                note = a.note,
                chapter = a.chapter,
                page = a.page,
                date = a.date,
                time = time_only,
                special = a.special,
                handwritten = a.handwritten,
                color = a.color,
                highlight_color = b.highlight_color,
                drawing = a.drawing_vault_rel or a.drawing,
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
    add("exported: " .. formatYamlDate(opts.exported, true))
    add("highlights: " .. tostring(#items))
    add("tags:")
    add("  - ebook")
    local dig_tag = render.sanitizeTag(_("digest"))
    if dig_tag ~= "" and dig_tag:lower() ~= "ebook" then
        add("  - " .. yamlListItem(dig_tag))
    end
    add("---")
    add("")
    local dig_pure_cm = (opts.markdown_style == "commonmark")
    local dig_em = dig_pure_cm and "_" or "*"
    add("# " .. title)
    add("")
    add('> ' .. dig_em .. '"' .. _("Welcome to the quiet space where authors' thoughts linger, and your own reflections take shape.") .. '"' .. dig_em)
    add("")
    add("---")
    add("")

    if #items == 0 then
        add("_" .. _("No exported books with highlights.") .. "_")
        add("")
        return table.concat(out, "\n") .. "\n"
    end

    local digest_style = opts.visual_style
    if digest_style ~= "emoji" and digest_style ~= "badges" and digest_style ~= "editorial" then
        digest_style = "minimal"
    end
    local books_txt = total_books == 1 and _("%1 book") or _("%1 books")
    local highlights_txt = #items == 1 and _("%1 highlight")
        or _("%1 highlights")
    local books_str = books_txt:gsub("%%1", tostring(total_books))
    local hl_str = highlights_txt:gsub("%%1", tostring(#items))
    local sp_str = (_("%1 special"):gsub("%%1", tostring(total_special)))
    local stats
    if digest_style == "badges" then
        stats = "`" .. books_str:upper() .. "` · `" .. hl_str:upper() .. "`"
        if total_special > 0 then
            stats = stats .. " · `★ " .. sp_str:upper() .. "`"
        end
    elseif digest_style == "emoji" then
        stats = "📚 **" .. books_str .. "** · ✍️ **" .. hl_str .. "**"
        if total_special > 0 then
            stats = stats .. " · ⭐ **" .. sp_str .. "**"
        end
    elseif digest_style == "editorial" then
        stats = "**" .. books_str .. "** · **" .. hl_str .. "**"
        if total_special > 0 then
            stats = stats .. " · **" .. sp_str .. "**"
        end
    else
        stats = "**" .. books_str .. "** · **" .. hl_str .. "**"
        if total_special > 0 then
            stats = stats .. " · **★ " .. sp_str .. "**"
        end
    end
    local digest_std = (opts.markdown_style == "standard" or dig_pure_cm)
    local idx_back_link
    if opts.with_index == true then
        idx_back_link = render.bookLink("00 - Index", "← " .. _("Book index"),
            digest_std and "markdown" or opts.index_links, false)
    end
    local ostyle = opts.overview_style or "inline"
    if ostyle == "blockquote" then
        add("> " .. stats .. (idx_back_link and (" · " .. idx_back_link) or ""))
    elseif ostyle == "callout" then
        if digest_std then
            add("> " .. stats .. (idx_back_link and (" · " .. idx_back_link) or ""))
        else
            add("> [!summary] " .. _("Overview"))
            add("> " .. stats .. (idx_back_link and (" · " .. idx_back_link) or ""))
        end
    elseif ostyle == "table" then
        if total_special > 0 then
            add("| " .. _("Books") .. " | " .. _("Highlights") .. " | " .. _("Special") .. " |")
            add("|:---:|:---:|:---:|")
            add("| " .. tostring(total_books) .. " | " .. tostring(#items) .. " | ★ " .. tostring(total_special) .. " |")
        else
            add("| " .. _("Books") .. " | " .. _("Highlights") .. " |")
            add("|:---:|:---:|")
            add("| " .. tostring(total_books) .. " | " .. tostring(#items) .. " |")
        end
        if idx_back_link then
            add("")
            add(idx_back_link)
        end
    else
        add(stats .. (idx_back_link and (" · " .. idx_back_link) or ""))
    end

    local valid_markers = {
        callout = true,
        alert = true,
        highlight = true,
        highlight_bold = true,
        star_bold = true,
        bold = true,
    }
    local is_pure_cm = (opts.markdown_style == "commonmark")
    local is_std = (opts.markdown_style == "standard" or is_pure_cm)
    local em = is_pure_cm and "_" or "*"
    local marker_global = opts.special_marker
    if not valid_markers[marker_global] then
        marker_global = "callout"
    end
    if is_std and (marker_global == "callout" or marker_global == "alert"
            or marker_global == "highlight" or marker_global == "highlight_bold") then
        marker_global = "bold"
    end
    local digest_callout = not digest_std and opts.callout or false
    local use_footnotes = opts.note_style == "footnote"
    local use_note_callout = not digest_std and opts.note_style == "callout"
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
            if digest_style == "emoji" then
                add("## 📅 " .. item.day_label)
            elseif digest_style == "badges" then
                add("## `" .. tostring(item.day_label):upper() .. "`")
            else
                add("## " .. item.day_label)
            end
            current_day = item.day_key
            current_book = nil
        end

        local book_id = tostring(item.book_link) .. "\31" .. tostring(item.book_title)
        if book_id ~= current_book then
            if current_book ~= nil then
                add("")
                add("---")
            end
            add("")
            local link = render.bookLink(item.book_link, item.book_title,
                digest_std and "markdown" or opts.index_links, false)
            local book_pfx = digest_style == "emoji" and "📖 " or ""
            if item.book_author and tostring(item.book_author) ~= "" then
                add("### " .. book_pfx .. link .. " — " .. dig_em .. tostring(item.book_author) .. dig_em)
            else
                add("### " .. book_pfx .. link)
            end
            current_book = book_id
        end

        add("")
        local marker = marker_global
        local is_special = item.special and not digest_callout
        local as_callout = not digest_std and (digest_callout or (is_special and marker == "callout"))
        local as_alert = not digest_std and (is_special and marker == "alert")
        if item.handwritten then
            if item.drawing and tostring(item.drawing) ~= "" then
                local alt = _("Handwritten note")
                if item.page and tostring(item.page) ~= "" then
                    alt = alt .. " · p. " .. tostring(item.page)
                end
                local img_md = "![" .. alt .. "](" .. render.encodeLinkTarget(item.drawing) .. ")"
                if as_callout then
                    add("> [!highlight]")
                    add("> " .. img_md)
                elseif as_alert then
                    add("> [!IMPORTANT]")
                    add("> " .. img_md)
                else
                    add(img_md)
                end
            else
                if as_callout then
                    add("> [!highlight]")
                elseif as_alert then
                    add("> [!IMPORTANT]")
                end
                add("> ✍️ " .. tostring(item.text or _("Handwritten note")))
            end
        else
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
        end
        add("")

        local meta = {}
        local can_deeplink = not digest_std
            and opts.index_links ~= "markdown"
            and item.id ~= nil
            and tostring(item.book_link or "") ~= ""
            and not tostring(item.book_link):find("[#%^[%]|]")
        if can_deeplink then
            local loc_parts = {}
            if item.chapter and tostring(item.chapter) ~= "" then
                loc_parts[#loc_parts + 1] = tostring(item.chapter)
            end
            if item.page and tostring(item.page) ~= "" then
                loc_parts[#loc_parts + 1] = "p. " .. tostring(item.page)
            end
            local loc_label = #loc_parts > 0 and render.alias(table.concat(loc_parts, " · ")) or ""
            if loc_label == "" then
                loc_label = "→"
            end
            meta[#meta + 1] = "[[" .. tostring(item.book_link) .. "#^" .. item.id .. "|" .. loc_label .. "]]"
        else
            if item.chapter and tostring(item.chapter) ~= "" then
                meta[#meta + 1] = dig_em .. tostring(item.chapter) .. dig_em
            end
            if item.page and tostring(item.page) ~= "" then
                meta[#meta + 1] = "**p. " .. tostring(item.page) .. "**"
            end
        end
        if item.time and tostring(item.time) ~= "" then
            meta[#meta + 1] = tostring(item.time)
        end
        if item.handwritten then
            meta[#meta + 1] = "✍️ " .. _("Handwritten note")
        elseif (item.highlight_color ~= nil and item.highlight_color == true)
                or (item.highlight_color == nil and opts.highlight_color == true) then
            local col_label = formatHighlightColor(item.color, opts.color_aliases)
            if col_label then
                meta[#meta + 1] = col_label
            end
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
        elseif use_note_callout and note_lines then
            if #meta > 0 then
                add("- " .. table.concat(meta, " · "))
            end
            renderCalloutNote(add, note_lines)
        else
            if #meta > 0 then
                add("- " .. table.concat(meta, " · "))
            end
            if note_lines then
                renderInlineNote(add, note_lines, #meta > 0, dig_em)
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

function render.buildBookTxt(book, opts)
    opts = opts or {}
    local annotations = book.annotations or {}
    local count = book.count or #annotations
    local special_count = 0
    for ann_idx, a in ipairs(annotations) do
        if a.special then
            special_count = special_count + 1
        end
    end
    local out = {}
    local function add(s)
        out[#out + 1] = s
    end

    add(tostring(book.title or ""))
    if book.author and tostring(book.author) ~= "" and tostring(book.author) ~= "N/A" then
        add(tostring(book.author))
    end
    local summary = {}
    if book.series and tostring(book.series) ~= "" then
        local s = tostring(book.series)
        if book.series_index and tostring(book.series_index) ~= "" then
            s = s .. " #" .. tostring(book.series_index)
        end
        summary[#summary + 1] = s
    end
    if count > 0 then
        local hl = count == 1 and _("%1 highlight") or _("%1 highlights")
        hl = hl:gsub("%%1", tostring(count))
        if special_count > 0 then
            hl = hl .. " · ★ " .. (_("%1 special"):gsub("%%1", tostring(special_count)))
        end
        summary[#summary + 1] = hl
    end
    summary[#summary + 1] = tostring(book.exported or os.date("%Y-%m-%d"))
    add(table.concat(summary, " · "))
    add(string.rep("=", 72))

    if type(opts.user_notes_head) == "string" and opts.user_notes_head:find("%S") then
        add("")
        if opts.notes_title and opts.notes_title ~= "" then
            add(opts.notes_title)
            add(string.rep("-", math.min(72, #opts.notes_title)))
        end
        add((opts.user_notes_head:gsub("^%s+", ""):gsub("%s+$", "")))
        add("")
        add(string.rep("-", 72))
    end

    local chapter_mode = opts.chapter_headings or "h1"
    local with_chapters = chapter_mode ~= "none" and hasAnyChapter(annotations)
    local current_chapter = nil
    local details_mode = opts.highlight_details or "page_date"
    local show_page = details_mode == "page_date" or details_mode == "page_only"
    local show_date = details_mode == "page_date" or details_mode == "date_only"
    local show_context = opts.highlight_context == true

    local function formatContext(a)
        if type(a.context) == "string" then
            local c = a.context:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
            if c ~= "" then
                return c
            end
        end
        local prev = type(a.context_prev) == "string"
            and a.context_prev:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "") or ""
        local nxt = type(a.context_next) == "string"
            and a.context_next:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "") or ""
        if prev ~= "" and nxt ~= "" then
            return "…" .. prev .. " … " .. nxt .. "…"
        elseif prev ~= "" then
            return "…" .. prev .. " …"
        elseif nxt ~= "" then
            return "… " .. nxt .. "…"
        end
        return nil
    end

    for ann_idx, a in ipairs(annotations) do
        if with_chapters then
            local chapter = annotationChapter(a, opts.no_chapter_label)
            if chapter ~= current_chapter then
                add("")
                add(chapter)
                add(string.rep("-", math.min(72, math.max(3, #chapter))))
                current_chapter = chapter
            end
        end
        add("")
        local text = tostring(a.text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
        local prefix = a.special and "★ " or ""
        if a.handwritten then
            add(prefix .. "✍️ " .. (text ~= "" and text or _("Handwritten note")))
        else
            add(prefix .. text)
        end

        local meta = {}
        if show_page and a.page and tostring(a.page) ~= "" then
            meta[#meta + 1] = "p. " .. tostring(a.page)
        end
        if show_date and a.date and tostring(a.date) ~= "" then
            meta[#meta + 1] = tostring(a.date)
        end
        if not a.handwritten and opts.highlight_color == true then
            local col_label = formatHighlightColor(a.color, opts.color_aliases)
            if col_label then
                meta[#meta + 1] = col_label
            end
        end
        if #meta > 0 then
            add("[" .. table.concat(meta, " · ") .. "]")
        end
        local ctx_line = show_context and formatContext(a) or nil
        if ctx_line then
            add(_("Context:") .. " " .. ctx_line)
        end
        if a.note and tostring(a.note):find("%S") then
            local note = tostring(a.note):gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("^%s+", ""):gsub("%s+$", "")
            add("NOTE: " .. note)
        end
    end

    local bookmarks = book.bookmarks or {}
    if #bookmarks > 0 then
        add("")
        local bm_title = _("Page bookmarks")
        add(bm_title)
        add(string.rep("-", math.min(72, math.max(3, #bm_title))))
        for __, b in ipairs(bookmarks) do
            add("")
            if b.text and tostring(b.text) ~= "" then
                add(tostring(b.text):gsub("\r\n", "\n"):gsub("\r", "\n"))
            end
            local bmeta = {}
            if b.page and tostring(b.page) ~= "" then
                bmeta[#bmeta + 1] = "p. " .. tostring(b.page)
            end
            if b.date and tostring(b.date) ~= "" then
                bmeta[#bmeta + 1] = tostring(b.date)
            end
            if #bmeta > 0 then
                add("[" .. table.concat(bmeta, " · ") .. "]")
            end
        end
    end

    if type(opts.user_notes_tail) == "string" and opts.user_notes_tail:find("%S") then
        add("")
        add(string.rep("-", 72))
        add((opts.user_notes_tail:gsub("^%s+", ""):gsub("%s+$", "")))
    end

    if out[#out] ~= "" then
        add("")
    end
    return table.concat(out, "\n") .. "\n"
end

return render
