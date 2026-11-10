--[[
Settings and file helpers shared by main.lua and the menu, export and
upload modules.

Everything here used to sit at the top of main.lua. The three modules
read the same settings and the same write zone, so the helpers moved
here once instead of being copied into each one. The bodies are
unchanged.
]]

local _ = require("tomedown_i18n")
local logger = require("logger")
local md5 = require("ffi/sha2").md5
local util = require("util")

local SETTINGS_KEY = "tomedown"
local DEFAULT_LOCAL_SUBDIR = "clipboard/tomedown"
local DEFAULT_COVERS_FOLDER = "covers"
local INDEX_FILENAME = "00 - Index.md"
local DIGEST_FILENAME = "00 - Reading Digest.md"
local FILENAME_TEMPLATE = "%A - %T"

-- settings (everything in G_reader_settings under a single key)

local function getSetting(key, default)
    local value = G_reader_settings:readSetting(SETTINGS_KEY, {})[key]
    if value == nil then
        return default
    end
    return value
end

local function setSetting(key, value)
    local settings = G_reader_settings:readSetting(SETTINGS_KEY, {})
    settings[key] = value
    G_reader_settings:saveSetting(SETTINGS_KEY, settings)
end

-- Title of the heading that names the writable zone in an exported
-- file: the file's own title when it asked for one, the global one
-- otherwise (translated default until the reader renames it from the
-- Markdown menu, "" when they asked for no heading at all). Books are
-- keyed the same way as "preserve_books" (the book file path), the
-- index by its filename. The global switch, while it is on, names
-- every zone itself: the per file titles stay where they are, dormant
-- until it is off again.
local function getNotesTitle(file)
    if file and not getSetting("preserve", false) then
        local titles = getSetting("notes_titles", {})
        if titles[file] ~= nil then
            return titles[file]
        end
    end
    local value = getSetting("notes_title", nil)
    if value == nil then
        return _("My notes...")
    end
    return value
end

local function setBookNotesTitle(file, title)
    local titles = getSetting("notes_titles", {})
    titles[file] = title
    setSetting("notes_titles", titles)
end

-- preserve per file: while the global switch is on it alone governs
-- every file, and the per book rows stay out of the way; with it off,
-- a book's own choice wins over the default, which stays for books
-- that never chose anything (whoever turned it on under 1.0 keeps it
-- on for every one of them). The map is keyed the same way as
-- "exports", the book file path, and no choice is ever dropped.
local function getBookPreserve(file)
    local global = getSetting("preserve", false)
    if global then
        return true
    end
    local choice = getSetting("preserve_books", {})[file]
    if choice ~= nil then
        return choice
    end
    return global
end

local function setBookPreserve(file, on)
    local choices = getSetting("preserve_books", {})
    choices[file] = on and true or false
    setSetting("preserve_books", choices)
end

-- Tags the reader added to a book from its own menu. The map is keyed
-- like "exports" (the book file path). A missing entry means the book
-- never chose anything; an empty table means the tags were cleared on
-- purpose. The difference matters: only an explicit choice lets the
-- export drop the tags it managed before.
local function getBookTags(file)
    if not file then
        return nil
    end
    local tags = getSetting("book_tags", {})[file]
    if type(tags) ~= "table" then
        return nil
    end
    return tags
end

local function setBookTags(file, tags)
    local all = getSetting("book_tags", {})
    all[file] = tags or {}
    setSetting("book_tags", all)
end

local function clearBookTags(file)
    if not file then
        return
    end
    local all = getSetting("book_tags", {})
    all[file] = nil
    setSetting("book_tags", all)
end

-- Imported book info: the explicit, per-book switch that lets Tomedown
-- read rating, review, publication date, reading dates, collections and
-- the shared keywords into the note. A book stays exactly as 1.2.0 left
-- it until it is imported; once imported, the flag also gates ownership
-- of the new frontmatter keys and the automatic updates. Keyed like
-- "exports" (the book file path).
local function getBookImported(file)
    if not file then
        return false
    end
    return getSetting("bookinfo_imported", {})[file] == true
end

local function setBookImported(file, on)
    if not file then
        return
    end
    local all = getSetting("bookinfo_imported", {})
    if on then
        all[file] = true
    else
        all[file] = nil
    end
    setSetting("bookinfo_imported", all)
end

