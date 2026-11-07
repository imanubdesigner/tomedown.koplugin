--[[
Book information imported into the Markdown note.

KOReader already holds most of what a reader wants in the frontmatter:
the rating and review in the sidecar's summary, the reading dates in the
summary and in the statistics database, the collections in
collection.lua, the publication date inside the book file and the
keywords shared with Bookshelf in the custom metadata.

None of it is read unless the reader imported that one book from its
menu. The import flag is what keeps a normal export byte-identical to
1.2.0: without it this module is never asked, the frontmatter keys are
not owned by the merger and the automatic updates never run.

This module is the only place that knows how to read and write those
sources. The exporters use collect(); the menus use the editors; the
DocSettings and ReadCollection hooks use snapshot()/changed() to decide
whether an imported book has to be written again.
]]

local BookInfo = require("apps/filemanager/filemanagerbookinfo")
local BookList = require("ui/widget/booklist")
local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local render = require("tomedown_render")
local pubdate = require("tomedown_pubdate")
local shared = require("tomedown_shared")

local M = {}

local SEP = "\31"
local AUTO_DELAY = 2

-- ------------------------------------------------------------------ basics

local function docSettings(file)
    if not file then
        return nil
    end
    local ok, ds = pcall(BookList.getDocSettings, file)
    if ok and ds then
        return ds
    end
    return nil
end

local function readSetting(ds, key)
    if not ds then
        return nil
    end
    local ok, value = pcall(ds.readSetting, ds, key)
    return ok and value or nil
end

--- The sidecar's summary table, or an empty table.
function M.summary(file)
    local summary = readSetting(docSettings(file), "summary")
    return type(summary) == "table" and summary or {}
end

local function trim(s)
    if type(s) ~= "string" then
        return nil
    end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s ~= "" and s or nil
end

--- The effective keywords of a book, as one comma separated string.
-- `props` may carry them already (buildBook has the extended props in
-- hand); otherwise they are read from the sidecar and overlaid the same
-- way KOReader and Bookshelf do, so the custom override always wins,
-- including an empty string that clears the file's own keywords.
function M.keywordsText(file, props)
    if props and props.keywords ~= nil then
        local value = props.keywords
        if type(value) == "table" then
            return table.concat(value, ", ")
        end
        return tostring(value)
    end
    local ds = docSettings(file)
    local doc_props = readSetting(ds, "doc_props") or {}
    local ok, extended = pcall(BookInfo.extendProps, doc_props, file)
    local value = ok and extended and extended.keywords or doc_props.keywords
    if type(value) == "table" then
        return table.concat(value, ", ")
    end
    return type(value) == "string" and value or ""
end

--- The effective tags of a book (sanitized, deduplicated, original
-- spelling kept). Used by the tag editor for an imported book and by
-- the export, which replaces the Tomedown-only list with this shared
-- one once the book is imported.
function M.tags(file, props)
    local tags = render.parseTagList(M.keywordsText(file, props))
    return tags
end

--- Write the shared keyword list. An empty list writes an empty string:
-- KOReader and Bookshelf read that as "no keywords", not as "fall back
-- to the file's own", which is what makes a removal stick.
function M.writeKeywords(file, tags)
    if not file then
        return false
    end
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not (ok_ds and DocSettings) then
        return false
    end
    local ok, result = pcall(function()
        local cmf = DocSettings:findCustomMetadataFile(file)
        local cds
        if cmf then
            cds = DocSettings.openSettingsFile(cmf)
        else
            cds = DocSettings.openSettingsFile()
            -- KOReader expects a copy of the original doc props in a new
            -- custom metadata file, so a never-opened book still resolves
            -- its title, authors and so on.
            local props = readSetting(docSettings(file), "doc_props") or {}
            cds:saveSetting("doc_props", props)
        end
        local custom = cds:readSetting("custom_props", {})
        if type(custom) ~= "table" then
            custom = {}
        end
        custom.keywords = table.concat(tags or {}, ", ")
        return cds:flushCustomMetadata(file)
    end)
    if not ok or not result then
        logger.warn("tomedown: cannot write the keywords of", file, result)
        return false
    end
    -- KOReader keeps the extracted props in a cache: tell it the file's
    -- metadata moved on so Show info and every book list refresh.
    local ok_event, Event = pcall(require, "ui/event")
    if ok_event and Event then
        pcall(function()
            UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", file))
            UIManager:broadcastEvent(Event:new("BookMetadataChanged",
                { filepath = file }))
        end)
    end
    return true
