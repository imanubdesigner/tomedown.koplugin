--[[
tomedown.koplugin

Exports the highlights (and notes) of every book into a Markdown file
per book, with frontmatter and an automatic index, and uploads them to
a cloud (WebDAV, Dropbox, FTP) to read them later in Obsidian or in any
Markdown app.

Unlike "Export highlights and notes" (which produces a single combined
file), here every volume gets its own `.md`.
]]

local BookInfo = require("apps/filemanager/filemanagerbookinfo")
local BookList = require("ui/widget/booklist")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local time = require("ui/time")
local util = require("util")
local ffiUtil = require("ffi/util")
local md5 = require("ffi/sha2").md5
local json = require("json")
local readhistory = require("readhistory")
local lfs = require("libs/libkoreader-lfs")
local T = ffiUtil.template
local _ = require("tomedown_i18n")
local render = require("tomedown_render")
local merge = require("tomedown_merge")
local Cover = require("tomedown_cover")
local Update = require("tomedown_update")

local SETTINGS_KEY = "tomedown"
local DEFAULT_LOCAL_SUBDIR = "clipboard/tomedown"
local INDEX_FILENAME = "00 - Index.md"
local FILENAME_TEMPLATE = "%A - %T"

-- upload retry: up to 3 attempts, wait doubling
-- each time (2s, 4s), to absorb transient network blips without
-- having to trigger "Upload everything to the cloud" by hand.
local UPLOAD_MAX_ATTEMPTS = 3
local UPLOAD_RETRY_BASE_DELAY = 2 -- seconds

-- only transient failures are worth retrying: network errors (code
-- not a number), temporarily unavailable resources (5xx), timeouts and
-- too many requests from the server. 4xx (wrong credentials, missing
-- folder) fail on the first shot: retrying them only wastes time.
local function isTransient(code)
    if type(code) ~= "number" then
        return true
    end
    return code >= 500 or code == 408 or code == 429
end

local Tomedown = WidgetContainer:extend{
    name = "tomedown",
}

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

-- helpers

local function pageLabel(item)
    local p = item.pageref
    if type(p) == "table" then
        p = nil
    end
    if p == nil or p == "" then
        p = item.pageno
    end
    -- item.page is an xpointer, we use it only when it is a page number
    if p == nil or p == "" then
        if type(item.page) == "number" or tostring(item.page or ""):match("^%d+$") then
            p = item.page
        end
    end
    if p == nil or p == "" then
        return nil
    end
    return tostring(p)
end

local function trim(s)
    if type(s) ~= "string" then
        return nil
    end
    s = s:match("^%s*(.-)%s*$")
    if s == "" then
        return nil
    end
    return s
end