-- Automatic updates of imported books. On by default, but it only ever
-- applies to imported books: a normal book is never touched by it.
local function getAutoBookInfo()
    return getSetting("bookinfo_auto", true) ~= false
end

local function setAutoBookInfo(on)
    setSetting("bookinfo_auto", on and true or false)
end

-- Per-field date overrides for an imported book. A nil value means
-- "use the automatic date"; an empty string is never stored. The map is
-- keyed by the book file path, then by field name.
local DATE_OVERRIDE_FIELDS = {
    published = true, date_started = true, date_finished = true,
}

local function getBookOverride(file, field)
    if not file or not DATE_OVERRIDE_FIELDS[field] then
        return nil
    end
    local value = getSetting("bookinfo_dates", {})[file]
    value = type(value) == "table" and value[field] or nil
    return type(value) == "string" and value ~= "" and value or nil
end

local function setBookOverride(file, field, value)
    if not file or not DATE_OVERRIDE_FIELDS[field] then
        return
    end
    local all = getSetting("bookinfo_dates", {})
    local book = type(all[file]) == "table" and all[file] or {}
    book[field] = type(value) == "string" and value ~= "" and value or nil
    if next(book) then
        all[file] = book
    else
        all[file] = nil
    end
    setSetting("bookinfo_dates", all)
end

local function clearBookOverrides(file)
    if not file then
        return
    end
    local all = getSetting("bookinfo_dates", {})
    all[file] = nil
    setSetting("bookinfo_dates", all)
end

-- What the auto-update hooks compare against: the summary fields and
-- the shared keywords as they were at the last export. Saved only by a
-- successful export, so a modification made while the feature is off is
-- still seen when it comes back on.
local function getBookInfoSnapshot(file)
    if not file then
        return nil
    end
    local snapshot = getSetting("bookinfo_snapshot", {})[file]
    return type(snapshot) == "table" and snapshot or nil
end

local function setBookInfoSnapshot(file, snapshot)
    if not file then
        return
    end
    local all = getSetting("bookinfo_snapshot", {})
    all[file] = snapshot
    setSetting("bookinfo_snapshot", all)
end

local function clearBookInfoSnapshot(file)
    if not file then
        return
    end
    local all = getSetting("bookinfo_snapshot", {})
    all[file] = nil
    setSetting("bookinfo_snapshot", all)
end

-- A one-shot marker: the note has to lose the imported fields before
-- the import flag goes away. Used only by "Remove imported book info".
local function getBookInfoRemoval(file)
    return file ~= nil and getSetting("bookinfo_removal", {})[file] == true
end

local function setBookInfoRemoval(file, on)
    if not file then
        return
    end
    local all = getSetting("bookinfo_removal", {})
    all[file] = on and true or nil
    setSetting("bookinfo_removal", all)
end

-- Where a book goes: nil is the normal state (exported and shown in
-- the index), "index" keeps it out of the index only, "none" stops the
-- export too. The note already written is never deleted: both states
-- only decide what the next runs do. The map is keyed like "exports"
-- (the book file path).
local function getBookExclusion(file)
    if not file then
        return nil
    end
    local value = getSetting("book_exclusions", {})[file]
    if value == "index" or value == "none" then
        return value
    end
    return nil
end

local function setBookExclusion(file, value)
    if not file then
        return
    end
    local all = getSetting("book_exclusions", {})
    if value == "index" or value == "none" then
        all[file] = value
    else
        all[file] = nil
    end
    setSetting("book_exclusions", all)
end

-- Tags seen while exporting, for the suggestions in the tag menu: a
-- map keyed by the lowercase tag, each entry { name = <tag>, count =
-- <books> }. The count is the largest number of books one run has seen
-- carrying that tag, not a running total: a single-book export (auto
-- close) must not make one tag look more common than the whole library.
local function getKnownTags()
    local known = getSetting("known_tags", {})
    if type(known) ~= "table" then
        return {}
    end
    return known
end

local function mergeKnownTags(counts)
    if type(counts) ~= "table" then
        return
    end
    local known = getKnownTags()
    local deleted = getSetting("deleted_tags", {})
    if type(deleted) ~= "table" then
        deleted = {}
    end
    local changed = false
    for key, entry in pairs(counts) do
        if type(entry) == "table" and type(entry.name) == "string"
                and not deleted[key] then
            local previous = known[key]
            local count = tonumber(entry.count) or 0
            if type(previous) ~= "table"
                    or (tonumber(previous.count) or 0) < count then
                known[key] = { name = entry.name, count = count }
                changed = true
            end
        end
    end
    if changed then
        setSetting("known_tags", known)
    end