end

-- ------------------------------------------------------------- collections

local function collectionPath()
    return DataStorage:getSettingsDir() .. "/collection.lua"
end

--- Every collection, as a map from book file to the sorted collection
-- names. The collection file is read once for the whole library: the
-- automatic-update hook asks for every imported book on each write.
function M.collectionMap()
    local map = {}
    local ok_req, LuaSettings = pcall(require, "luasettings")
    if not (ok_req and LuaSettings) then
        return map
    end
    local ok = pcall(function()
        local settings = LuaSettings:open(collectionPath())
        for name, collection in pairs(settings.data or {}) do
            if type(collection) == "table" then
                for __, item in ipairs(collection) do
                    local item_file = type(item) == "table" and item.file or nil
                    if item_file then
                        local keys = { item_file }
                        local real = ffiUtil.realpath(item_file)
                        if real and real ~= item_file then
                            keys[#keys + 1] = real
                        end
                        for ___, key in ipairs(keys) do
                            local names = map[key]
                            if not names then
                                names = {}
                                map[key] = names
                            end
                            local found = false
                            for ____, existing in ipairs(names) do
                                if existing == tostring(name) then
                                    found = true
                                    break
                                end
                            end
                            if not found then
                                names[#names + 1] = tostring(name)
                            end
                        end
                    end
                end
            end
        end
    end)
    if not ok then
        return {}
    end
    for __, names in pairs(map) do
        table.sort(names)
    end
    return map
end

--- Every collection the book belongs to, sorted. `favorites` is a
-- collection like the others when the book is in it. A missing or
-- unreadable file simply means no collections.
function M.collections(file)
    if not file then
        return {}
    end
    local map = M.collectionMap()
    return map[file] or map[ffiUtil.realpath(file) or file] or {}
end

-- -------------------------------------------------------------- statistics

--- The first instant the statistics plugin recorded `file`, as
-- "YYYY-MM-DD", or nil when the plugin is absent, has no database or
-- never saw this book. The book is matched by partial_md5_checksum, the
-- same checksum the statistics plugin stores in its book table.
function M.dateStarted(file)
    local checksum = readSetting(docSettings(file), "partial_md5_checksum")
    if type(checksum) ~= "string" or not checksum:match("^[%w]+$") then
        return nil
    end
    local db = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if lfs.attributes(db, "mode") ~= "file" then
        return nil
    end
    local ok_req, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not (ok_req and SQ3) then
        return nil
    end
    local ok, date = pcall(function()
        local conn = SQ3.open(db)
        local id = conn:rowexec(string.format(
            "SELECT id FROM book WHERE md5 = '%s' ORDER BY id DESC LIMIT 1;",
            checksum))
        if not id then
            conn:close()
            return nil
        end
        local first = conn:rowexec(string.format(
            "SELECT min(start_time) FROM page_stat_data WHERE id_book = %d;",
            tonumber(id)))
        conn:close()
        first = tonumber(first)
        if first and first > 0 then
            return os.date("%Y-%m-%d", first)
        end
        return nil
    end)
    return ok and date or nil
end

-- ------------------------------------------------------------ publication

--- The publication date written in the book file, or nil. Cached by
-- path, modification time and size in tomedown_pubdate.
function M.publishedDate(file)
    if not file then
        return nil
    end
    return pubdate.read(file)
end

-- ------------------------------------------------------------ the fields

local function ratingValue(summary)
    local rating = tonumber(summary.rating)
    if rating and rating >= 1 and rating <= 5 then
        return math.floor(rating + 0.5)
    end
    return nil
end

local function reviewValue(summary)
    local note = trim(summary.note)
    if not note then
        return nil
    end
    -- one line in 1.3.0: a block scalar is reserved for 1.4.0, so the
    -- paragraphs are folded and the YAML stays a plain string
    note = note:gsub("%s*\n%s*", " ")
    note = note:gsub("%s+", " ")
    return trim(note)
end

--- The date a field would get without an override.
function M.autoDate(file, field, status)
    if field == "published" then
        return M.publishedDate(file)
    elseif field == "date_started" then
        return M.dateStarted(file)
    elseif field == "date_finished" then
        local modified = M.summary(file).modified
        if status == "complete" and type(modified) == "string"
                and modified ~= "" then
            return modified
        end
    end
    return nil
end

--- The date the note would carry now: the reader's override first,
-- then the automatic answer.
function M.effectiveDate(file, field, status)
    return shared.getBookOverride(file, field)
        or M.autoDate(file, field, status)
end

--- The frontmatter fields for an imported book.
-- `status` is the effective reading status the exporter already
-- resolved (nil, "reading", "abandoned", "complete"); `summary` may be
-- passed by a caller that read it already.
-- Each date checks the reader's override first. The automatic answers
-- are: published from the file, started from the statistics database,
-- finished from summary.modified (only while the book is complete).
function M.collect(file, status, summary, props)
    summary = summary or M.summary(file)
    local fields = {
        rating = ratingValue(summary),
        review = reviewValue(summary),
        published = M.effectiveDate(file, "published", status),
        date_started = M.effectiveDate(file, "date_started", status),
        date_finished = M.effectiveDate(file, "date_finished", status),
        collections = M.collections(file),
    }
    if type(fields.date_finished) ~= "string" or fields.date_finished == "" then
        fields.date_finished = nil
    end
    if #fields.collections == 0 then
        fields.collections = nil
    end
    return fields
end

-- ------------------------------------------------------------- snapshots

--- What the automatic update compares: the sidecar fields it can see
-- change and the shared sources that live outside it. Kept flat and
-- string-only so a settings round trip never changes its shape.
function M.snapshot(file)
    local summary = M.summary(file)
    local rating = summary.rating
    local note = summary.note
    return {
        rating = rating ~= nil and tostring(rating) or "",
        note = type(note) == "string" and note or "",
        status = type(summary.status) == "string" and summary.status or "",
        modified = type(summary.modified) == "string"
            and summary.modified or "",
        keywords = table.concat(M.tags(file), SEP),
        collections = table.concat(M.collections(file), SEP),
    }
end

local function sameSnapshot(a, b)
    if not (a and b) then
        return false
    end
    for _, key in ipairs({ "rating", "note", "status", "modified",
            "keywords", "collections" }) do
        if tostring(a[key] or "") ~= tostring(b[key] or "") then
            return false
        end
    end
    return true
end

--- Has the book's information moved on since the last export?
-- No stored snapshot means "not yet": the first export writes one, and
-- a book imported but never exported cannot have a file to update.
function M.changed(file)
    local stored = shared.getBookInfoSnapshot(file)
    if not stored then
        return false
    end
    return not sameSnapshot(stored, M.snapshot(file))
end

function M.saveSnapshot(file)
    if file then
        shared.setBookInfoSnapshot(file, M.snapshot(file))
    end
end

-- ----------------------------------------------------- import and removal

--- Mark one book as imported, migrating the tags chosen before 1.3.0
-- into the shared keyword list. Returns false when the file is not a
-- book KOReader has opened.
function M.import(file)
    if not file or not BookList.hasBookBeenOpened(file) then
        return false
    end
    if shared.getBookImported(file) then
        return true
    end
    local legacy = shared.getBookTags(file)
    if legacy then
        local tags, seen = {}, {}
        local function add(tag)
            tag = render.sanitizeTag(tag)
            if tag ~= "" and not seen[tag:lower()] then
                seen[tag:lower()] = true
                tags[#tags + 1] = tag
            end
        end
        for __, tag in ipairs(M.tags(file)) do
            add(tag)
        end
        for __, tag in ipairs(legacy or {}) do
            add(tag)
        end
        -- the migration must succeed before the old list is dropped: a
        -- failed write leaves the book exactly as it was, so nothing is
        -- lost and the import can be tried again
        if not M.writeKeywords(file, tags) then
            return false
        end
        shared.clearBookTags(file)
    end
    shared.setBookImported(file, true)
    shared.setBookInfoRemoval(file, false)
    M.saveSnapshot(file)
    return true
end

--- Stop managing one book. The caller removes the fields from the note
-- first, while the import flag is still on, so the merge deletes them;
-- only then does the flag go away. The tags stay, and become the book's
-- own chosen list, so editing them afterwards behaves like any other
-- book that chose its tags.
function M.forget(file)
    if not file then
        return
    end
    local tags = M.tags(file)
    shared.setBookImported(file, false)
    shared.setBookInfoRemoval(file, false)
    shared.clearBookOverrides(file)
    shared.clearBookInfoSnapshot(file)
    if #tags > 0 then
        shared.setBookTags(file, tags)
    else
        shared.clearBookTags(file)
    end
end

-- ------------------------------------------------------ automatic updates

local plugin
local scheduled = {}

local function schedule(file)
    if not file or scheduled[file] then
        return
    end
    if not plugin or not shared.getAutoBookInfo()
            or not shared.getBookImported(file) then
        return
    end
    scheduled[file] = true
    UIManager:scheduleIn(AUTO_DELAY, function()
        scheduled[file] = nil
        if not plugin or not shared.getAutoBookInfo()
                or not shared.getBookImported(file) then
            return
        end
        if not M.changed(file) then
            return
        end
        logger.info("tomedown: book info changed, exporting", file)
        plugin:runExport({ file }, { auto = "bookinfo" })
    end)
end

--- Install the write hooks once per process. They only observe: a hook
-- that fires for a book nobody imported, or with the feature off, does
-- nothing at all.
local function installHooks()
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if ok_ds and DocSettings and not DocSettings._tomedown_hooks then
        DocSettings._tomedown_hooks = true
        if type(DocSettings.flush) == "function" then
            local flush = DocSettings.flush
            DocSettings.flush = function(self, ...)
                local result = flush(self, ...)
                local path = self and self.data and self.data.doc_path
                if path and shared.getBookImported(path) then
                    schedule(path)
                end
                return result
            end
        end
        if type(DocSettings.flushCustomMetadata) == "function" then
            local flush_custom = DocSettings.flushCustomMetadata
            DocSettings.flushCustomMetadata = function(self, path, ...)
                local result = flush_custom(self, path, ...)
                if path and shared.getBookImported(path) then
                    schedule(path)
                end
                return result
            end
        end
    end
    local ok_rc, ReadCollection = pcall(require, "readcollection")
    if ok_rc and ReadCollection and not ReadCollection._tomedown_hooks then
        ReadCollection._tomedown_hooks = true
        if type(ReadCollection.write) == "function" then
            local write = ReadCollection.write
            ReadCollection.write = function(self, ...)
                local result = write(self, ...)
                local map = M.collectionMap()
                for file in pairs(shared.getSetting("bookinfo_imported", {})) do
                    local stored = shared.getBookInfoSnapshot(file)
                    if stored then
                        local names = map[file]
                            or map[ffiUtil.realpath(file) or file]
                            or {}
                        local now = table.concat(names, SEP)
                        if now ~= tostring(stored.collections or "") then
                            schedule(file)
                        end
                    end
                end
                return result
            end
        end
    end
end

--- Give the hooks the plugin that knows how to export. Called from
-- Tomedown:init(); the hooks themselves are installed once, however
-- many plugin instances come and go.
function M.attach(instance)
    plugin = instance
    installHooks()
end

--- Only for the tests: drop the scheduler state and the plugin.
function M.detach()
    plugin = nil
    scheduled = {}
end

return M
