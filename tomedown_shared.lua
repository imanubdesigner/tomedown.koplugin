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

local SETTINGS_KEY = "tomedown"
local DEFAULT_LOCAL_SUBDIR = "clipboard/tomedown"
local INDEX_FILENAME = "00 - Index.md"
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

-- Keeps `content` as the safety copy (.bak.1), unless the same bytes
-- are already kept in either slot. Returns whether the copy is there.
local function keepSafety(path, content)
    if readIfExists(path .. ".bak") == content
            or readIfExists(path .. ".bak.1") == content then
        return true
    end
    return replaceFile(path .. ".bak.1", content)
end


return {
    SETTINGS_KEY = SETTINGS_KEY,
    DEFAULT_LOCAL_SUBDIR = DEFAULT_LOCAL_SUBDIR,
    INDEX_FILENAME = INDEX_FILENAME,
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
    readIfExists = readIfExists,
    ownCopy = ownCopy,
    isZoned = isZoned,
    replaceFile = replaceFile,
    normalizeBackups = normalizeBackups,
    parkZone = parkZone,
    keepSafety = keepSafety,
}