end

-- Drop one tag from the suggestion cache and remember the deletion so
-- future exports do not re-add it from book metadata. The menu passes
-- the sanitized spelling; the key is case-insensitive.
local function forgetKnownTag(tag)
    if type(tag) ~= "string" or tag == "" then
        return false
    end
    local key = tag:lower()
    local known = getKnownTags()
    local had = known[key] ~= nil
    if had then
        known[key] = nil
        setSetting("known_tags", known)
    end
    local deleted = getSetting("deleted_tags", {})
    if type(deleted) ~= "table" then
        deleted = {}
    end
    if not deleted[key] then
        deleted[key] = true
        setSetting("deleted_tags", deleted)
    end
    return had
end

local function allowKnownTag(tag)
    if type(tag) ~= "string" or tag == "" then
        return
    end
    local deleted = getSetting("deleted_tags", {})
    if type(deleted) ~= "table" then
        return
    end
    local key = tag:lower()
    if deleted[key] then
        deleted[key] = nil
        setSetting("deleted_tags", deleted)
    end
end

-- The index is a file like the others, and since 1.1 it carries its
-- own switch: it keeps its zone when the reader asks for it, and
-- otherwise follows the global default. It used to ride along with
-- whatever any book had chosen, which switched the index on behind
-- the reader's back; now nothing turns it on but the global switch or
-- this choice, and with the global switch on it is covered like every
-- other file (the row below it in Settings then goes away).
local function getIndexPreserve()
    local global = getSetting("preserve", false)
    if global then
        return true
    end
    local choice = getSetting("preserve_index", nil)
    if choice ~= nil then
        return choice
    end
    return global
end

local function getFilenameTemplate()
    local tpl = getSetting("filename_template", FILENAME_TEMPLATE)
    if type(tpl) ~= "string" or tpl == "" then
        return FILENAME_TEMPLATE
    end
    return tpl
end

local function setFilenameTemplate(tpl)
    if type(tpl) ~= "string" then
        tpl = ""
    end
    tpl = tpl:gsub("^%s+", ""):gsub("%s+$", "")
    if tpl == "" or tpl == FILENAME_TEMPLATE then
        setSetting("filename_template", nil)
    else
        setSetting("filename_template", tpl)
    end
end

local function getFolderLayout()
    local layout = getSetting("folder_layout", "flat")
    if layout == "author" or layout == "series" or layout == "status" then
        return layout
    end
    return "flat"
end

local function setFolderLayout(layout)
    if layout == "author" or layout == "series" or layout == "status" then
        setSetting("folder_layout", layout)
    else
        setSetting("folder_layout", nil)
    end
end

local function getIndexLinks()
    local fmt = getSetting("index_links", "wikilink")
    if fmt == "markdown" then
        return "markdown"
    end
    return "wikilink"
end

local function setIndexLinks(fmt)
    if fmt == "markdown" then
        setSetting("index_links", "markdown")
    else
        setSetting("index_links", nil)
    end
end

local function getBookStyleOverride(file, key)
    if not file or not key then
        return nil
    end
    local all = getSetting("book_style", nil)
    if type(all) ~= "table" or type(all[file]) ~= "table" then
        return nil
    end
    return all[file][key]
end

local function setBookStyleOverride(file, key, val)
    if not file or not key then
        return
    end
    local all = getSetting("book_style", {})
    if type(all) ~= "table" then
        all = {}
    end
    local entry = type(all[file]) == "table" and all[file] or {}
    entry[key] = val
    if next(entry) == nil then
        all[file] = nil
    else
        all[file] = entry
    end
    setSetting("book_style", next(all) and all or nil)
end

local function hasBookStyleOverrides(file)
    if not file then
        return false
    end
    local all = getSetting("book_style", nil)
    return type(all) == "table" and type(all[file]) == "table" and next(all[file]) ~= nil
end

local function clearBookStyleOverrides(file)
    if not file then
        return
    end
    local all = getSetting("book_style", nil)
    if type(all) ~= "table" or all[file] == nil then
        return
    end
    all[file] = nil
    setSetting("book_style", next(all) and all or nil)
end

local function getNoteStyle(file)
    local override = file and getBookStyleOverride(file, "note_style")
    local style = override or getSetting("note_style", "inline")
    if style == "footnote" then
        return "footnote"
    end
    return "inline"