-- xpointer positions ("/body/DocFragment[16]/body/p[8]/text().0"):
-- split into text/number chunks so p[2] sorts before p[10]. The order
-- of the text never changes; pageno does with every layout change.
local function posTokens(s)
    local out = {}
    local i = 1
    while i <= #s do
        local d0, d1 = s:find("%d+", i)
        if not d0 then
            out[#out + 1] = { text = s:sub(i) }
            break
        end
        if d0 > i then
            out[#out + 1] = { text = s:sub(i, d0 - 1) }
        end
        out[#out + 1] = { num = tonumber(s:sub(d0, d1)) }
        i = d1 + 1
    end
    return out
end

local function posCompare(a, b)
    local n = math.min(#a, #b)
    for k = 1, n do
        local x, y = a[k], b[k]
        if x.num and y.num then
            if x.num ~= y.num then
                return x.num < y.num and -1 or 1
            end
        elseif x.num or y.num then
            return x.num and -1 or 1
        elseif x.text ~= y.text then
            return x.text < y.text and -1 or 1
        end
    end
    if #a == #b then
        return 0
    end
    return #a < #b and -1 or 1
end

function Tomedown:getLocalDir()
    local dir = getSetting("local_dir")
    if dir and dir ~= "" then
        return dir
    end
    return DataStorage:getFullDataDir() .. "/" .. DEFAULT_LOCAL_SUBDIR
end

function Tomedown:getRemoteFolder()
    local folder = getSetting("remote_folder")
    if folder and folder ~= "" then
        return folder
    end
    local server = self:getServer()
    return server and server.url or ""
end

-- Koofr server: first the one chosen in "Settings", then the fallback
-- already used by AnnotationSync, so whoever already set up Koofr on
-- KOReader does not have to set it up again.
function Tomedown:getServer()
    local server = getSetting("server")
    if server and server.type then
        return server
    end
    -- legacy key written by AnnotationSync (JSON string)
    local legacy = G_reader_settings:readSetting("cloud_server_object")
    if type(legacy) == "string" and legacy ~= "" then
        local ok, decoded = pcall(json.decode, legacy)
        if ok and type(decoded) == "table" and decoded.type and decoded.address then
            return decoded
        end
    end
    -- current AnnotationSync settings (the "sync_server" table)
    for __, key in ipairs({ "annotation_sync_plugin", "annotation_sync", "AnnotationSync" }) do
        local settings = G_reader_settings:readSetting(key)
        local sync_server = type(settings) == "table" and settings.sync_server or nil
        if type(sync_server) == "table" and sync_server.type and sync_server.address then
            return sync_server
        end
    end
    return nil
end

function Tomedown:hasServer()
    return self:getServer() ~= nil and (self.ui and self.ui.cloudstorage) ~= nil
end

function Tomedown:getCurrentFile()
    if self.ui and self.ui.document then
        return self.ui.document.file
    end
    return G_reader_settings:readSetting("lastfile")
end

function Tomedown:showProgress(text)
    local info = InfoMessage:new{ text = text }
    UIManager:show(info)
    UIManager:forceRePaint()
    return info
end

-- reading the annotations

-- when a book was last opened: the reading history carries the time of
-- every entry, newest first — the index shows it as "Last read", "—"
-- for a book the reader has not touched yet
local function lastReadTime(file)
    for __, item in ipairs(readhistory.hist) do
        if item.file == file and type(item.time) == "number" then
            return item.time
        end
    end
    return nil
end

function Tomedown:listBookFiles()
    local files = {}
    for __, item in ipairs(readhistory.hist) do
        if not item.dim and item.file and item.file ~= ""
            and BookList.hasBookBeenOpened(item.file) then
            files[#files + 1] = item.file
        end
    end
    return files
end

-- fallback for .sdr files written by old KOReader versions
-- (before annotations were saved in the "annotations" table)
function Tomedown:legacyAnnotations(ds)
    local highlights = ds:readSetting("highlight")
    if type(highlights) ~= "table" then
        return nil
    end
    local bookmarks = ds:readSetting("bookmarks")
    if type(bookmarks) ~= "table" then
        bookmarks = {}
    end
    local items = {}
    for page, list in pairs(highlights) do
        if type(list) == "table" then
            for __, hl in ipairs(list) do
                if type(hl) == "table" and hl.drawer then
                    local note
                    for __, bm in pairs(bookmarks) do
                        if type(bm) == "table" and bm.datetime == hl.datetime
                            and bm.text and bm.text ~= hl.text
                            and not bm.text:match("@ %d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$") then
                            note = bm.text
                            break
                        end
                    end
                    local pageno = tonumber(page)
                    items[#items + 1] = {
                        drawer = hl.drawer,
                        color = hl.color,
                        text = hl.text,
                        note = note,
                        chapter = hl.chapter,
                        datetime = hl.datetime,
                        datetime_updated = hl.datetime_updated,
                        pageno = pageno or 0,
                        pageref = pageno or page,
                        pos0 = type(hl.pos0) == "string" and hl.pos0 or nil,
                    }
                end
            end
        end
    end
    if #items == 0 then
        return nil
    end
    return items
end

-- keeps only the highlights (drawer), drops page bookmarks
-- and deleted entries, then sorts them by page
function Tomedown:cleanAnnotations(raw)
    local out = {}
    if type(raw) ~= "table" then
        return out
    end
    for __, item in ipairs(raw) do
        if type(item) == "table" and not item.deleted and item.drawer then
            local text = trim(item.text)
            if text then
                local datetime = item.datetime_updated or item.datetime
                local pos = type(item.pos0) == "string" and item.pos0 or nil
                if not pos and type(item.page) == "string"
                    and item.page:sub(1, 1) == "/" then
                    pos = item.page
                end
                out[#out + 1] = {
                    text = text,
                    note = trim(item.note),
                    chapter = trim(item.chapter),
                    page = pageLabel(item),
                    date = render.fmtDateTime(datetime),
                    sort_pos = pos and posTokens(pos) or nil,
                    sort_page = tonumber(item.pageno) or 0,
                    sort_time = tostring(datetime or ""),
                    special = item.tomedown_special or nil,
                    -- block ID seed: the CREATION time never changes (an
                    -- edited note or a resized highlight only moves
                    -- datetime_updated), so the ID outlives every edit
                    id_seed = item.datetime,
                    id_pos = pos,
                    id_text = text,
                }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.sort_pos and b.sort_pos then
            local d = posCompare(a.sort_pos, b.sort_pos)
            if d ~= 0 then
                return d < 0
            end
        end
        if a.sort_page ~= b.sort_page then
            return a.sort_page < b.sort_page
        end
        if a.sort_time ~= b.sort_time then
            return a.sort_time < b.sort_time
        end
        return a.text < b.text
    end)
    return out
end

-- keeps the page bookmarks (page, without pos0/pos1), drops deleted
-- entries and auto-generated notes, then sorts them by page
function Tomedown:cleanBookmarks(raw)
    local out = {}
    if type(raw) ~= "table" then
        return out
    end
    for __, item in ipairs(raw) do
        if type(item) == "table" and not item.deleted
            and item.page ~= nil and not (item.pos0 and item.pos1) then
            local note = trim(item.note) or trim(item.text)
            if note and note:match("^@ %d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$") then
                note = nil
            end
            local datetime = item.datetime_updated or item.datetime
            out[#out + 1] = {
                text = note,
                page = pageLabel(item),
                date = render.fmtDateTime(datetime),
                sort_page = tonumber(item.pageno) or 0,
                sort_time = tostring(datetime or ""),
            }
        end
    end
    table.sort(out, function(a, b)
        if a.sort_page ~= b.sort_page then
            return a.sort_page < b.sort_page
        end
        if a.sort_time ~= b.sort_time then
            return a.sort_time < b.sort_time
        end
        return tostring(a.text or "") < tostring(b.text or "")
    end)
    return out
end

-- keywords may be a string ("horror, gothic"), a table, or absent;
-- each keyword is normalised into a valid Obsidian tag (the sanitized
-- form is what both the hash and the exported frontmatter see)
local function parseKeywords(keywords)
    local out = {}
    local function add(v)
        if type(v) == "string" or type(v) == "number" then
            local s = render.sanitizeTag(tostring(v))
            if s ~= "" then
                out[#out + 1] = s
            end
        end
    end
    if type(keywords) == "table" then
        for __, v in ipairs(keywords) do
            add(v)
        end
    elseif type(keywords) == "string" then
        for part in keywords:gmatch("[^,\n]+") do
            add(part)
        end
    end
    local seen, deduped = {}, {}
    for __, s in ipairs(out) do
        local key = s:lower()
        if not seen[key] then
            seen[key] = true
            deduped[#deduped + 1] = s
        end
    end
    return deduped
end

local function hashBook(title, author, annotations, meta, bookmarks)
    local parts = {
        -- render format version: bumping it makes every stored hash stale,
        -- so the next export rewrites all the .md files with the new layout
        -- (render options stay out of here on purpose, see
        -- invalidateExportHashes)
        "fmt:8",
        "title:" .. tostring(title or ""),
        "author:" .. tostring(author or ""),
        "count:" .. tostring(#annotations),
    }
    if meta and meta ~= "" then
        parts[#parts + 1] = "meta:" .. meta
    end
    for __, a in ipairs(annotations) do
        parts[#parts + 1] = table.concat({
            tostring(a.sort_page or 0),
            tostring(a.sort_time or ""),
            tostring(a.page or ""),
            tostring(a.chapter or ""),
            a.text,
            tostring(a.note or ""),
            -- the Special Highlight mark changes the rendering, the hash
            -- must catch up with it
            tostring(a.special or ""),
        }, "\31")
    end
    for __, b in ipairs(bookmarks or {}) do
        parts[#parts + 1] = "bm:" .. table.concat({
            tostring(b.sort_page or 0),
            tostring(b.sort_time or ""),
            tostring(b.page or ""),
            tostring(b.text or ""),
        }, "\31")
    end
    return md5(table.concat(parts, "\n"))
end

-- file name identical to the standard exporter's ("%A - %T")
function Tomedown:fileBase(file, props)
    local name
    local bookinfo = self.ui and self.ui.bookinfo
    if bookinfo and bookinfo.expandString then
        local ok, result = pcall(bookinfo.expandString, bookinfo, FILENAME_TEMPLATE, file, os.time())
        if ok and type(result) == "string" and result ~= "" then
            name = result
        end
    end
    if not name then
        local title = props and props.display_title or file
        name = (props and props.authors or "N/A") .. " - " .. tostring(title)
    end
    name = name:gsub("\r?\n", "; ")
    return util.getSafeFilename(name, nil, nil, -1)
end

--- The vault-relative path of a book's cover, extracting the image the
-- first time it is needed. nil when "Include book covers" is off or the
-- book has no cover at all; the markdown then simply omits it.
function Tomedown:ensureCover(file, base, dir)
    if not getSetting("covers", false) then
        return nil
    end
    local rel = Cover.relPath(base)
    local document
    if self.ui and self.ui.document and self.ui.document.file == file then
        document = self.ui.document
    end
    if Cover.extract(document, file, dir .. "/" .. rel) then
        return rel
    end
    return nil
end

--- The reader UI when `file` is the book currently open, else nil.
-- While a book is open KOReader keeps its data (props, annotations,
-- progress) in memory and writes the .sdr only on close, on suspend or
-- with the periodic autosave: an export made mid-reading has to see what
-- the reader itself sees, or the series column of the index comes from a
-- flush older than the book (and the row lands in "My books").
function Tomedown:openReader(file)
    if self.ui and self.ui.document and self.ui.document.file == file then
        return self.ui
    end
    return nil
end

function Tomedown:buildBook(file, live_annotations)
    if self.book_cache and self.book_cache[file] ~= nil then
        return self.book_cache[file]
    end

    local book
    if BookList.hasBookBeenOpened(file) then
        local open = self:openReader(file)
        local ds = BookList.getDocSettings(file)
        if ds then
            local raw = live_annotations or ds:readSetting("annotations")
            if raw == nil then
                raw = self:legacyAnnotations(ds)
            end
            local annotations = self:cleanAnnotations(raw)
            local bookmarks = getSetting("include_bookmarks", false)
                and self:cleanBookmarks(raw) or {}
            if #annotations > 0 or #bookmarks > 0 then
                -- the open book's props are the ones KOReader read from
                -- the file; the .sdr copy is the last flush and may not
                -- know the series yet
                local doc_props = (open and open.doc_props)
                    or ds:readSetting("doc_props")
                local props = BookInfo.extendProps(doc_props, file)
                local title = props.display_title or file
                local author = props.authors
                local base = self:fileBase(file, props)
                local info = BookList.getBookInfo(file)
                local status = info and info.status
                if status ~= "reading" and status ~= "abandoned" and status ~= "complete" then
                    status = nil
                end
                local progress = ds:readSetting("percent_finished")
                if type(progress) == "number" then
                    if progress > 1 then
                        progress = progress / 100
                    end
                    progress = math.floor(progress * 100 + 0.5) .. "%"
                else
                    progress = nil
                end
                -- when the book was last opened, from the reading
                -- history (there is no such key in the doc settings)
                local lr = lastReadTime(file)
                local last_read = lr and os.date("%Y-%m-%d", lr) or nil
                local pages = info and info.pages
                if type(pages) ~= "number" or pages <= 0 then
                    pages = nil
                end
                local series = props.series
                if type(series) ~= "string" or series == "" then
                    series = nil
                end
                local series_index = props.series_index
                if series_index ~= nil and tostring(series_index) == "" then
                    series_index = nil
                end
                local language = props.language
                if type(language) ~= "string" or language == "" then
                    language = nil
                end
                local keywords = parseKeywords(props.keywords)
                local meta = table.concat({
                    tostring(series or ""),
                    tostring(series_index or ""),
                    tostring(language or ""),
                    tostring(pages or ""),
                    tostring(status or ""),
                    tostring(progress or ""),
                    table.concat(keywords, "\31"),
                }, "\31")
                book = {
                    file = file,
                    title = title,
                    author = author,
                    base = base,
                    series = series,
                    series_index = series_index,
                    language = language,
                    pages = pages,
                    status = status,
                    progress = progress,
                    last_read = last_read,
                    keywords = keywords,
                    count = #annotations,
                    annotations = annotations,
                    bookmarks = bookmarks,
                    exported = os.date("%Y-%m-%d"),
                    hash = hashBook(title, author, annotations, meta, bookmarks),
                }
            end
        end
    end

    if self.book_cache then
        self.book_cache[file] = book
    end
    return book
end

function Tomedown:buildBooks(files)
    local books = {}
    for __, file in ipairs(files) do
        local open = self:openReader(file)
        local live = open and open.annotation and open.annotation.annotations
        local ok, book = pcall(self.buildBook, self, file, live)
        if ok then
            if book then
                books[#books + 1] = book
            end
        else
            logger.err("tomedown: cannot read annotations of", file, book)
        end
    end
    return books
end

-- index

function Tomedown:buildIndexEntries(dir, export_records)
    local entries = {}
    local new_covers = {}
    local with_covers = getSetting("covers", false)
    for __, file in ipairs(self:listBookFiles()) do
        -- same live data the export above writes into the book file:
        -- the .sdr still holds the previous flush while the book is open
        local open = self:openReader(file)
        local live = open and open.annotation and open.annotation.annotations
        local book = self:buildBook(file, live)
        if book and lfs.attributes(dir .. "/" .. book.base .. ".md") then
            local cover_rel = Cover.relPath(book.base)
            local has_cover = lfs.attributes(dir .. "/" .. cover_rel, "mode") == "file"
            if not has_cover and with_covers then
                -- backfill: books exported before the option was turned on
                has_cover = self:ensureCover(file, book.base, dir)
                if has_cover then
                    new_covers[#new_covers + 1] = dir .. "/" .. cover_rel
                end
            end
            local special = 0
            for __, a in ipairs(book.annotations or {}) do
                if a.special then
                    special = special + 1
                end
            end
            entries[#entries + 1] = {
                link = book.base,
                title = book.title,
                author = book.author,
                series = book.series,
                series_index = book.series_index,
                status = book.status,
                count = book.count,
                special = special,
                progress = book.progress,
                last_read = book.last_read and render.fmtDate(book.last_read)
                    or "",
                cover = has_cover and cover_rel or nil,
            }
        end
    end
    table.sort(entries, function(a, b)
        local author_a = tostring(a.author or ""):lower()
        local author_b = tostring(b.author or ""):lower()
        if author_a ~= author_b then
            return author_a < author_b
        end
        return tostring(a.title or ""):lower() < tostring(b.title or ""):lower()
    end)
    return entries, new_covers
end

-- upload to the cloud

function Tomedown:cloudProvider(server)
    local cloud = self.ui and self.ui.cloudstorage
    if not (cloud and server and server.type and cloud.providers) then
        return nil
    end
    return cloud.providers[server.type]
end

-- Where our uploads live, identified by server + folder: the hashes
-- below only make sense against the same destination.
local function cloudScope(server)
    local remote_folder = getSetting("remote_folder")
    return table.concat({
        server.type or "?",
        server.url or server.address or "?",
        remote_folder or "",
    }, "|")
end

--- What each file looked like the last time we uploaded it (nil when
-- this server/folder never saw an upload from us: a first export into
-- an existing cloud folder, an upgrade from tomedown 0.8).
function Tomedown:cloudBase(server)
    local store = getSetting("cloud_base")
    if not store or store.scope ~= cloudScope(server) then
        return nil
    end
    return store.files
end

--- Remember the content just uploaded for the local file `path`: the
-- next export compares it with the cloud copy to tell "still ours"
-- from "edited somewhere else in between".
function Tomedown:markUploaded(server, path, dir)
    local rel = path:sub(1, #dir + 1) == dir .. "/" and path:sub(#dir + 2)
    if not rel or rel:sub(-3) ~= ".md" then
        -- only the markdown is merged back: covers are pushed whole
        return
    end
    local content = readIfExists(path)
    if not content then
        return
    end
    local store = getSetting("cloud_base")
    local scope = cloudScope(server)
    if not store or store.scope ~= scope then
        store = { scope = scope, files = {} }
    end
    store.files[rel] = md5(content)
    setSetting("cloud_base", store)
end

--- The copy of the local file `path` currently in the cloud (nil when
-- there is none: nothing there, no download support, any failure — the
-- caller keeps the local file). One GET per file being exported, and
-- only while the reader has a connection.
--
-- The second return value names why there is no content, and only the
-- flush below cares: "unsupported" (this server cannot download, so a
-- push is the only move), "absent" (nothing there to lose), "failed"
-- (a transient error — the export keeps its local file, the flush
-- refuses to push over a copy it never got to see). nil means a copy
-- was returned.
function Tomedown:fetchRemote(server, path, dir)
    local provider = self:cloudProvider(server)
    if not (provider and provider.downloadFile) then
        return nil, "unsupported"
    end
    local srv = util.tableDeepCopy(server)
    local remote_folder = getSetting("remote_folder")
    if remote_folder and remote_folder ~= "" then
        srv.url = remote_folder
    end
    if not srv.url and srv.address then
        srv.url = srv.address
    end
    provider.base = srv
    local rel = path:sub(1, #dir + 1) == dir .. "/" and path:sub(#dir + 2)
        or ffiUtil.basename(path)
    local subdir = rel:match("^(.*)/[^/]+$")
    local url = srv.url or ""
    if subdir then
        url = (url:gsub("/+$", "")) .. "/" .. subdir
    end
    -- providers download to <url>/<basename>
    url = (url:gsub("/+$", "")) .. "/" .. ffiUtil.basename(path)
    local tmp = os.tmpname()
    local ok_call, ret = pcall(provider.downloadFile, url, tmp)
    local code = type(ret) == "number" and ret or nil
    local ok = ok_call and (ret == nil or code == nil
        or (code >= 200 and code < 300))
    if not ok then
        os.remove(tmp)
        if ok_call and code == 404 then
            return nil, "absent"
        end
        return nil, "failed"
    end
    local content = readIfExists(tmp)
    os.remove(tmp)
    if not content or content == "" then
        return nil, "absent"
    end
    return content
end

-- upload through the provider (webdav/dropbox/ftp) instead of via
-- Cloud:uploadFile, which does not exist in every KOReader version.
--
-- Each file is retried up to UPLOAD_MAX_ATTEMPTS times, with an
-- exponential backoff wait (UPLOAD_RETRY_BASE_DELAY * 2^(n-1))
-- between one attempt and the next, before being marked as a
-- permanent failure. It absorbs transient network blips (WiFi reconnecting,
-- slow DNS, etc.) without needing an "Upload everything
-- to the cloud" by hand every time.
function Tomedown:uploadPaths(server, paths, callback)
    local provider = self:cloudProvider(server)
    -- remembered for the Status panel; every upload path funnels here
    local function recordUpload(uploaded, errors)
        if #paths > 0 then
            logger.info(string.format("tomedown: upload done: ok=%d errors=%d",
                uploaded, errors))
            setSetting("last_upload", {
                at = os.time(),
                uploaded = uploaded,
                errors = errors,
            })
        end
    end
    if #paths > 0 then
        logger.info(string.format("tomedown: upload start: %d files -> %s",
            #paths, server.name or server.type or "?"))
    end
    if not (provider and provider.uploadFile and provider.run) then
        recordUpload(0, #paths)
        if callback then callback(0, #paths, paths) end
        return
    end
    local i, ok_count, fail_count, failed = 0, 0, 0, {}
    local dir = self:getLocalDir()
    local made_folders = {}

    local function attemptUpload(path, attempt, on_done)
        local srv = util.tableDeepCopy(server)
        local remote_folder = getSetting("remote_folder")
        if remote_folder and remote_folder ~= "" then
            srv.url = remote_folder
        end
        -- servers taken from AnnotationSync have "address", not "url"
        if not srv.url and srv.address then
            srv.url = srv.address
        end
        provider.base = srv
        -- KOReader's providers upload to <url>/<basename>, dropping any
        -- local subfolder: a cover in covers/ would land flattened in the
        -- remote root and the markdown would link to a folder that does
        -- not exist. The subfolder joins the url instead, and is created
        -- once per run before the first upload into it (an existing
        -- folder answers 405 to MKCOL: the result is ignored).
        local base_url = srv.url or ""
        local rel = path:sub(1, #dir + 1) == dir .. "/" and path:sub(#dir + 2) or nil
        local subdir = rel and rel:match("^(.*)/[^/]+$")
        local upload_url = base_url
        if subdir then
            upload_url = (base_url:gsub("/+$", "")) .. "/" .. subdir
        end
        provider.run(function()
            if subdir and provider.createFolder
                    and not made_folders[base_url .. "/" .. subdir] then
                made_folders[base_url .. "/" .. subdir] = true
                pcall(provider.createFolder, base_url, subdir)
            end
            local ok_call, code = pcall(provider.uploadFile, upload_url, path, nil, true)
            local success = ok_call and type(code) == "number" and code >= 200 and code < 300
            if success then
                -- remembered, so the next export can tell the cloud copy
                -- we wrote from one edited elsewhere in the meantime
                self:markUploaded(server, path, dir)
                on_done(true)
                return
            end
            if attempt < UPLOAD_MAX_ATTEMPTS and isTransient(code) then
                local delay = UPLOAD_RETRY_BASE_DELAY * (2 ^ (attempt - 1))
                logger.warn("tomedown: upload failed (attempt", attempt, "of", UPLOAD_MAX_ATTEMPTS,
                    "), retrying in", delay, "s:", path, tostring(code))
                UIManager:scheduleIn(delay, function()
                    attemptUpload(path, attempt + 1, on_done)
                end)
            else
                logger.warn("tomedown: upload failed after", attempt,
                    isTransient(code) and "attempts:" or "attempt (error not retryable):",
                    path, tostring(code))
                on_done(false)
            end
        end)
    end

    local function step()
        i = i + 1
        if i > #paths then
            recordUpload(ok_count, fail_count)
            if callback then callback(ok_count, fail_count, failed) end
            return
        end
        local path = paths[i]
        attemptUpload(path, 1, function(success)
            if success then
                ok_count = ok_count + 1
            else
                fail_count = fail_count + 1
                failed[#failed + 1] = path
            end
            UIManager:scheduleIn(0, step)
        end)
    end
    step()
end

-- export

-- files written locally but not yet in the cloud (offline export, upload
-- failure, export during suspend): remembered across restarts so that the
-- next connection can upload only those
function Tomedown:markPendingUploads(paths)
    local pending = getSetting("pending_uploads", {})
    local changed = false
    for __, path in ipairs(paths) do
        if not pending[path] then
            pending[path] = true
            changed = true
        end
    end
    if changed then
        setSetting("pending_uploads", pending)
        if G_reader_settings.flush then
            G_reader_settings:flush()
        end
    end
end

function Tomedown:clearPendingUploads(paths)
    local pending = getSetting("pending_uploads", {})
    local changed = false
    for __, path in ipairs(paths) do
        if pending[path] then
            pending[path] = nil
            changed = true
        end
    end
    if changed then
        setSetting("pending_uploads", pending)
    end
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

function Tomedown:runExport(files, opts)
    opts = opts or {}
    if opts.auto then
        -- close and suspend only export what changed since last time
        opts.only_updated = true
    end
    -- suspend: write locally and stay completely silent (no widgets, no
    -- network: the device is about to sleep)
    local silent = opts.auto == "suspend"
    self.book_cache = {}
    local t0 = time.now()

    local dir = self:getLocalDir()
    util.makePath(dir)
    local with_index = getSetting("with_index", true)

    local info
    if not silent and opts.auto ~= "close" then
        -- auto close: one book straight from the .sdr, the export is
        -- milliseconds - the widget would only flash one more e-ink
        -- refresh between the close and the result notification
        info = self:showProgress(opts.progress_text or _("Export in progress…"))
    end

    local export_records = getSetting("exports", {})
    local written, errors = {}, {}
    local skipped, exported = 0, 0
    -- manual edits: "preserve" merges the render into the file on disk
    -- (the reader's zones and front matter stay, the generated block is
    -- rebuilt), "overwrite" writes what was generated; a file whose
    -- block held hand edits is kept as .bak before it is rewritten.
    -- Off by default: tomedown ≤ 0.8 always overwrote every file, and
    -- an upgrade must not change that under the reader's feet. Since
    -- 1.1 every file may hold its own choice and its own heading, and
    -- both stay dormant while the global switch is on: with it on the
    -- switch alone governs every file and names every zone itself,
    -- with it off each file follows what it stored (books:
    -- getBookPreserve and getNotesTitle with the book's file, the
    -- index: getIndexPreserve and its own title)
    local index_title = getNotesTitle(INDEX_FILENAME)
    local backups = 0
    -- the copies in .bak / .bak.1 are what keeps the reader's text when a
    -- file is rewritten: when one cannot be written the file is left as
    -- it is and the export says so, rather than losing the text
    local hold_msg = _("the backup copy could not be written, file left as it is")

    -- a reader who edits the exported file somewhere else (Obsidian on
    -- the desktop, synced through the same cloud folder) must not lose
    -- that text: before the merge, the cloud copy is fetched and used
    -- as the base when it moved on from the last upload. Everything
    -- else (upload off, offline, silent suspend export, the option
    -- turned off) keeps the local file as the base, as before. Since
    -- 1.1 preserve is per book, so the fetch runs per file, only for
    -- the ones that keep a write zone (the `pull` flag below)
    local cloud_pull = getSetting("upload", false)
        and getSetting("cloud_merge", true) and not silent
        and NetworkMgr:isConnected()
    local pull_server = cloud_pull and self:getServer() or nil
    -- a cloud copy that could not be read during this run must not be
    -- pushed over: those files stay out of the upload below and are
    -- queued for the flush, which fetches them again and folds them in
    -- (or keeps them back) before anything goes up
    local unread = {}
    local function mergeBase(rel, md_path, local_old, pull)
        if not pull_server or not pull then
            return local_old
        end
        local remote, status = self:fetchRemote(pull_server, md_path, dir)
        if status == "failed" then
            logger.warn("tomedown:", rel,
                "(cloud copy not fetched, holding the upload back)")
            unread[md_path] = true
        end
        if not remote or remote == local_old then
            return local_old
        end
        local stored = self:cloudBase(pull_server)
        if stored and stored[rel] and md5(remote) == stored[rel] then
            -- still the copy we uploaded: ours is the newer file
            return local_old
        end
        logger.info("tomedown:", rel,
            "was edited elsewhere: folding the cloud copy into the merge")
        return remote
    end

    for __, file in ipairs(files) do
        local open = self:openReader(file)
        local live = open and open.annotation and open.annotation.annotations
        local ok, book = pcall(self.buildBook, self, file, live)
        if not ok then
            logger.err("tomedown: cannot read annotations of", file, book)
            errors[#errors + 1] = ffiUtil.basename(tostring(file))
        elseif book then
            local md_path = dir .. "/" .. book.base .. ".md"
            local record = export_records[file]
            -- what this book chose (or the global default): its file is
            -- folded or rewritten on its own, never on its neighbours'
            local preserve = getBookPreserve(file)
            local mode = preserve and "preserve" or "overwrite"
            if opts.only_updated and record and record.hash == book.hash
                and lfs.attributes(md_path) then
                skipped = skipped + 1
            else
                local cover_rel = self:ensureCover(file, book.base, dir)
                local md = render.buildBookMd(book, {
                    no_chapter_label = _("No chapter"),
                    cover = cover_rel,
                    callout = getSetting("callout", false),
                    block_ids = getSetting("block_ids", false),
                    special_marker = getSetting("special_marker", "callout"),
                    notes_title = getNotesTitle(file),
                    markers = preserve,
                })
                -- fold the file on disk into the render: the reader's
                -- zones and front matter come across, the block is rebuilt
                local content = md
                local old = mergeBase(book.base .. ".md", md_path,
                    readIfExists(md_path), preserve)
                -- Preserve coming back on brings the parked file back:
                -- the file on disk is plain (no zone) while the .bak
                -- holds the zoned file from the moment preserve went
                -- off, so that file is the base of this export and the
                -- reader's notes are in the file again. If the plain
                -- file is not the one this plugin wrote (the reader
                -- typed into it while preserve was off) its text cannot
                -- come across by itself: it is kept as the safety copy.
                local restored = false
                local hold
                normalizeBackups(md_path)
                if old and preserve and not isZoned(old) then
                    local snapshot = readIfExists(md_path .. ".bak")
                    if isZoned(snapshot) then
                        if not ownCopy(record and record.disk, old) then
                            if keepSafety(md_path, old) then
                                backups = backups + 1
                            else
                                hold = hold_msg
                            end
                        end
                        old = snapshot
                        restored = true
                    end
                end
                if old then
                    local merged, info = merge.apply(old, md,
                        record and record.regions,
                        { mode = mode, notes_title = getNotesTitle(file) })
                    content = merged
                    if restored then
                        -- the parked file stays in .bak as it is: it is
                        -- replaced only when preserve goes off again
                        -- with whatever the file holds by then
                    elseif info.backup
                            and not ownCopy(record and record.disk, old) then
                        -- the reader had written inside the block (or
                        -- the file has to be rebuilt from scratch): the
                        -- previous file is kept whole, as the safety
                        -- copy, before the rebuilt one replaces it
                        if keepSafety(md_path, old) then
                            backups = backups + 1
                        else
                            hold = hold_msg
                        end
                    elseif not preserve and isZoned(old) then
                        -- the book goes from zoned to plain, which is
                        -- what turning preserve off does: the file is
                        -- parked in .bak until preserve comes back
                        if parkZone(md_path, old) then
                            backups = backups + 1
                        else
                            hold = hold_msg
                        end
                    end
                end
                local written_ok, err
                if hold then
                    written_ok, err = false, hold
                else
                    written_ok, err =
                        util.writeToFile(content, md_path, true, false, true)
                end
                if written_ok then
                    exported = exported + 1
                    written[#written + 1] = md_path
                    if cover_rel then
                        written[#written + 1] = dir .. "/" .. cover_rel
                    end
                    export_records[file] = {
                        hash = book.hash,
                        base = book.base,
                        date = os.date("%Y-%m-%d"),
                        -- what we would have generated: the proof the
                        -- next export compares the regions against
                        regions = merge.fingerprints(merge.split(md)),
                        -- the file as it left our hands: proof that the
                        -- next run needs no copy of it (ownCopy above)
                        disk = md5(content),
                    }
                else
                    errors[#errors + 1] = book.base .. ": " .. tostring(err)
                end
            end
        end
    end
    local ms_books = time.to_ms(time.since(t0))
    local t1 = time.now()

    if with_index then
        local index_path = dir .. "/" .. INDEX_FILENAME
        if exported > 0 or not lfs.attributes(index_path) then
            -- the index keeps its zone when its own switch says so, or
            -- when the global switch covers it: no book choice turns it
            -- on behind the reader's back any more
            local index_preserve = getIndexPreserve()
            -- what the last export left in the file, to tell our own
            -- output from anything the reader wrote in it
            local index_disk = getSetting("index_disk")
            local entries, new_covers = self:buildIndexEntries(dir, export_records)
            local index_md = render.buildIndexMd(entries, {
                title = _("Book index"),
                exported = os.date("%Y-%m-%d"),
                show_covers = getSetting("covers", false),
                notes_title = index_title,
                markers = index_preserve,
            })
            -- the index is a region too: the reader may have annotated it
            local content = index_md
            local old_index = mergeBase(INDEX_FILENAME, index_path,
                readIfExists(index_path), index_preserve)
            -- the same road as the books: the index comes back from its
            -- parked file when preserve returns
            local restored_index = false
            local hold_index
            normalizeBackups(index_path)
            if old_index and index_preserve and not isZoned(old_index) then
                local snapshot = readIfExists(index_path .. ".bak")
                if isZoned(snapshot) then
                    if not ownCopy(index_disk, old_index) then
                        if keepSafety(index_path, old_index) then
                            backups = backups + 1
                        else
                            hold_index = hold_msg
                        end
                    end
                    old_index = snapshot
                    restored_index = true
                end
            end
            if old_index then
                local merged, info = merge.apply(old_index, index_md,
                    getSetting("index_regions"),
                    { mode = index_preserve and "preserve" or "overwrite",
                      notes_title = index_title })
                content = merged
                if restored_index then
                    -- the parked index stays in .bak as it is
                elseif info.backup
                        and not ownCopy(index_disk, old_index) then
                    if keepSafety(index_path, old_index) then
                        backups = backups + 1
                    else
                        hold_index = hold_msg
                    end
                elseif not index_preserve and isZoned(old_index) then
                    -- the index goes from zoned to plain: it is parked
                    -- in .bak until preserve comes back
                    if parkZone(index_path, old_index) then
                        backups = backups + 1
                    else
                        hold_index = hold_msg
                    end
                end
            end
            local index_ok, index_err
            if hold_index then
                index_ok, index_err = false, hold_index
            else
                index_ok, index_err =
                    util.writeToFile(content, index_path, true, false, true)
            end
            if index_ok then
                written[#written + 1] = index_path
                setSetting("index_regions",
                    merge.fingerprints(merge.split(index_md)))
                setSetting("index_disk", md5(content))
                -- covers pulled in by the backfill above join the upload
                for __, path in ipairs(new_covers) do
                    written[#written + 1] = path
                end
            else
                -- a silent failure here leaves the old index in place
                -- while the export reports success (a file held open by
                -- another app: Obsidian on Windows, an editor anywhere)
                errors[#errors + 1] = INDEX_FILENAME .. ": "
                    .. tostring(index_err)
            end
        end
    end
    local ms_index = time.to_ms(time.since(t1))

    setSetting("exports", export_records)
    -- remembered for the Status panel (also for silent suspend exports)
    setSetting("last_export", {
        at = os.time(),
        exported = exported,
        skipped = skipped,
        errors = #errors,
        backups = backups,
    })
    if info then
        UIManager:close(info)
    end
    local ms_total = time.to_ms(time.since(t0))
    logger.info(string.format(
        "tomedown: export done: exported=%d skipped=%d errors=%d"
        .. " books=%dms index=%dms rest=%dms total=%dms",
        exported, skipped, #errors, ms_books, ms_index,
        ms_total - ms_books - ms_index, ms_total))

    -- two separate results: the local export is reported right away,
    -- so a reader who never enables the cloud does not wait for an
    -- upload phase that does not exist for them
    local function reportExport(offline_pending)
        if silent then
            return
        end
        -- auto close of a book without new highlights: no message at all
        if opts.auto == "close" and exported == 0 and #errors == 0 then
            return
        end
        self:showResult(exported, skipped, errors, offline_pending,
            opts.auto, backups)
    end
    local function reportUpload(uploaded, upload_failed)
        if upload_failed > 0 then
            UIManager:show(InfoMessage:new{
                text = T(_("Cloud: %1 uploaded, %2 errors"), uploaded, upload_failed),
            })
            return
        end
        UIManager:show(Notification:new{
            text = T(_("Cloud: %1 files uploaded"), uploaded),
            timeout = 3,
        })
    end

    local server = self:getServer()
    local has_upload = getSetting("upload", false) and server and #written > 0
    local queued = has_upload and (silent or not NetworkMgr:isConnected())
    if queued then
        -- no network work now: queue for the next connection
        self:markPendingUploads(written)
    end
    reportExport(queued)

    if has_upload and not queued then
        -- a file whose cloud copy could not be read stays out of this
        -- push and is queued: the flush fetches it again and folds it
        -- in, instead of the export overwriting a copy it never saw
        local push, held = {}, {}
        for __, path in ipairs(written) do
            if unread[path] then
                held[#held + 1] = path
            else
                push[#push + 1] = path
            end
        end
        if #held > 0 then
            self:markPendingUploads(held)
        end
        if #push == 0 then
            -- every file was held back: say it out loud instead of
            -- looking like a clean export
            UIManager:show(InfoMessage:new{
                text = T(_("Cloud: %1 files kept back, will retry"), #held),
            })
            return
        end
        -- stays open for the whole upload phase, retries included
        -- with backoff: without this the screen stays silent for minutes
        local upload_info = self:showProgress(T(_("Uploading %1 files to the cloud…"), #push))
        self:uploadPaths(server, push, function(ok_count, fail_count, failed)
            UIManager:close(upload_info)
            if #failed > 0 then
                self:markPendingUploads(failed)
            end
            local failed_set = {}
            for __, path in ipairs(failed) do
                failed_set[path] = true
            end
            local ok_paths = {}
            for __, path in ipairs(push) do
                if not failed_set[path] then
                    ok_paths[#ok_paths + 1] = path
                end
            end
            self:clearPendingUploads(ok_paths)
            -- the vault copy is now the master one: drop the transferred
            -- covers from the device (the .md files stay local, they are
            -- the library this plugin reads its history from)
            if getSetting("covers", false) then
                Cover.deleteUploaded(ok_paths, dir)
            end
            reportUpload(ok_count, fail_count)
        end)
    end
end

-- What started an automatic export, for the notification prefix.
-- Manual runs stay unlabelled in the toast — the reader just tapped
-- the menu entry — but the error window, which stays on screen after
-- a background close, always names its trigger.
local function autoTriggerLabel(auto)
    if auto == "close" then
        return _("Closing")
    end
    return nil
end

--- The local outcome: a toast right after the export finishes, an
-- InfoMessage (stays on screen) when something went wrong. The cloud
-- reports separately, in reportUpload's own notification. `auto` is
-- opts.auto of the run: automatic toasts carry their trigger, manual
-- ones do not; the error window is always labelled. `backups` counts
-- the files kept as .bak because the reader had written inside their
-- generated block.
function Tomedown:showResult(exported, skipped, errors, offline_pending,
        auto, backups)
    local lines = {}
    if exported > 0 then
        if offline_pending then
            lines[#lines + 1] = T(_("%1 files exported — upload when online"), exported)
        else
            lines[#lines + 1] = T(_("%1 files exported locally"), exported)
        end
    else
        lines[#lines + 1] = _("No files exported")
    end
    if skipped > 0 then
        lines[#lines + 1] = T(_("%1 files unchanged, skipped"), skipped)
    end
    if backups and backups > 0 then
        lines[#lines + 1] = T(_("%1 files backed up (.bak)"), backups)
    end
    if #errors > 0 then
        lines[#lines + 1] = _("Errors:") .. "\n" .. table.concat(errors, "\n")
        local trigger = autoTriggerLabel(auto) or _("Manual")
        UIManager:show(InfoMessage:new{
            text = trigger .. " · " .. table.concat(lines, "\n"),
        })
        return
    end
    local prefix = ""
    local auto_label = autoTriggerLabel(auto)
    if auto_label then
        prefix = auto_label .. " · "
    end
    UIManager:show(Notification:new{
        text = prefix .. table.concat(lines, " · "),
        timeout = 3,
    })
end

-- Status panel: the state that otherwise lives only in the toast
-- history — network, server, queued uploads and the outcome of the
-- last export/upload with their timestamps — on a single screen.
-- statusLines() is separated from showStatus() so the tests can read
-- the text without any widget.

function Tomedown:statusLines()
    local lines = {}
    lines[#lines + 1] = NetworkMgr:isConnected()
        and _("Network: connected")
        or _("Network: offline")
    local server = self:getServer()
    if server then
        local desc = server.name or server.type or "?"
        local folder = self:getRemoteFolder()
        if folder ~= "" then
            desc = desc .. " → " .. folder
        end
        lines[#lines + 1] = T(_("Server: %1"), desc)
    else
        lines[#lines + 1] = _("Server: not set")
    end

    local pending_count = 0
    for __ in pairs(getSetting("pending_uploads", {})) do
        pending_count = pending_count + 1
    end
    if pending_count > 0 then
        lines[#lines + 1] = T(_("Upload pending: %1 files"), pending_count)
    end

    local last_export = getSetting("last_export")
    if last_export and last_export.at then
        local outcome = T(_("%1 exported, %2 skipped"),
            last_export.exported, last_export.skipped)
        if (last_export.backups or 0) > 0 then
            outcome = outcome .. " · "
                .. T(_("%1 files backed up (.bak)"), last_export.backups)
        end
        if (last_export.errors or 0) > 0 then
            outcome = outcome .. " · " .. T(_("%1 errors"), last_export.errors)
        end
        lines[#lines + 1] = T(_("Last export: %1 — %2"),
            os.date("%d/%m/%Y %H:%M", last_export.at), outcome)
    else
        lines[#lines + 1] = _("Last export: never")
    end

    local last_upload = getSetting("last_upload")
    if last_upload and last_upload.at then
        local outcome = T(_("%1 uploaded"), last_upload.uploaded)
        if (last_upload.errors or 0) > 0 then
            outcome = outcome .. " · " .. T(_("%1 errors"), last_upload.errors)
        end
        lines[#lines + 1] = T(_("Last upload: %1 — %2"),
            os.date("%d/%m/%Y %H:%M", last_upload.at), outcome)
    else
        lines[#lines + 1] = _("Last upload: never")
    end

    if pending_count > 0 then
        if not getSetting("upload", false) then
            lines[#lines + 1] = _("Next upload: disabled in settings")
        elseif not NetworkMgr:isConnected() then
            lines[#lines + 1] = _("Next upload: at the next connection")
        elseif self._flushing then
            lines[#lines + 1] = _("Next upload: in progress")
        else
            lines[#lines + 1] = _("Next upload: any moment now")
        end
    end
    return lines
end

function Tomedown:showStatus()
    -- KOReader's own inline styling, "Poor Text Formatting": the header
    -- char must open the text and the two private-use chars wrap what
    -- gets the bold face. Applied to the already translated lines, so
    -- the msgids stay plain.
    local styled = TextBoxWidget.PTF_HEADER
    for i, line in ipairs(self:statusLines()) do
        -- every line is "Label: value"; bold the label, up to the first
        -- colon (values may well contain colons: times, paths)
        local label, rest = line:match("^(.-:)(.*)$")
        if label then
            line = TextBoxWidget.PTF_BOLD_START .. label
                .. TextBoxWidget.PTF_BOLD_END .. rest
        end
        if i > 1 then
            styled = styled .. "\n"
        end
        styled = styled .. line
    end
    UIManager:show(InfoMessage:new{
        -- the smallest info face (18pt vs the default 24): every entry
        -- stays on a single line instead of wrapping into a wall of text
        face = Font:getFace("xx_smallinfofont"),
        -- 90% of the screen (the default is 2/3): bold labels plus long
        -- dates and outcomes still fit on one line
        width = math.floor(Device.screen:getWidth() * 0.9),
        text = styled,
    })
end

-- pending uploads: flushed when the connection comes back (NetworkConnected),
-- when KOReader wakes up and at plugin start, so an export made offline finds
-- the network at the next opportunity without any prompt

function Tomedown:schedulePendingFlush()
    if self._flush_scheduled or self._flushing then
        return
    end
    if not getSetting("upload", false) then
        return
    end
    if next(getSetting("pending_uploads", {})) == nil then
        return
    end
    if not NetworkMgr:isConnected() then
        return
    end
    self._flush_scheduled = true
    UIManager:scheduleIn(1, function()
        self._flush_scheduled = false
        self:flushPendingUploads()
    end)
end

--- Decide what a push may do before it sends anything: the flush of the
-- queued files and "Upload everything to the cloud" both run it.
-- Returns the paths that are safe to push and the paths held back.
--
-- An offline export wrote the new highlights into the local file while
-- the copy in the cloud sat still — or the other way round, when the
-- reader edited that copy in Obsidian in the meantime. Pushing blind
-- would throw those edits away, so before a file is uploaded the cloud
-- copy is fetched and compared with the one we last sent:
--   - still ours (or gone, or a server that cannot download): push;
--   - moved on: the cloud copy becomes the merge base, so the notes it
--     holds ride along into the file the highlights are then pushed in;
--   - not fetched (a transient error), or a copy the merge cannot fold
--     (broken markers): the file stays pending. Nothing is overwritten
--     and nothing is lost — the copy is still in the cloud and the new
--     highlights are still on the device. "Upload everything to the
--     cloud" runs this same comparison before it pushes; a reader who
--     wants the copy on the device to win turns the merge option off.
-- Only a markdown file is folded, the way it works at export time, and
-- only while the reader keeps their edits: with preserve or the merge
-- option off the file is pushed untouched. Preserve goes exactly the
-- way the export decides it: with the global switch on it covers
-- every file, with it off each book follows the choice it stored (and
-- an unknown file the default), and the index its own switch; the
-- heading that names the zone comes from the same place as at export
-- time.
function Tomedown:reconcilePending(server, paths, dir)
    local cloud_merge = getSetting("cloud_merge", true)
    -- md path -> book file, so a path can find both the choice its book
    -- made and the name it gave its zone
    local books_by_base = {}
    for file, record in pairs(getSetting("exports", {})) do
        if type(record) == "table" and record.base then
            books_by_base[record.base] = file
        end
    end
    local function bookFor(rel)
        if not rel or rel == INDEX_FILENAME then
            return nil
        end
        return books_by_base[rel:sub(1, -4)]
    end
    local function keepMerge(rel)
        if not cloud_merge then
            return false
        end
        if rel == INDEX_FILENAME then
            return getIndexPreserve()
        end
        -- a path with no book behind it follows the default, the same
        -- way the export decides for a file it does not know
        return getBookPreserve(bookFor(rel))
    end
    -- The name the export gives the zone of this path: a book's own
    -- when it named it, the global one otherwise, and the index its
    -- own title (which runExport writes into it).
    local function zoneTitle(rel)
        if rel == INDEX_FILENAME then
            return getNotesTitle(INDEX_FILENAME)
        end
        return getNotesTitle(bookFor(rel))
    end
    local ready, held = {}, {}
    for __, path in ipairs(paths) do
        local rel = path:sub(1, #dir + 1) == dir .. "/" and path:sub(#dir + 2)
        local local_md = readIfExists(path)
        local remote, status, tried
        if rel and rel:sub(-3) == ".md" and keepMerge(rel) and local_md then
            remote, status = self:fetchRemote(server, path, dir)
            tried = true
        end
        if tried and status == "failed" then
            -- the cloud copy may hold the reader's notes and we could
            -- not see it: pushing now is exactly the overwrite this
            -- whole path exists to prevent
            logger.warn("tomedown: holding back", rel or path,
                "(cloud copy not fetched, will retry at the next chance)")
            held[#held + 1] = path
        elseif remote and remote ~= local_md then
            -- pcall reports its own success first: merged is the text
            -- only when the call went through
            local call_ok, merged, info = pcall(merge.apply, remote, local_md,
                rel == INDEX_FILENAME and getSetting("index_regions") or nil,
                -- the zone is named the way the export names it
                { mode = "preserve", notes_title = zoneTitle(rel) })
            if call_ok and merged
                    and (info.reason == "merged" or info.reason == "format") then
                -- the copy in the cloud is the base the next export
                -- will compare against: keep it whole as .bak before
                -- the folded file replaces the local one. Unless it is
                -- the very copy this plugin uploaded last: nothing of
                -- the reader's can sit in it, and it would only take a
                -- slot from a copy that might hold their notes
                local cloud_base = self:cloudBase(server)
                local kept = true
                if not (cloud_base and cloud_base[rel]
                        and cloud_base[rel] == md5(remote)) then
                    kept = keepSafety(path, remote)
                end
                local written_ok = false
                if kept then
                    logger.info("tomedown:", rel,
                        "was edited in the cloud: folding it into the offline export")
                    written_ok = util.writeToFile(merged, path, true, false, true)
                end
                if written_ok then
                    ready[#ready + 1] = path
                else
                    -- the local file still holds the highlights and the
                    -- cloud copy still holds the notes: leave both be
                    logger.warn("tomedown: cannot fold", rel or path,
                        "into the offline export, holding it back")
                    held[#held + 1] = path
                end
            else
                local reason = type(info) == "table" and info.reason or "error"
                logger.warn("tomedown: the cloud copy of", rel or path,
                    "cannot be folded (" .. tostring(reason)
                    .. "), holding it back")
                held[#held + 1] = path
            end
        else
            -- still our copy, nothing there, no download support or the
            -- merge is off: what is on the device goes up as it is
            ready[#ready + 1] = path
        end
    end
    return ready, held
end

function Tomedown:flushPendingUploads()
    if self._flushing or not getSetting("upload", false) then
        return
    end
    local pending = getSetting("pending_uploads", {})
    local paths = {}
    for path in pairs(pending) do
        if lfs.attributes(path, "mode") == "file" then
            paths[#paths + 1] = path
        else
            -- the file was deleted locally: nothing to upload
            pending[path] = nil
        end
    end
    if #paths == 0 then
        setSetting("pending_uploads", pending)
        return
    end
    if not NetworkMgr:isConnected() then
        return
    end
    local server = self:getServer()
    if not server then
        return
    end
    local dir = self:getLocalDir()
    table.sort(paths)
    -- before anything is pushed, the cloud copies are compared with the
    -- ones this device last sent: a file edited in Obsidian meanwhile is
    -- folded into the offline export instead of being overwritten (see
    -- reconcilePending; the option lives in Settings → Cloud)
    --
    -- _flushing goes up before the reconcile too: it costs one network
    -- GET per file, and with the flag still down a reconnect or a resume
    -- landing in the middle of that stretch would schedule a second
    -- flush over the same paths. It comes down on every exit below, the
    -- error one included, so a failure inside the reconcile cannot leave
    -- the flush switched off for good.
    self._flushing = true
    local call_ok, ready, held = pcall(self.reconcilePending, self,
        server, paths, dir)
    if not call_ok then
        self._flushing = false
        logger.warn("tomedown: reconcile failed, nothing pushed:",
            tostring(ready))
        return
    end
    if #ready == 0 then
        -- everything is held back: the notes stay in the cloud and the
        -- highlights stay on the device, nothing to push right now
        self._flushing = false
        if #held > 0 then
            UIManager:show(InfoMessage:new{
                text = T(_("Cloud: %1 files kept back, will retry"), #held),
            })
        end
        return
    end
    logger.info(string.format("tomedown: flushing %d pending uploads", #ready))
    local upload_info = self:showProgress(T(_("Uploading %1 files to the cloud…"), #ready))
    self:uploadPaths(server, ready, function(ok_count, fail_count, failed)
        UIManager:close(upload_info)
        self._flushing = false
        local failed_set = {}
        for __, path in ipairs(failed) do
            failed_set[path] = true
        end
        local ok_paths = {}
        for __, path in ipairs(ready) do
            if not failed_set[path] then
                ok_paths[#ok_paths + 1] = path
            end
        end
        self:clearPendingUploads(ok_paths)
        if getSetting("covers", false) then
            Cover.deleteUploaded(ok_paths, self:getLocalDir())
        end
        if fail_count > 0 then
            UIManager:show(InfoMessage:new{
                text = T(_("Cloud: %1 uploaded, %2 errors"), ok_count, fail_count),
            })
        else
            UIManager:show(Notification:new{
                text = T(_("Cloud: %1 files uploaded"), ok_count),
                timeout = 3,
            })
        end
    end)
end

--- "Upload everything to the cloud": every markdown file and leftover
-- cover in the local folder goes up. The markdown files run through the
-- same reconciliation as the flush first (see reconcilePending): cloud
-- edits are folded into the push and a copy that cannot be read keeps
-- its file out of it, queued for the retry. With preserve or the merge
-- option off the push is blind: the reader has chosen the device to win.
function Tomedown:reuploadAll(touchmenu)
    if touchmenu and touchmenu.closeMenu then
        touchmenu:closeMenu()
    end
    local server = self:getServer()
    if not server then
        UIManager:show(InfoMessage:new{ text = _("Choose a cloud server in the settings first.") })
        return
    end
    local dir = self:getLocalDir()
    local paths = {}
    local function listDir(path, match)
        local ok, iter, dir_obj = pcall(lfs.dir, path)
        if not ok or not iter then
            return
        end
        for entry in iter, dir_obj do
            if entry ~= "." and entry ~= ".." and match(entry) then
                paths[#paths + 1] = path .. "/" .. entry
            end
        end
    end
    listDir(dir, function(entry)
        return entry:sub(-3) == ".md"
    end)
    -- covers still sitting on the device (upload was off, or the upload
    -- failed earlier) ride along with "Upload everything"
    listDir(dir .. "/covers", function(entry)
        return entry:sub(-4) == ".jpg"
    end)
    if #paths == 0 then
        UIManager:show(Notification:new{
            text = _("Nothing to upload, export something first."),
            timeout = 3,
        })
        return
    end

    table.sort(paths)
    if not NetworkMgr:isConnected() then
        -- nothing can go up now: queue everything and let the flush
        -- push it when the connection comes back
        self:markPendingUploads(paths)
        UIManager:show(InfoMessage:new{
            text = T(_("Cloud: %1 files kept back, will retry"), #paths),
        })
        return
    end
    -- the same guard the flush runs: a copy edited in Obsidian meanwhile
    -- is folded into the push, a copy that cannot be read keeps its file
    -- back in the queue instead of being overwritten
    local ready, held = self:reconcilePending(server, paths, dir)
    if #held > 0 then
        self:markPendingUploads(held)
    end
    if #ready == 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("Cloud: %1 files kept back, will retry"), #held),
        })
        return
    end
    local info = self:showProgress(T(_("Uploading %1 files to the cloud…"), #ready))
    self:uploadPaths(server, ready, function(ok_count, fail_count, failed)
        UIManager:close(info)
        local failed_set = {}
        for __, path in ipairs(failed) do
            failed_set[path] = true
        end
        local ok_paths = {}
        for __, path in ipairs(ready) do
            if not failed_set[path] then
                ok_paths[#ok_paths + 1] = path
            end
        end
        self:clearPendingUploads(ok_paths)
        if #failed > 0 then
            -- the failures join the queue too: the flush retries them at
            -- the next chance, the way it already does for the export
            self:markPendingUploads(failed)
        end
        if getSetting("covers", false) then
            Cover.deleteUploaded(ok_paths, dir)
        end
        if fail_count > 0 then
            UIManager:show(InfoMessage:new{
                text = T(_("Cloud: %1/%2 files uploaded, %3 errors"), ok_count, #ready, fail_count),
            })
        else
            UIManager:show(Notification:new{
                text = T(_("Cloud: %1 files uploaded"), ok_count),
                timeout = 3,
            })
        end
    end)
end

-- settings / choices

function Tomedown:chooseCloudFolder(touchmenu)
    local cloud = self.ui and self.ui.cloudstorage
    if not cloud then
        UIManager:show(InfoMessage:new{
            text = _("Enable the \"Cloud storage\" plugin to upload to the cloud."),
        })
        return
    end
    cloud:onShowCloudStorageList(function(server)
        setSetting("server", server)
        if touchmenu and touchmenu.updateItems then
            touchmenu:updateItems()
        end
    end)
end

function Tomedown:editRemoteFolder(touchmenu)
    local dialog
    dialog = InputDialog:new{
        title = _("Remote folder on the server"),
        input = getSetting("remote_folder", ""),
        hint = _("leave empty to use the folder chosen in the browser"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
            {
                {
                    text = _("Save"),
                    callback = function()
                        local value = dialog:getInputText() or ""
                        setSetting("remote_folder", value:gsub("^%s+", ""):gsub("%s+$", ""))
                        UIManager:close(dialog)
                        if touchmenu and touchmenu.updateItems then
                            touchmenu:updateItems()
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Tomedown:editLocalDir(touchmenu)
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        title = _("Local folder for exports"),
        path = self:getLocalDir(),
        select_directory = true,
        select_file = false,
        show_files = false,
        onConfirm = function(folder)
            folder = (folder == "/") and "/" or folder:gsub("/+$", "")
            setSetting("local_dir", folder)
            -- The folder decides where every export lands, but
            -- saveSetting only writes to memory: KOReader reaches
            -- flush() on suspend, on its 15 minutes autosave and when
            -- the reader UI closes, so dying in between would bring
            -- the exports back to the folder the reader just left.
            -- One write makes the choice stick at once, the way
            -- FileManager:onClose() does before going away.
            if G_reader_settings.flush then
                G_reader_settings:flush()
            end
            if touchmenu and touchmenu.updateItems then
                touchmenu:updateItems()
            end
        end,
    })
end

-- Name the writable zone: the global heading from the Markdown menu, or
-- one file's own heading when the file is given (the row inside the
-- book's menu, the index's own row in Settings). A rename must reach
-- the files it names: the global one invalidates every export hash, a
-- book's only its own (the blocks themselves do not change, only the
-- heading above them), the index every one, since the index is only
-- rewritten along with the books. A file title set to "" names its
-- zone with nothing at all, while the global heading keeps applying to
-- every other file.
function Tomedown:editNotesTitle(touchmenu, file)
    local dialog
    -- the field shows the heading this file will actually export: the
    -- book's own when it asked for one ("" included, truthy in Lua),
    -- the global one otherwise
    local current = file and getNotesTitle(file)
        or getSetting("notes_title", nil) or _("My notes...")
    dialog = InputDialog:new{
        title = _("Personal notes heading"),
        input = current,
        hint = _("leave empty to export no heading"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
            {
                {
                    text = _("Save"),
                    callback = function()
                        local value = dialog:getInputText() or ""
                        value = value:gsub("^%s+", ""):gsub("%s+$", "")
                        if file then
                            -- the field starts on the heading this book
                            -- exports today: its own when it has one, the
                            -- global one otherwise. Saving a book that
                            -- never chose, with that global title still
                            -- in the field, must not store a copy of it:
                            -- the book would stop following the global
                            -- one, and a later rename in Settings would
                            -- leave it behind with no way to see it. A
                            -- choice is only made by typing over it.
                            local global = getSetting("notes_title", nil)
                                or _("My notes...")
                            local had_own =
                                getSetting("notes_titles", {})[file] ~= nil
                            if not had_own and value == global then
                                UIManager:close(dialog)
                                if touchmenu and touchmenu.updateItems then
                                    touchmenu:updateItems()
                                end
                                return
                            end
                            setBookNotesTitle(file, value)
                            if file == INDEX_FILENAME then
                                -- the index is only rebuilt when a
                                -- book is exported with it: every file
                                -- has to be rewritten for the new
                                -- heading to reach it
                                self:invalidateExportHashes()
                            else
                                -- this book's file carries the old
                                -- heading: the next export has to
                                -- rewrite it, and only it
                                self:invalidateExportHash(file)
                            end
                        else
                            setSetting("notes_title", value)
                            self:invalidateExportHashes()
                        end
                        UIManager:close(dialog)
                        if touchmenu and touchmenu.updateItems then
                            touchmenu:updateItems()
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

-- menu

function Tomedown:genPickerMenu()
    self.book_cache = {}
    local selected = getSetting("selected", {})
    local books = self:buildBooks(self:listBookFiles())
    table.sort(books, function(a, b)
        return tostring(a.title):lower() < tostring(b.title):lower()
    end)

    local function countSelected()
        local count = 0
        for __, book in ipairs(books) do
            if selected[book.file] then
                count = count + 1
            end
        end
        return count
    end

    local items = {}
    if #books == 0 then
        return {
            {
                text = _("No books with highlights"),
                enabled = false,
            },
        }
    end

    items[#items + 1] = {
        text_func = function()
            return T(_("Export selected (%1)"), countSelected())
        end,
        enabled_func = function()
            return countSelected() > 0
        end,
        callback = function(touchmenu)
            local files = {}
            for __, book in ipairs(books) do
                if selected[book.file] then
                    files[#files + 1] = book.file
                end
            end
            if #files == 0 then
                return
            end
            if touchmenu and touchmenu.closeMenu then
                touchmenu:closeMenu()
            end
            self:runExport(files, {})
        end,
    }
    items[#items + 1] = {
        text = _("Deselect all"),
        enabled_func = function()
            return countSelected() > 0
        end,
        callback = function()
            for __, book in ipairs(books) do
                selected[book.file] = nil
            end
            setSetting("selected", selected)
        end,
        separator = true,
    }

    for __, book in ipairs(books) do
        items[#items + 1] = {
            text_func = function()
                return book.title .. " (" .. book.count .. ")"
            end,
            checked_func = function()
                return selected[book.file] or nil
            end,
            keep_menu_open = true,
            callback = function()
                if selected[book.file] then
                    selected[book.file] = nil
                else
                    selected[book.file] = true
                end
                setSetting("selected", selected)
            end,
        }
    end
    return items
end

--- Label of a group or submenu row: a Nerd Font glyph from the symbols
-- font KOReader already ships, two spaces, then the label. The glyph
-- stays outside the translated string, so .po files never see it. The
-- code points are in the Private Use Area on purpose (anything else
-- risks missing glyphs in other fonts) - the same rule Bookshelf's
-- menus follow.
local function withIcon(glyph, text)
    return glyph .. "  " .. text
end

--- Settings: four groups (the structure Bookshelf uses). About lives
-- in the main menu right under Settings. Every setting keeps its own
-- row; the checkable ones keep their keep_menu_open so KOReader
-- refreshes the tick in place.
-- Dropping the stored hash forces the next "Export only what changed"
-- to rewrite every book: the render options (covers, callout) are not
-- part of hashBook, so without this a settings toggle would leave the
-- already exported .md files stale until the highlights change.
function Tomedown:invalidateExportHashes()
    local records = getSetting("exports", {})
    local changed = false
    for __, record in pairs(records) do
        if type(record) == "table" and record.hash ~= nil then
            record.hash = nil
            changed = true
        end
    end
    if changed then
        setSetting("exports", records)
    end
end

-- the same drop for a single book: flipping preserve for one book must
-- rewrite that one file at the next "Export only what changed" (its
-- zone appears or disappears), and must leave every other book's hash
-- alone, so the rest of the library is not exported again for nothing
function Tomedown:invalidateExportHash(file)
    local records = getSetting("exports", {})
    local record = records[file]
    if record and record.hash ~= nil then
        record.hash = nil
        setSetting("exports", records)
    end
end

function Tomedown:genSettingsMenu()
    -- declared before the Cloud rows below: the Upload toggle inside
    -- them rebuilds this very table in place, and in Lua a closure can
    -- only see a local that is already declared when it is written.
    -- `cloud` is forward-declared too, so buildCloudRows (also written
    -- before the rows but called only once the menu opens) can copy it.
    local cloud_table, buildCloudRows, cloud
    cloud = {
        {
            text = _("Upload to cloud"),
            enabled_func = function()
                return self:hasServer()
            end,
            checked_func = function()
                return self:hasServer() and getSetting("upload", false)
            end,
            keep_menu_open = true,
            callback = function(touchmenu)
                setSetting("upload", not getSetting("upload", false))
                -- the Merge row below exists only while upload is on:
                -- rebuild the open group in place (the same way the
                -- Preserve toggle rebuilds Markdown files), so the row
                -- shows up or goes away without leaving the menu
                if touchmenu and cloud_table
                        and touchmenu.item_table == cloud_table then
                    local fresh = buildCloudRows()
                    for i = #cloud_table, 1, -1 do
                        cloud_table[i] = nil
                    end
                    for _, item in ipairs(fresh) do
                        cloud_table[#cloud_table + 1] = item
                    end
                end
            end,
        },
        {
            text_func = function()
                local server = self:getServer()
                if not server then
                    return _("Server and folder: not set")
                end
                local cloud = self.ui and self.ui.cloudstorage
                local name = cloud and cloud.getServerNameType
                    and cloud:getServerNameType(server) or server.name or "?"
                local folder = self:getRemoteFolder()
                if folder ~= "" then
                    return T(_("Server and folder: %1 → %2"), name, folder)
                end
                return T(_("Server and folder: %1"), name)
            end,
            callback = function(touchmenu)
                self:chooseCloudFolder(touchmenu)
            end,
        },
        {
            text_func = function()
                local folder = self:getRemoteFolder()
                if folder == "" then
                    return _("Remote folder: not set")
                end
                return T(_("Remote folder: %1"), folder)
            end,
            callback = function(touchmenu)
                self:editRemoteFolder(touchmenu)
            end,
        },
    }
    -- The Merge row folds the cloud copy back into the file before the
    -- render, but only a cloud reader has a cloud copy to fold, and
    -- only while preserve keeps a write zone to fold into: with no
    -- server, no upload or preserve off the row is not shown at all.
    -- It belongs to the global switch: the per book choice lives in the
    -- book's own menu, not in the settings (the way the row that names
    -- the zone below exists only while preserve is on).
    -- The group is rebuilt every time it opens, and in place when the
    -- Upload or Preserve toggle flips (both rebuild below).
    -- (cloud_table, buildCloudRows and cloud are all declared before
    -- the Cloud rows above, so the toggles can see them; here
    -- buildCloudRows is only assigned, after the `cloud` table exists.)
    buildCloudRows = function()
        local rows = {}
        for i, item in ipairs(cloud) do
            rows[i] = item
        end
        if self:hasServer() and getSetting("upload", false)
                and getSetting("preserve", false) then
            rows[#rows + 1] = {
                text = _("Merge edits made in the cloud"),
                checked_func = function()
                    return getSetting("cloud_merge", true)
                end,
                keep_menu_open = true,
                callback = function()
                    setSetting("cloud_merge", not getSetting("cloud_merge", true))
                end,
            }
        end
        return rows
    end
    -- The row that renames the heading of the write zone names the
    -- global one, and that heading is written only behind the merge
    -- markers: with preserve off every export overwrites the file and
    -- no heading ever reaches it, so the row exists solely while the
    -- preserve toggle below is on. The settings speak about the global
    -- switch only: a book's own choice, and its own heading, live in
    -- the book's own menu. The group is therefore rebuilt every time it
    -- opens instead of being a fixed table: files_table is the live
    -- copy the open group shows, buildFilesRows assembles it, both
    -- declared before the table so the toggle's callback can reach
    -- them.
    local files_table
    local buildFilesRows
    -- rebuild the Markdown files group in place: the index rows below
    -- depend on Generate, on Preserve and on their own switch, the
    -- heading row on Preserve, so they show up or go away as those
    -- switches flip, without the reader leaving the menu (the same
    -- in-place refresh the Developer submenu uses)
    local function rebuildFilesRows(touchmenu)
        if not touchmenu or not files_table
            or touchmenu.item_table ~= files_table then
            return
        end
        local fresh = buildFilesRows()
        for i = #files_table, 1, -1 do
            files_table[i] = nil
        end
        for _, item in ipairs(fresh) do
            files_table[#files_table + 1] = item
        end
    end
    local files = {
        {
            text_func = function()
                return T(_("Local folder: %1"), self:getLocalDir())
            end,
            callback = function(touchmenu)
                self:editLocalDir(touchmenu)
            end,
        },
        {
            text = T(_("Generate the %1 (for Obsidian)"), INDEX_FILENAME),
            checked_func = function()
                return getSetting("with_index", true)
            end,
            keep_menu_open = true,
            callback = function(touchmenu)
                setSetting("with_index", not getSetting("with_index", true))
                -- the index rows below exist only while an
                -- index is generated at all
                rebuildFilesRows(touchmenu)
            end,
        },
        {
            text = _("Include page bookmarks"),
            checked_func = function()
                return getSetting("include_bookmarks", false)
            end,
            keep_menu_open = true,
            callback = function()
                setSetting("include_bookmarks", not getSetting("include_bookmarks", false))
            end,
        },
        {
            text = _("Include book covers"),
            checked_func = function()
                return getSetting("covers", false)
            end,
            keep_menu_open = true,
            callback = function()
                setSetting("covers", not getSetting("covers", false))
                self:invalidateExportHashes()
            end,
        },
        {
            text = _("Auto-export on close"),
            checked_func = function()
                return getSetting("auto_export", false)
            end,
            keep_menu_open = true,
            callback = function()
                setSetting("auto_export",
                    not getSetting("auto_export", false))
            end,
        },
        {
            -- what wins when the render meets a file the reader edited;
            -- opt-in since 1.0: off means the tomedown ≤ 0.8 behaviour
            -- (every export writes the file from scratch), and every
            -- file follows the choice it stored. On, this switch alone
            -- governs every file and names every zone, and no other
            -- row is built to choose for one file
            text = _("Preserve: global"),
            checked_func = function()
                return getSetting("preserve", false)
            end,
            keep_menu_open = true,
            callback = function(touchmenu)
                setSetting("preserve", not getSetting("preserve", false))
                -- switching modes must regenerate what the other
                -- mode left behind: the next export rewrites
                -- every file
                self:invalidateExportHashes()
                -- With the switch on the rows below go its way: the
                -- index rows leave (it covers the index too) and the
                -- heading row for it appears. Rebuild the open group
                -- in place, the way the Developer submenu does, so the
                -- rows change without leaving the menu, and rebuild the
                -- book menu above: the switch is in charge of the per
                -- book rows there, and its own table is re-read when
                -- the reader taps back from Settings
                rebuildFilesRows(touchmenu)
                self:refreshBookMenu()
                -- the Merge row in Cloud also needs preserve on (there
                -- is no write zone to fold into without it): rebuild
                -- that group too, so it stays in step
                if touchmenu and cloud_table
                        and touchmenu.item_table == cloud_table then
                    local fresh = buildCloudRows()
                    for i = #cloud_table, 1, -1 do
                        cloud_table[i] = nil
                    end
                    for _, item in ipairs(fresh) do
                        cloud_table[#cloud_table + 1] = item
                    end
                end
            end,
        },
    }
    buildFilesRows = function()
        local rows = {}
        for i, item in ipairs(files) do
            rows[i] = item
        end
        -- The index is a file like the others: since 1.1 it gets its
        -- own switch, right below the global one, and the row that
        -- names its zone below that one. Both stay away while the
        -- global switch is on, which governs the index like every
        -- other file, and the switch itself exists only while an index
        -- is generated at all. Its checked state is the effective one:
        -- the reader's own choice when they made one, the global
        -- switch otherwise.
        if getSetting("with_index", true)
                and not getSetting("preserve", false) then
            rows[#rows + 1] = {
                text = _("Preserve: index"),
                checked_func = function()
                    return getIndexPreserve()
                end,
                keep_menu_open = true,
                callback = function(touchmenu)
                    setSetting("preserve_index",
                        not getIndexPreserve())
                    -- the index on disk was written the other way
                    -- round: the next export has to rewrite it
                    self:invalidateExportHashes()
                    -- the row below exists only while the index keeps
                    -- a zone to name: rebuild the open group in place
                    rebuildFilesRows(touchmenu)
                end,
            }
            if getIndexPreserve() then
                rows[#rows + 1] = {
                    text_func = function()
                        return T(_("Index notes: %1"),
                            getNotesTitle(INDEX_FILENAME))
                    end,
                    callback = function(touchmenu)
                        self:editNotesTitle(touchmenu, INDEX_FILENAME)
                    end,
                }
            end
        end
        -- with the global switch on it names every zone itself, and
        -- this is the single row that does it (every file follows it)
        if getSetting("preserve", false) then
            rows[#rows + 1] = {
                text_func = function()
                    return T(_("Notes: %1"), getNotesTitle())
                end,
                callback = function(touchmenu)
                    self:editNotesTitle(touchmenu)
                end,
            }
        end
        return rows
    end
    -- Developer updates: everything that is not meant for daily use,
    -- in its own submenu. Beta Releases first; while it is ticked a
    -- beta "Check for updates" sits right below it, then a separator,
    -- the way back to stable and the installed version as a plain
    -- grey label. The row list is rebuilt whenever the submenu opens
    -- and in place when the toggle flips (TouchMenu redraws the table
    -- after the callback), so the beta check appears at once.
    local developer_table
    local function developerItems()
        local beta_on = getSetting("beta_releases", false)
        local items = {
            {
                text = _("Beta Releases"),
                checked_func = function()
                    return getSetting("beta_releases", false)
                end,
                keep_menu_open = true,
                callback = function(touch_menu)
                    setSetting("beta_releases",
                        not getSetting("beta_releases", false))
                    Update.clearAvailableCache()
                    -- the submenu that is open IS this table: rebuild
                    -- it in place so the check row shows up or goes
                    -- away without leaving the menu
                    if touch_menu
                            and touch_menu.item_table == developer_table then
                        local fresh = developerItems()
                        for i = #developer_table, 1, -1 do
                            developer_table[i] = nil
                        end
                        for _, item in ipairs(fresh) do
                            developer_table[#developer_table + 1] = item
                        end
                    end
                end,
                separator = not beta_on,
            },
        }
        if beta_on then
            items[#items + 1] = {
                text = _("Check for updates"),
                callback = function()
                    Update.check(true)
                end,
                separator = true,
            }
        end
        items[#items + 1] = {
            -- the cartoon bomb (U+ED8F): the reset blows the beta up
            text = withIcon("\xEE\xB6\x8F", _("Reset to latest stable release")),
            callback = function()
                Update.resetToStable()
            end,
        }
        items[#items + 1] = {
            text_func = function()
                local current = Update.getInstalledVersion()
                local kind = current:find("-", 1, true)
                    and _("Beta") or _("Release")
                return T(_("Installed: v%1 (%2)"), current, kind)
            end,
            enabled = false,
        }
        return items
    end
    local updates = {
        {
            text_func = function()
                local current = Update.getInstalledVersion()
                local available = Update.getAvailableVersion()
                if available then
                    return T(_("Update available: v%1 → v%2"), current, available)
                end
                return T(_("Check for updates (v%1)"), current)
            end,
            callback = function()
                Update.check()
            end,
        },
        {
            text = _("View changelog"),
            callback = function()
                Update.showChangelog()
            end,
            separator = true,
        },
        {
            text = _("Check for updates in background"),
            checked_func = function()
                return getSetting("update_check", false)
            end,
            keep_menu_open = true,
            callback = function()
                setSetting("update_check", not getSetting("update_check", false))
            end,
        },
        {
            text = withIcon("\xEF\x84\xA6", _("Developer updates")), -- code-fork
            sub_item_table_func = function()
                developer_table = developerItems()
                return developer_table
            end,
        },
    }
    -- The three rows that speak about the highlights themselves, out of
    -- the Markdown files group (where the rows already come and go with
    -- the switches): how a Special Highlight is marked in the note, and
    -- whether every quote carries its stable block id. Static: no row
    -- here appears or disappears.
    local highlights = {
        {
            text = _("All highlights as Special Highlights"),
            checked_func = function()
                return getSetting("callout", false)
            end,
            keep_menu_open = true,
            callback = function()
                setSetting("callout", not getSetting("callout", false))
                self:invalidateExportHashes()
            end,
        },
        {
            -- how a Special Highlight is marked in the note; meaningful
            -- only while "All highlights as Special Highlights" is off,
            -- because that one makes every highlight a callout
            text_func = function()
                local labels = {
                    callout = _("Callout"),
                    bold = _("Bold"),
                }
                return T(_("Special highlight marker: %1"),
                    labels[getSetting("special_marker", "callout")]
                        or labels.callout)
            end,
            enabled_func = function()
                return not getSetting("callout", false)
            end,
            keep_menu_open = true,
            sub_item_table = {
                {
                    text = _("Callout"),
                    radio = true,
                    checked_func = function()
                        return getSetting("special_marker", "callout") == "callout"
                    end,
                    keep_menu_open = true,
                    callback = function()
                        setSetting("special_marker", "callout")
                        self:invalidateExportHashes()
                    end,
                },
                {
                    text = _("Bold"),
                    radio = true,
                    checked_func = function()
                        return getSetting("special_marker", "callout") == "bold"
                    end,
                    keep_menu_open = true,
                    callback = function()
                        setSetting("special_marker", "bold")
                        self:invalidateExportHashes()
                    end,
                },
            },
        },
        {
            text = _("Block IDs for highlights"),
            checked_func = function()
                return getSetting("block_ids", false)
            end,
            keep_menu_open = true,
            callback = function()
                setSetting("block_ids", not getSetting("block_ids", false))
                self:invalidateExportHashes()
            end,
        },
    }

    return {
        { text = withIcon("\xEE\xB4\xBE", _("Cloud")), -- cloud-sync
            sub_item_table_func = function()
                cloud_table = buildCloudRows()
                return cloud_table
            end },
        { text = withIcon("\xEF\x83\xB6", _("Markdown files")), -- file-text
            sub_item_table_func = function()
                files_table = buildFilesRows()
                return files_table
            end },
        { text = withIcon("\xEE\xB5\x91", _("Highlights")), -- marker
            sub_item_table = highlights },
        { text = withIcon("\xEE\xB6\xAE", _("Updates")), -- update
            sub_item_table = updates },
    }
end

--- About: the popup Bookshelf shows - the logo, the installed version,
-- the description from _meta.lua and the tappable repository URLs
-- (Codeberg first, GitHub as the mirror), centred on the screen. No
-- buttons; tapping outside the frame (or Back) closes it. The logo
-- lives in assets/ (SVG or PNG) and is only shown when the file is
-- there, so a copy of the plugin without it still shows the rest.
function Tomedown:showAbout()
    local src = debug.getinfo(1, "S").source
    local plugin_dir
    if src:sub(1, 1) == "@" then
        plugin_dir = src:sub(2):match("^(.*)/[^/]+$")
    end
    local version = Update.getInstalledVersion()
    local description = ""
    if plugin_dir then
        local ok, meta = pcall(dofile, plugin_dir .. "/_meta.lua")
        if ok and type(meta) == "table" and meta.description then
            description = meta.description
        end
    end

    -- Hard-coded English URLs; not translatable. Display form drops the
    -- https:// prefix; the full URL with the scheme is what
    -- Device:openLink and the clipboard receive on tap. Codeberg first:
    -- it is the host that answers while the GitHub side stays a 404
    local REPOS = {
        { display = "codeberg.org/imanubdesigner/tomedown.koplugin",
            url = "https://codeberg.org/imanubdesigner/tomedown.koplugin" },
        { display = "github.com/imanubdesigner/tomedown.koplugin",
            url = "https://github.com/imanubdesigner/tomedown.koplugin" },
    }

    local Screen = Device.screen
    local Geom = require("ui/geometry")
    local Size = require("ui/size")
    local Blitbuffer = require("ffi/blitbuffer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local MovableContainer = require("ui/widget/container/movablecontainer")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local TextWidget = require("ui/widget/textwidget")
    local Button = require("ui/widget/button")
    local GestureRange = require("ui/gesturerange")

    local sw, sh = Screen:getWidth(), Screen:getHeight()
    -- Frame target: ~80% of width on phone-sized portraits, capped so
    -- it doesn't sprawl on landscape / tablet sizes
    local frame_w = math.min(math.floor(sw * 0.8), Screen:scaleBySize(420))
    local FRAME_PAD = Screen:scaleBySize(24)
    local content_w = frame_w - FRAME_PAD * 2

    local column = VerticalGroup:new{ align = "center" }

    -- Logo at the top, centred: SVG preferred (scales to any density),
    -- PNG as a fallback. alpha=true so a transparent background stays
    -- transparent instead of rendering as opaque black
    -- Native size from the file's own header (SVG viewBox/width/height):
    -- passing width alone would leave ImageWidget reserve a square box
    -- with empty bands above and below the logo
    local function imageSize(path)
        local f = io.open(path, "rb")
        if not f then
            return nil
        end
        local head = f:read(4096)
        f:close()
        if not head then
            return nil
        end
        local w, h = head:match(
            'viewBox%s*=%s*"%s*[%-%d%.]+%s+[%-%d%.]+%s+([%-%d%.]+)%s+([%-%d%.]+)%"')
        if not w then
            w = head:match('width%s*=%s*"([%d%.]+)"')
            h = head:match('height%s*=%s*"([%d%.]+)"')
        end
        w, h = tonumber(w), tonumber(h)
        if not w or not h or w <= 0 or h <= 0 then
            return nil
        end
        return w, h
    end
    if plugin_dir then
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs and lfs.attributes then
            for __, name in ipairs({ "logo.svg", "logo.png" }) do
                local path = plugin_dir .. "/assets/" .. name
                if lfs.attributes(path) then
                    local ImageWidget = require("ui/widget/imagewidget")
                    local logo = {
                        file = path,
                        width = math.min(content_w, Screen:scaleBySize(220)),
                        scale_factor = 0,
                        alpha = true,
                    }
                    local nat_w, nat_h = imageSize(path)
                    if nat_w and nat_h then
                        logo.height = math.floor(logo.width * nat_h / nat_w + 0.5)
                    end
                    column[#column + 1] = ImageWidget:new(logo)
                    column[#column + 1] = VerticalSpan:new{
                        width = Size.padding.default,
                    }
                    break
                end
            end
        end
    end

    -- Version-only line: the logo carries the name, the digits stand
    -- alone; sourced live from _meta.lua
    column[#column + 1] = TextWidget:new{
        text = "v" .. version,
        face = Font:getFace("cfont", 16),
    }
    column[#column + 1] = VerticalSpan:new{ width = Size.padding.large }
    column[#column + 1] = TextBoxWidget:new{
        text = description,
        face = Font:getFace("cfont", 16),
        width = content_w,
        alignment = "center",
    }
    column[#column + 1] = VerticalSpan:new{ width = Size.padding.large }
    -- Tappable URL: Device:openLink where it exists (SDL/Android); on
    -- the e-reader the URL goes to KOReader's internal clipboard with
    -- a brief Notification instead (no browser to open)
    local function open_link(url)
        return function()
            local ok = false
            if Device.openLink then
                local ok_call, ret = pcall(function() return Device:openLink(url) end)
                if ok_call and ret then
                    ok = true
                end
            end
            if not ok and Device.input and Device.input.setClipboardText then
                pcall(function() Device.input.setClipboardText(url) end)
                UIManager:show(Notification:new{
                    text = _("Link copied to clipboard"),
                })
            end
        end
    end
    for i, repo in ipairs(REPOS) do
        if i > 1 then
            column[#column + 1] = VerticalSpan:new{ width = Size.padding.small }
        end
        column[#column + 1] = Button:new{
            text = repo.display,
            bordersize = 0,
            padding = 0,
            margin = 0,
            text_font_face = "cfont",
            text_font_size = 14,
            callback = open_link(repo.url),
        }
    end

    local frame = FrameContainer:new{
        radius = Size.radius.window,
        padding = FRAME_PAD,
        padding_top = math.floor(FRAME_PAD * 0.5),
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        column,
    }

    local dialog
    dialog = InputContainer:new{
        align = "center",
        dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
        CenterContainer:new{
            dimen = Geom:new{ w = sw, h = sh },
            MovableContainer:new{ frame },
        },
    }
    if Device:isTouchDevice() then
        dialog.ges_events = {
            TapClose = { GestureRange:new{
                ges = "tap",
                range = Geom:new{ x = 0, y = 0, w = sw, h = sh },
            } },
        }
        dialog.onTapClose = function(self_d, _arg, ges_ev)
            if not frame.dimen or ges_ev.pos:notIntersectWith(frame.dimen) then
                UIManager:close(self_d)
            end
            return true
        end
    end
    if Device:hasKeys() then
        dialog.key_events = { Close = { { Device.input.group.Back } } }
        dialog.onClose = function(self_d)
            UIManager:close(self_d)
            return true
        end
    end

    UIManager:show(dialog)
end

--- One-time default for "Upload to cloud": a fresh install starts with
-- it off (local-first), while anyone who has already exported keeps the
-- old behaviour (on) unless they had explicitly chosen otherwise.
function Tomedown:migrateDefaults()
    local settings = G_reader_settings:readSetting(SETTINGS_KEY)
    if type(settings) == "table" and settings.upload == nil
            and settings.exports ~= nil then
        settings.upload = true
        G_reader_settings:saveSetting(SETTINGS_KEY, settings)
    end
end

function Tomedown:init()
    self.ui.menu:registerToMainMenu(self)
    -- Do NOT insert this instance into self.ui here: KOReader runs init()
    -- inside createPluginInstance and inserts the instance itself right
    -- after, via registerModule (ReaderUI and FileManager both do). An
    -- extra insert left the plugin in the children array twice, so every
    -- event reached it twice: on close two exports ran back to back and
    -- the silent second one (nothing changed) overwrote the recorded
    -- outcome shown by the Status panel.
    -- before anything reads the upload default (the pending flush below)
    self:migrateDefaults()
    if getSetting("update_check", false) then
        -- quiet check shortly after KOReader starts; the same check also
        -- runs when the menu is opened (both throttled to once an hour)
        UIManager:scheduleIn(10, function()
            Update.checkBackground()
        end)
    end
    -- pending uploads from an offline export: catch up right away if the
    -- network is already up (no NetworkConnected event will fire then)
    self:schedulePendingFlush()
end

-- auto-export (first row of the Tomedown menu, off by default)

function Tomedown:onCloseDocument()
    if not getSetting("auto_export", false) then
        return
    end
    local doc = self.ui and self.ui.document
    local path = doc and doc.file
    if not path then
        return
    end
    -- let the reader finish closing (and flush the .sdr) first
    local closed_at = time.now()
    UIManager:scheduleIn(1, function()
        logger.info(string.format(
            "tomedown: auto export starts %.2fs after the close",
            time.to_ms(time.since(closed_at)) / 1000))
        self:runExport({ path }, { auto = "close" })
    end)
end

function Tomedown:onSuspend()
    if not getSetting("auto_export", false) then
        return
    end
    local doc = self.ui and self.ui.document
    local path = doc and doc.file
    if not path then
        return
    end
    -- synchronous and silent: no widget, no network right before sleep
    self:runExport({ path }, { auto = "suspend" })
end

function Tomedown:onResume()
    self:schedulePendingFlush()
end

function Tomedown:onNetworkConnected()
    self:schedulePendingFlush()
end

-- Special Highlight: two entry points. (1) KOReader's full highlight menu
-- (fresh text selection or the "…" of an existing highlight): keyed
-- "03b_special", so the alphabetical menu order lands the button right
-- under "02_highlight"; on a fresh selection there is no annotation yet,
-- so it creates the highlight through the very same prompt "Highlight"
-- uses (color prompt included) and marks what it hands back. (2) The
-- compact edit menu shown when an existing highlight is tapped
-- (trash/Style/Color/…): KOReader builds it from a hardcoded list and
-- exposes no API for it, so showHighlightDialog is wrapped and our row
-- appended at the bottom while it constructs its ButtonDialog. Both
-- buttons read the mark dynamically: "Special Highlight" marks,
-- "Remove Special Highlight" unmarks. The mark lives on the annotation
-- itself (tomedown_special in the .sdr): it survives restarts, reaches
-- cleanAnnotations and therefore the markdown, and is part of the book
-- hash so the next export rewrites the .md.

-- saves the annotation list back on the book and confirms the change
function Tomedown:_specialSave(rh, marked)
    local doc_settings = rh.ui.doc_settings
    if doc_settings then
        doc_settings:saveSetting("annotations", rh.ui.annotation.annotations)
    end
    UIManager:show(Notification:new{
        text = marked and _("Highlight marked as special")
            or _("Special mark removed"),
        timeout = 2,
    })
end

-- marks/unmarks an existing highlight on an already loaded ReaderHighlight;
-- close_menu runs right after the flip (the caller's way to dismiss its UI)
function Tomedown:_specialToggle(rh, index, close_menu)
    local annotations = rh.ui.annotation and rh.ui.annotation.annotations
    local item = annotations and annotations[index]
    if not item then
        return
    end
    item.tomedown_special = not item.tomedown_special or nil
    local marked = item.tomedown_special
    if close_menu then
        close_menu()
    end
    self:_specialSave(rh, marked)
end

-- the button of the row appended at the bottom of the compact edit menu;
-- the label is read when the menu is built, the mark again on tap
function Tomedown:_specialEditRow(rh, index)
    local annotations = rh.ui.annotation and rh.ui.annotation.annotations
    local item = annotations and annotations[index]
    local marked = item and item.tomedown_special or false
    local button -- forward declaration: the callback closes over it
    button = {
        text = marked and _("Remove Special Highlight")
            or _("Special Highlight"),
        callback = function()
            self:_specialToggle(rh, index, button.on_done)
        end,
    }
    return button
end

-- installs the edit-menu hook once per session: the guard lives on the
-- ReaderHighlight class, so re-reading a book never wraps twice
function Tomedown:_installSpecialEditRow()
    local plugin = self
    local ok_class, ReaderHighlight = pcall(require,
        "apps/reader/modules/readerhighlight")
    local ok_dialog, ButtonDialog = pcall(require, "ui/widget/buttondialog")
    if not ok_class or not ok_dialog or not ReaderHighlight or not ButtonDialog then
        return
    end
    if ReaderHighlight.__tomedown_special_row then
        return
    end
    ReaderHighlight.__tomedown_special_row = true
    local orig_show = ReaderHighlight.showHighlightDialog
    ReaderHighlight.showHighlightDialog = function(rh, index)
        local own_new = rawget(ButtonDialog, "new")
        local resolved_new = ButtonDialog.new
        ButtonDialog.new = function(bd, opts)
            if type(opts) ~= "table" or opts.name ~= "edit_highlight_dialog" then
                return resolved_new(bd, opts)
            end
            -- KOReader names that dialog "edit_highlight_dialog" (for its
            -- own unit tests): append our row after the arrows and keep a
            -- handle on the dialog so the tap can dismiss the menu
            local button = plugin:_specialEditRow(rh, index)
            opts.buttons[#opts.buttons + 1] = { button }
            local dialog = resolved_new(bd, opts)
            button.on_done = function()
                UIManager:close(dialog)
            end
            return dialog
        end
        local ok, err = pcall(orig_show, rh, index)
        if own_new then
            ButtonDialog.new = own_new
        else
            ButtonDialog.new = nil
        end
        if not ok then
            error(err, 0)
        end
    end
end

function Tomedown:onReaderReady()
    local highlight = self.ui and self.ui.highlight
    if not highlight or not highlight.addToHighlightDialog then
        return
    end
    highlight:addToHighlightDialog("03b_special", function(this, index)
        local annotations = this.ui.annotation and this.ui.annotation.annotations
        local item = annotations and index and annotations[index]
        local marked = item and item.tomedown_special or false
        return {
            text = marked and _("Remove Special Highlight")
                or _("Special Highlight"),
            callback = function()
                if item then
                    self:_specialToggle(this, index, function()
                        this:onClose()
                    end)
                    return
                end
                -- fresh selection: showHighlightPrompt saves the highlight
                -- (and closes the menu) exactly like the Highlight button,
                -- then hands us the new annotation's index to mark
                this:showHighlightPrompt(function(new_index)
                    local anns = this.ui.annotation and this.ui.annotation.annotations
                    local annot = anns and anns[new_index]
                    if not annot then
                        return
                    end
                    annot.tomedown_special = true
                    self:_specialSave(this, true)
                end)
            end,
        }
    end)
    self:_installSpecialEditRow()
end

-- first-run onboarding: offer to export every book's highlights in one
-- tap, taken from KOReader's reading history. Runs when the menu is
-- first built (KOReader calls addToMainMenu lazily on the first menu
-- open of a session), so the reader is already interacting with the UI.
-- The prompt appears once in a lifetime: both "Export" and "Not now"
-- set the flag.
function Tomedown:maybePromptLibraryImport()
    if getSetting("import_prompt_done", false) then
        return
    end
    if next(getSetting("exports", {})) ~= nil then
        return
    end
    local files = self:listBookFiles()
    if #files == 0 then
        return
    end
    -- deferred so the ConfirmBox lands on top of the just-opened menu
    UIManager:scheduleIn(0.1, function()
        UIManager:show(ConfirmBox:new{
            text = T(_("Found %1 books in your KOReader reading history. Export their highlights now?"), #files),
            ok_text = _("Export"),
            cancel_text = _("Not now"),
            ok_callback = function()
                setSetting("import_prompt_done", true)
                self:runExport(files, {})
            end,
            cancel_callback = function()
                setSetting("import_prompt_done", true)
            end,
        })
    end)
end

-- Pin this plugin's row to the top of its menu tab. MenuSorter appends
-- items it cannot place in the cached order tables at the bottom of the
-- first tab, prefixed with "NEW: ", which buries the entry on a second
-- page. Referencing the id from the order tables puts it exactly where
-- we want it (first row of the Navigation tab in the reader, first row
-- of the first tab in the file browser) and skips the orphan pass
-- entirely, so the "NEW: " prefix disappears too. Keyed by id, so tab
-- reorders done by other plugins don't affect us. Idempotent:
-- addToMainMenu fires again on menu rebuilds and once per host.
local function pinToTop(order_module, group_id)
    local ok, order = pcall(require, order_module)
    if not ok or type(order) ~= "table" or type(order[group_id]) ~= "table" then
        -- outside KOReader (tests): no order tables, no placement
        return
    end
    local group = order[group_id]
    for _, id in ipairs(group) do
        if id == "tomedown" then
            return
        end
    end
    table.insert(group, 1, "tomedown")
end

-- The rows of the book's own menu, rebuilt every time the menu opens
-- (and in place when a switch in it or in Settings flips, so a row
-- appears or goes away without the reader leaving the menu). Nine rows
-- inside a book, ten while the open book keeps a write zone (that is
-- when a heading to name it with makes any sense at all), eight while
-- the global switch in Settings is on: it governs every file itself,
-- so both per book rows stay away. On the dashboard, with no book
-- open, the three rows that need one are not built at all, so seven.
function Tomedown:genBookMenu()
    local file = self:getCurrentFile()
    local rows = {}
    -- This row needs a book open, which means the document itself: in
    -- the file manager KOReader hands the plugin the FileManager as ui,
    -- which carries no document, and "lastfile" would then name the
    -- last book read over a book nobody has open.
    if self.ui and self.ui.document then
        rows[#rows + 1] = {
            text = withIcon("\xEE\x89\xBC", _("Export current book")),
            enabled_func = function()
                local current = self:getCurrentFile()
                return current ~= nil
                    and BookList.hasBookBeenOpened(current)
            end,
            callback = function(touchmenu)
                local current = self:getCurrentFile()
                if not current then
                    return
                end
                if touchmenu and touchmenu.closeMenu then
                    touchmenu:closeMenu()
                end
                self:runExport({ current }, {})
            end,
        }
    end
    rows[#rows + 1] = {
        text = withIcon("\xEE\xA4\xB5", _("Export only what changed")),
        enabled_func = function()
            return #self:listBookFiles() > 0
        end,
        callback = function(touchmenu)
            if touchmenu and touchmenu.closeMenu then
                touchmenu:closeMenu()
            end
            self:runExport(self:listBookFiles(), { only_updated = true })
        end,
    }
    -- Since 1.1 a book chooses for itself, but only while the global
    -- switch in Settings is off: with that switch on it covers every
    -- file and names every zone, so neither of these rows is built at
    -- all (the stored choice is never touched, it comes back the way
    -- the reader left it when the switch goes off again). The pencil
    -- keeps the hand edits of the open book, the row under it names
    -- that zone.
    --
    -- Both rows belong to a book that is open: without one there is no
    -- file to choose for. In the file manager KOReader hands the plugin
    -- the FileManager itself as ui, which carries no document, and
    -- getCurrentFile() would then fall back to "lastfile" (always set,
    -- it is the last book read) and drag these rows onto the dashboard
    -- pointing at a book nobody has open. ReaderUI instead passes the
    -- document, so inside a book both rows are there.
    if self.ui and self.ui.document and not getSetting("preserve", false) then
        rows[#rows + 1] = {
            text = withIcon("\xEF\x81\x80", _("Preserve: this book")),
            enabled_func = function()
                return self:getCurrentFile() ~= nil
            end,
            checked_func = function()
                local current = self:getCurrentFile()
                return current ~= nil and getBookPreserve(current)
            end,
            keep_menu_open = true,
            callback = function(touchmenu)
                local current = self:getCurrentFile()
                if not current then
                    return
                end
                if getBookPreserve(current) then
                    -- the file on disk holds a zone the reader may have
                    -- written in, and turning preserve off hands the
                    -- render straight back to the writer: the file is
                    -- replaced with no merge and no .bak. So it is asked
                    -- first, deferred the way the import prompt is, so
                    -- the box lands on top of the just-opened menu
                    UIManager:scheduleIn(0.1, function()
                        UIManager:show(ConfirmBox:new{
                            text = T(_("Turn preserve off for %1? Your notes will not be lost. A .bak copy is created."), ffiUtil.basename(current)),
                            ok_text = _("Turn off"),
                            cancel_text = _("Keep it on"),
                            -- nothing has been touched yet, so closing
                            -- is all cancel has to do (the box says so
                            -- itself, and the work waits for OK)
                            cancel_callback = function() end,
                            ok_callback = function()
                                setBookPreserve(current, false)
                                -- the stored hash goes with it: the
                                -- file was written the other way round
                                self:invalidateExportHash(current)
                                -- and the file is rewritten plain right
                                -- away instead of waiting for the next
                                -- export: runExport keeps the zoned copy
                                -- as .bak before the plain one lands
                                self:runExport({ current }, {})
                                -- the heading row below exists only
                                -- while this book keeps a zone to name,
                                -- and the menu sat open behind the box:
                                -- redraw the group, tick included
                                self:refreshBookMenu()
                                if touchmenu and touchmenu.updateItems then
                                    touchmenu:updateItems()
                                end
                            end,
                        })
                    end)
                    return
                end
                setBookPreserve(current, true)
                -- the file on disk was written the other way round:
                -- the next export has to rewrite it, so its stored
                -- hash goes, and only its hash
                self:invalidateExportHash(current)
                -- the heading row below exists only while this book
                -- keeps a zone to name
                self:refreshBookMenu()
            end,
        }
        if file and getBookPreserve(file) then
            rows[#rows + 1] = {
                text_func = function()
                    return T(_("Book notes: %1"), getNotesTitle(file))
                end,
                callback = function(touchmenu)
                    self:editNotesTitle(touchmenu, file)
                end,
            }
        end
    end
    rows[#rows + 1] = {
        text = withIcon("\xEE\xB9\x94", _("Choose books…")),
        sub_item_table_func = function()
            return self:genPickerMenu()
        end,
    }
    rows[#rows + 1] = {
        text = withIcon("\xEE\xA7\x99", _("Export every book's highlights")),
        enabled_func = function()
            return #self:listBookFiles() > 0
        end,
        callback = function(touchmenu)
            if touchmenu and touchmenu.closeMenu then
                touchmenu:closeMenu()
            end
            self:runExport(self:listBookFiles(), {})
        end,
        separator = true,
    }
    rows[#rows + 1] = {
        text = withIcon("\xEE\xB4\xBE", _("Upload everything to the cloud")),
        enabled_func = function()
            return self:hasServer()
        end,
        callback = function(touchmenu)
            self:reuploadAll(touchmenu)
        end,
    }
    rows[#rows + 1] = {
        text = withIcon("\xEF\x83\xA4", _("Status")),
        callback = function()
            self:showStatus()
        end,
        separator = true,
    }
    rows[#rows + 1] = {
        text = withIcon("\xEF\x80\x93", _("Settings")),
        sub_item_table_func = function()
            return self:genSettingsMenu()
        end,
        separator = true,
    }
    rows[#rows + 1] = {
        text = withIcon("\xEE\xA7\xBC", _("About")),
        callback = function()
            self:showAbout()
        end,
    }
    return rows
end

-- Rebuild the book menu's rows in place, the way the Markdown files
-- group does: TouchMenu keeps a reference to the table it is showing,
-- so filling it with the fresh rows swaps the content and leaves the
-- menu where it is. It runs on whatever page of the menu is open, and
-- that matters from Settings: the switches there add or remove rows of
-- the book's own menu, which is read from this very table when the
-- reader taps back to it.
function Tomedown:refreshBookMenu()
    local live = self.book_menu_table
    if not live then
        return
    end
    local fresh = self:genBookMenu()
    for i = #live, 1, -1 do
        live[i] = nil
    end
    for _, item in ipairs(fresh) do
        live[#live + 1] = item
    end
end

function Tomedown:addToMainMenu(menu_items)
    if getSetting("update_check", false) then
        UIManager:scheduleIn(0.1, function()
            Update.checkBackground()
        end)
    end
    self:maybePromptLibraryImport()
    pinToTop("ui/elements/reader_menu_order", "navi")
    pinToTop("ui/elements/filemanager_menu_order", "filemanager_settings")
    -- Every row of the main menu carries a Nerd Font glyph (from
    -- nerdfonts/symbols.ttf, KOReader's own fallback font). Settings
    -- keeps its word plus the icon; inside, group labels and submenu
    -- rows are iconified - plain setting rows stay text-only.
    -- The rows are built on open, not once: the heading row of a book
    -- that keeps a zone only exists while that book is ticked.
    menu_items.tomedown = {
        text = "Tomedown",
        sub_item_table_func = function()
            self.book_menu_table = self:genBookMenu()
            return self.book_menu_table
        end,
    }
end

return Tomedown