end

local function setNoteStyle(style)
    if style == "footnote" then
        setSetting("note_style", "footnote")
    else
        setSetting("note_style", nil)
    end
end

local function sanitizeCoversFolder(name)
    if type(name) ~= "string" then
        return DEFAULT_COVERS_FOLDER
    end
    local trimmed = name:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^[/\\]+", ""):gsub("[/\\]+$", "")
    if trimmed == "" then
        return DEFAULT_COVERS_FOLDER
    end
    local safe = util.getSafeFilename(trimmed, nil, nil, -1) or ""
    safe = safe:gsub("^%s+", ""):gsub("%s+$", "")
    if safe == "" or safe == "." or safe == ".." then
        return DEFAULT_COVERS_FOLDER
    end
    return safe
end

local function getCoversFolder()
    local folder = getSetting("covers_folder", DEFAULT_COVERS_FOLDER)
    return sanitizeCoversFolder(folder)
end

local function setCoversFolder(folder)
    local clean = sanitizeCoversFolder(folder)
    if clean == DEFAULT_COVERS_FOLDER then
        setSetting("covers_folder", nil)
    else
        setSetting("covers_folder", clean)
    end
end

local function readIfExists(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local data = f:read("*a")
    f:close()
    return data
end

-- whether the file to replace is byte for byte what the last export
-- wrote: nothing of the reader's sits in it, the next run rebuilds it
-- anyway, so there is no point in a copy of it (and no point in letting
-- it take the slot of a copy worth keeping). A record from before this
-- was remembered answers false, which keeps the backup.
local function ownCopy(stored, content)
    return stored ~= nil and stored == md5(content)
end

-- A file with a write zone carries this marker in its comments.
local ZONE_MARK = "tomedown:begin"

local function isZoned(text)
    return type(text) == "string" and text:find(ZONE_MARK, 1, true) ~= nil
end

-- writes `content` to `path` through a temporary file and a rename, so
-- the file that is already there is either replaced whole or left
-- exactly as it was: never truncated halfway. rename() replaces its
-- target in one step (KOReader runs on POSIX systems). Should a
-- filesystem refuse the rename, the copy is complete in the temporary
-- file by then and is written in place instead, with a warning in the
-- log: a quirk of the card must not stop the export for good. Returns
-- whether `path` holds `content` when the call ends.
local function replaceFile(path, content)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then
        return false
    end
    local written = f:write(content)
    f:close()
    if not written then
        os.remove(tmp)
        return false
    end
    if os.rename(tmp, path) then
        return true
    end
    logger.warn("tomedown: rename refused for", path, "- writing it in place")
    local direct = io.open(path, "wb")
    local ok = direct and direct:write(content)
    if direct then
        direct:close()
    end
    os.remove(tmp)
    return ok ~= nil and ok ~= false
end

-- The two copies that can sit beside an exported file, each with ONE
-- job, so that turning preserve on and off any number of times finds
-- the reader's notes where they were left:
--
--   <n>.md.bak    the parked file: the zoned file as it was when
--                 preserve went off. It is the reader's file, kept
--                 aside while the plain export takes its place, and it
--                 comes back into the file when preserve is on again.
--                 There is only this one and it is always the latest:
--                 whatever it held was folded back into the file when
--                 it came back, so parking the next version over it
--                 loses nothing (a note deleted in between stays
--                 deleted, a note added in between is in the new copy).
--
--   <n>.md.bak.1  a safety copy: text of the reader's that the rewrite
--                 is about to replace and that does NOT come back by
--                 itself (a plain file edited by hand while preserve
--                 was off, a block edited inside its comments, a cloud
--                 copy that moved on). One slot, overwritten by the
--                 next one; it never takes the place of the parked file.

-- The beta.1 rotated every copy from .bak into .bak.1, so on a card
-- that has run it the file with the notes can sit in .bak.1 behind a
-- newer copy without a zone. The slots now have fixed jobs: when .bak
-- holds no zone and .bak.1 does, the two trade places (once: afterwards
-- .bak is the zoned one and the swap no longer applies). Three renames,
-- undone if one of them is refused, so nothing is ever lost halfway.
local function normalizeBackups(path)
    local bak, bak1, tmp = path .. ".bak", path .. ".bak.1", path .. ".bak.swap"
    -- a swap cut short between its renames: the copy waiting in .bak.swap
    -- goes back to the slot it came from, so the swap below sees both
    local waiting = readIfExists(tmp)
    if waiting then
        if not readIfExists(bak) then
            os.rename(tmp, bak)
        elseif not readIfExists(bak1) then
            os.rename(tmp, bak1)
        elseif waiting == readIfExists(bak) or waiting == readIfExists(bak1) then
            -- a duplicate left by a swap that did finish: no information
            -- in it, the slot already has the same bytes
            os.remove(tmp)
        else
            logger.warn("tomedown: a temporary copy is left beside", path,
                "(.bak.swap), both slots are taken")
        end
    end
    local first, second = readIfExists(bak), readIfExists(bak1)
    if not first or not second or isZoned(first) or not isZoned(second) then
        return
    end
    if not os.rename(bak, tmp) then
        return
    end
    if not os.rename(bak1, bak) then
        os.rename(tmp, bak)
        return
    end
    if not os.rename(tmp, bak1) then
        -- .bak.1 is gone from its place and the old .bak waits in tmp:
        -- put the notes copy back where it was and the other beside it
        os.rename(bak, bak1)
        os.rename(tmp, bak)
        return
    end
    logger.info("tomedown: swapped the slots of", path, "(beta.1 layout)")
end

-- Parks the zoned file `content` in .bak. Returns whether the copy is
-- there when the call ends. An older .bak that holds no zone (written
-- before this rule) is moved to .bak.1 first rather than overwritten.
local function parkZone(path, content)
    local bak_path = path .. ".bak"
    local current = readIfExists(bak_path)
    if current == content then
        return true
    end
    if current and not isZoned(current)
            and readIfExists(bak_path .. ".1") ~= current
            and not replaceFile(bak_path .. ".1", current) then
        return false
    end
    return replaceFile(bak_path, content)
end

local BACKUP_SLOTS = { ".bak", ".bak.1", ".bak.2", ".bak.3" }

-- Keeps `content` as the safety copy (.bak.1), unless the same bytes
-- are already kept in any slot. An existing .bak.1 is rotated back to
-- .bak.2 (and .bak.2 to .bak.3) first so consecutive rewrites never
-- bury an earlier safety copy. Returns whether the copy is there.
local function keepSafety(path, content)
    for __, slot in ipairs(BACKUP_SLOTS) do
        if readIfExists(path .. slot) == content then
            return true
        end
    end
    local had1 = readIfExists(path .. ".bak.1") ~= nil
    local had2 = had1 and readIfExists(path .. ".bak.2") ~= nil
    if had2 then
        os.rename(path .. ".bak.2", path .. ".bak.3")
    end
    if had1 then
        os.rename(path .. ".bak.1", path .. ".bak.2")
    end
    if replaceFile(path .. ".bak.1", content) then
        return true
    end
    if had1 then
        os.rename(path .. ".bak.2", path .. ".bak.1")
    end
    if had2 then
        os.rename(path .. ".bak.3", path .. ".bak.2")
    end
    return false
end

-- Frontmatter customization: optional keys that can be hidden, and key
-- ordering. `tomedown` is the format stamp and can never be hidden or
-- moved away from the top of the front matter.
local FRONTMATTER_HIDEABLE_KEYS = {
    "cover", "series", "language", "pages", "exported",
    "highlights", "special", "status", "progress",
}

local DEFAULT_FRONTMATTER_ORDER = {
    "title", "author", "cover", "series", "series_index",
    "language", "pages", "exported", "highlights", "special",
    "status", "progress",
    "published", "rating", "review", "date_started", "date_finished",
    "collections", "tags",
}

local VALID_HIDEABLE_KEY = {}
for __, k in ipairs(FRONTMATTER_HIDEABLE_KEYS) do
    VALID_HIDEABLE_KEY[k] = true
end

local VALID_ORDER_KEY = {}
for __, k in ipairs(DEFAULT_FRONTMATTER_ORDER) do
    VALID_ORDER_KEY[k] = true
end

local function getFrontmatterHidden()
    local raw = getSetting("fm_hidden", nil)
    if type(raw) ~= "table" then
        return nil
    end
    local out = {}
    local any = false
    for k, v in pairs(raw) do
        if v == true and k ~= "tomedown" and VALID_HIDEABLE_KEY[k] then
            out[k] = true
            any = true
        end
    end
    return any and out or nil
end

local function isFrontmatterKeyEnabled(key)
    if key == "tomedown" or not VALID_HIDEABLE_KEY[key] then
        return true
    end
    local hidden = getSetting("fm_hidden", nil)
    return not (type(hidden) == "table" and hidden[key] == true)
end

local function setFrontmatterKeyEnabled(key, enabled)
    if key == "tomedown" or not VALID_HIDEABLE_KEY[key] then
        return
    end
    local current = getSetting("fm_hidden", nil)
    local next_map = {}
    if type(current) == "table" then
        for k, v in pairs(current) do
            if v == true and k ~= "tomedown" and VALID_HIDEABLE_KEY[k] then
                next_map[k] = true
            end
        end
    end
    if enabled then
        next_map[key] = nil
    else
        next_map[key] = true
    end
    setSetting("fm_hidden", next(next_map) and next_map or nil)
end

local function sanitizeFrontmatterOrder(raw)
    local tokens = {}
    if type(raw) == "string" then
        for tok in raw:gmatch("[%w_]+") do
            tokens[#tokens + 1] = tok:lower()
        end
    elseif type(raw) == "table" then
        for __, tok in ipairs(raw) do
            if type(tok) == "string" then
                tokens[#tokens + 1] = tok:lower():gsub("^%s+", ""):gsub("%s+$", "")
            end
        end
    end
    local out, seen = {}, {}
    for __, k in ipairs(tokens) do
        if k ~= "tomedown" and VALID_ORDER_KEY[k] and not seen[k] then
            seen[k] = true
            out[#out + 1] = k
        end
    end
    return #out > 0 and out or nil
end

local function getFrontmatterOrder()
    return sanitizeFrontmatterOrder(getSetting("fm_order", nil))
end

local function setFrontmatterOrder(raw)
    local clean = sanitizeFrontmatterOrder(raw)
    setSetting("fm_order", clean)
    return clean
end

local function getFrontmatterEnabled(file)
    if file then
        local override = getBookStyleOverride(file, "fm_enabled")
        if override ~= nil then
            return override == true
        end
    end
    return getSetting("fm_enabled", true) ~= false
end

local function setFrontmatterEnabled(enabled)
    if enabled == false then
        setSetting("fm_enabled", false)
    else
        setSetting("fm_enabled", nil)
    end
end

local function getBookCovers(file)
    if file then
        local override = getBookStyleOverride(file, "covers")
        if override ~= nil then
            return override == true
        end
    end
    return getSetting("covers", false) == true
end

local function getIncludeBookmarks(file)
    if file then
        local override = getBookStyleOverride(file, "include_bookmarks")
        if override ~= nil then
            return override == true
        end
    end
    return getSetting("include_bookmarks", false) == true
end

local function getHighlightDetails(file)
    local override = file and getBookStyleOverride(file, "highlight_details")
    local mode = override or getSetting("highlight_details", "page_date")
    if mode == "page_only" or mode == "date_only" or mode == "none" then
        return mode
    end
    return "page_date"
end

local function setHighlightDetails(mode)
    if mode == "page_only" or mode == "date_only" or mode == "none" then
        setSetting("highlight_details", mode)
    else
        setSetting("highlight_details", nil)
    end
end

local function getChapterHeadings(file)
    local override = file and getBookStyleOverride(file, "chapter_headings")
    local level = override or getSetting("chapter_headings", "h1")
    if level == "h2" or level == "h3" or level == "none" then
        return level
    end
    return "h1"
end

local function setChapterHeadings(level)
    if level == "h2" or level == "h3" or level == "none" then
        setSetting("chapter_headings", level)
    else
        setSetting("chapter_headings", nil)
    end
end

local function getHighlightContext(file)
    if file then
        local override = getBookStyleOverride(file, "highlight_context")
        if override ~= nil then
            return override == true
        end
    end
    return getSetting("highlight_context", false) == true
end

local function setHighlightContext(enabled)
    if enabled then
        setSetting("highlight_context", true)
    else
        setSetting("highlight_context", nil)
    end
end

local function getExportFormat(file)
    local override = file and getBookStyleOverride(file, "export_format")
    local fmt = override or getSetting("export_format", "md")
    if fmt == "txt" or fmt == "both" then
        return fmt
    end
    return "md"
end

local function setExportFormat(fmt)
    if fmt == "txt" or fmt == "both" then
        setSetting("export_format", fmt)
    else
        setSetting("export_format", nil)
    end
end

local function getTopbarIcon()
    return getSetting("topbar_icon", false) == true
end

local function setTopbarIcon(on)
    setSetting("topbar_icon", on and true or nil)
end


return {
    SETTINGS_KEY = SETTINGS_KEY,
    DEFAULT_LOCAL_SUBDIR = DEFAULT_LOCAL_SUBDIR,
    DEFAULT_COVERS_FOLDER = DEFAULT_COVERS_FOLDER,
    sanitizeCoversFolder = sanitizeCoversFolder,
    getCoversFolder = getCoversFolder,
    setCoversFolder = setCoversFolder,
    FRONTMATTER_HIDEABLE_KEYS = FRONTMATTER_HIDEABLE_KEYS,
    DEFAULT_FRONTMATTER_ORDER = DEFAULT_FRONTMATTER_ORDER,
    getFrontmatterHidden = getFrontmatterHidden,
    isFrontmatterKeyEnabled = isFrontmatterKeyEnabled,
    setFrontmatterKeyEnabled = setFrontmatterKeyEnabled,
    sanitizeFrontmatterOrder = sanitizeFrontmatterOrder,
    getFrontmatterOrder = getFrontmatterOrder,
    setFrontmatterOrder = setFrontmatterOrder,
    getFrontmatterEnabled = getFrontmatterEnabled,
    setFrontmatterEnabled = setFrontmatterEnabled,
    getBookCovers = getBookCovers,
    getIncludeBookmarks = getIncludeBookmarks,
    getHighlightDetails = getHighlightDetails,
    setHighlightDetails = setHighlightDetails,
    getChapterHeadings = getChapterHeadings,
    setChapterHeadings = setChapterHeadings,
    getHighlightContext = getHighlightContext,
    setHighlightContext = setHighlightContext,
    getExportFormat = getExportFormat,
    setExportFormat = setExportFormat,
    getTopbarIcon = getTopbarIcon,
    setTopbarIcon = setTopbarIcon,
    getBookStyleOverride = getBookStyleOverride,
    setBookStyleOverride = setBookStyleOverride,
    hasBookStyleOverrides = hasBookStyleOverrides,
    clearBookStyleOverrides = clearBookStyleOverrides,
    BACKUP_SLOTS = BACKUP_SLOTS,
    INDEX_FILENAME = INDEX_FILENAME,
    DIGEST_FILENAME = DIGEST_FILENAME,
    FILENAME_TEMPLATE = FILENAME_TEMPLATE,
    getSetting = getSetting,
    setSetting = setSetting,
    getNotesTitle = getNotesTitle,
    setBookNotesTitle = setBookNotesTitle,
    getBookPreserve = getBookPreserve,
    setBookPreserve = setBookPreserve,
    getBookTags = getBookTags,
    setBookTags = setBookTags,
    clearBookTags = clearBookTags,
    getBookImported = getBookImported,
    setBookImported = setBookImported,
    getAutoBookInfo = getAutoBookInfo,
    setAutoBookInfo = setAutoBookInfo,
    getBookOverride = getBookOverride,
    setBookOverride = setBookOverride,
    clearBookOverrides = clearBookOverrides,
    getBookInfoSnapshot = getBookInfoSnapshot,
    setBookInfoSnapshot = setBookInfoSnapshot,
    clearBookInfoSnapshot = clearBookInfoSnapshot,
    getBookInfoRemoval = getBookInfoRemoval,
    setBookInfoRemoval = setBookInfoRemoval,
    getBookExclusion = getBookExclusion,
    setBookExclusion = setBookExclusion,
    getKnownTags = getKnownTags,
    mergeKnownTags = mergeKnownTags,
    forgetKnownTag = forgetKnownTag,
    allowKnownTag = allowKnownTag,
    getIndexPreserve = getIndexPreserve,
    getFilenameTemplate = getFilenameTemplate,
    setFilenameTemplate = setFilenameTemplate,
    getFolderLayout = getFolderLayout,
    setFolderLayout = setFolderLayout,
    getIndexLinks = getIndexLinks,
    setIndexLinks = setIndexLinks,
    getNoteStyle = getNoteStyle,
    setNoteStyle = setNoteStyle,
    readIfExists = readIfExists,
    ownCopy = ownCopy,
    isZoned = isZoned,
    replaceFile = replaceFile,
    normalizeBackups = normalizeBackups,
    parkZone = parkZone,
    keepSafety = keepSafety,
}
