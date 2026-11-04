--[[
Reading the books and writing their Markdown files.

The data model built from KOReader's annotations and the export run
that renders, merges and writes the files. Everything was moved out of
main.lua unchanged; the upload methods it calls (fetchRemote,
markPendingUploads, uploadPaths, clearPendingUploads, cloudBase) and
the folder/server getters stay on the same plugin class.
]]

local BookInfo = require("apps/filemanager/filemanagerbookinfo")
local BookList = require("ui/widget/booklist")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")
local util = require("util")
local ffiUtil = require("ffi/util")
local md5 = require("ffi/sha2").md5
local readhistory = require("readhistory")
local lfs = require("libs/libkoreader-lfs")
local T = ffiUtil.template
local _ = require("tomedown_i18n")
local render = require("tomedown_render")
local merge = require("tomedown_merge")
local Cover = require("tomedown_cover")
local shared = require("tomedown_shared")
local metadata = require("tomedown_metadata")

local INDEX_FILENAME = shared.INDEX_FILENAME
local FILENAME_TEMPLATE = shared.FILENAME_TEMPLATE
local getSetting = shared.getSetting
local setSetting = shared.setSetting
local getNotesTitle = shared.getNotesTitle
local getBookPreserve = shared.getBookPreserve
local getBookExclusion = shared.getBookExclusion
local mergeKnownTags = shared.mergeKnownTags
local getIndexPreserve = shared.getIndexPreserve
local readIfExists = shared.readIfExists
local ownCopy = shared.ownCopy
local isZoned = shared.isZoned
local normalizeBackups = shared.normalizeBackups
local parkZone = shared.parkZone
local keepSafety = shared.keepSafety

local M = {}

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

function M:listBookFiles()
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
function M:legacyAnnotations(ds)
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
function M:cleanAnnotations(raw)
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
function M:cleanBookmarks(raw)
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

local function bookinfoMeta(fields, tags)
    if not fields then
        return nil
    end
    local parts = {
        tostring(fields.rating or ""),
        tostring(fields.review or ""),
        tostring(fields.published or ""),
        tostring(fields.date_started or ""),
        tostring(fields.date_finished or ""),
        table.concat(fields.collections or {}, "\30"),
        -- the shared keyword list belongs here too: clearing every tag
        -- has to change the hash even when the managed ledger was empty
        table.concat(tags or {}, "\30"),
    }
    return table.concat(parts, "\31")
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
function M:fileBase(file, props)
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
function M:ensureCover(file, base, dir)
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
function M:openReader(file)
    if self.ui and self.ui.document and self.ui.document.file == file then
        return self.ui
    end
    return nil
end

function M:buildBook(file, live_annotations)
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
                -- tags chosen from the book's own menu; nil means the
                -- book never chose, an empty list means it cleared them.
                -- The stored list is sanitized again: an older build let
                -- a number alone through, and filtering it here keeps it
                -- out of the hash too, so the next export rewrites the
                -- old file instead of taking it for unchanged.
                --
                -- An imported book uses the shared keyword list instead:
                -- KOReader, Bookshelf and Tomedown all read and write
                -- the same custom_props.keywords, so a tag removed in
                -- either place stays removed. The ledger is always on
                -- for these books, an empty list included, because the
                -- empty ledger is what tells the merge to drop them.
                local imported = shared.getBookImported(file)
                local removing = imported and shared.getBookInfoRemoval(file)
                local tags, tags_managed
                if imported then
                    tags = metadata.tags(file, props)
                    tags_managed = true
                else
                    local stored_tags = shared.getBookTags(file)
                    tags = stored_tags and render.parseTagList(
                        table.concat(stored_tags, ", ")) or nil
                    tags_managed = tags ~= nil
                end
                local bookinfo
                if imported and not removing then
                    bookinfo = metadata.collect(file, status,
                        ds:readSetting("summary"), props)
                end
                local meta_parts = {
                    tostring(series or ""),
                    tostring(series_index or ""),
                    tostring(language or ""),
                    tostring(pages or ""),
                    tostring(status or ""),
                    tostring(progress or ""),
                    table.concat(keywords, "\31"),
                }
                -- only a book that actually carries tags changes its
                -- hash: an upgrade must not rewrite the whole library,
                -- and an explicit clear still differs from the tags it
                -- replaces, so the next export removes them
                if tags_managed and #tags > 0 then
                    meta_parts[#meta_parts + 1] = "booktags:"
                        .. table.concat(tags, "\31")
                end
                -- the imported fields join the hash only for imported
                -- books: a normal book keeps the 1.2.0 fingerprint, so
                -- installing 1.3.0 rewrites nothing
                local bookinfo_meta = imported
                    and (bookinfoMeta(bookinfo, tags) or "removed") or nil
                if bookinfo_meta then
                    meta_parts[#meta_parts + 1] = "bookinfo:" .. bookinfo_meta
                end
                local meta = table.concat(meta_parts, "\31")
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
                    last_read_sort = lr,
                    keywords = keywords,
                    tags = tags or {},
                    tags_managed = tags_managed,
                    imported = imported,
                    published = bookinfo and bookinfo.published,
                    rating = bookinfo and bookinfo.rating,
                    review = bookinfo and bookinfo.review,
                    date_started = bookinfo and bookinfo.date_started,
                    date_finished = bookinfo and bookinfo.date_finished,
                    collections = bookinfo and bookinfo.collections,
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

function M:buildBooks(files)
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

function M:buildIndexEntries(dir, export_records)
    local entries = {}
    local new_covers = {}
    local hidden = 0
    local with_covers = getSetting("covers", false)
    for __, file in ipairs(self:listBookFiles()) do
        -- same live data the export above writes into the book file:
        -- the .sdr still holds the previous flush while the book is open
        local open = self:openReader(file)
        local live = open and open.annotation and open.annotation.annotations
        local book = self:buildBook(file, live)
        if book and lfs.attributes(dir .. "/" .. book.base .. ".md") then
            if getBookExclusion(file) then
                -- the file stays where it is: only the index forgets it
                hidden = hidden + 1
            else
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
                    tags = book.tags or {},
                    status = book.status,
                    count = book.count,
                    special = special,
                    progress = book.progress,
                    last_read = book.last_read and render.fmtDate(book.last_read)
                        or "",
                    last_read_sort = book.last_read_sort,
                    cover = has_cover and cover_rel or nil,
                }
            end
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
    return entries, new_covers, hidden
end


function M:runExport(files, opts)
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
    if not silent and opts.auto ~= "close" and opts.auto ~= "bookinfo" then
        -- auto close: one book straight from the .sdr, the export is
        -- milliseconds - the widget would only flash one more e-ink
        -- refresh between the close and the result notification
        info = self:showProgress(opts.progress_text or _("Export in progress…"))
    end

    local export_records = getSetting("exports", {})
    local written, errors = {}, {}
    local skipped, exported, excluded = 0, 0, 0
    -- tags met in this run, one count per book: the suggestion cache is
    -- merged once at the end, so a full export writes the setting once
    local known_counts = {}
    local function rememberTags(book)
        local seen = {}
        local function add(tag)
            tag = render.sanitizeTag(tag)
            if tag == "" then
                return
            end
            local key = tag:lower()
            if seen[key] then
                return
            end
            seen[key] = true
            local entry = known_counts[key]
            if entry then
                entry.count = entry.count + 1
            else
                known_counts[key] = { name = tag, count = 1 }
            end
        end
        for __, tag in ipairs(book.keywords or {}) do
            add(tag)
        end
        for __, tag in ipairs(book.tags or {}) do
            add(tag)
        end
    end
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
            return local_old, false
        end
        local remote, status = self:fetchRemote(pull_server, md_path, dir)
        if status == "failed" then
            logger.warn("tomedown:", rel,
                "(cloud copy not fetched, holding the upload back)")
            unread[md_path] = true
        end
        if not remote or remote == local_old then
            return local_old, false
        end
        local stored = self:cloudBase(pull_server)
        if stored and stored[rel] and md5(remote) == stored[rel] then
            -- still the copy we uploaded: ours is the newer file
            return local_old, false
        end
        logger.info("tomedown:", rel,
            "was edited elsewhere: folding the cloud copy into the merge")
        return remote, true
    end

    for __, file in ipairs(files) do
        local open = self:openReader(file)
        local live = open and open.annotation and open.annotation.annotations
        local ok, book = pcall(self.buildBook, self, file, live)
        if not ok then
            logger.err("tomedown: cannot read annotations of", file, book)
            errors[#errors + 1] = ffiUtil.basename(tostring(file))
        elseif book then
            local exclusion = getBookExclusion(file)
            if exclusion == "none" and not opts.force then
                -- "Do not export" wins over every automatic run; the
                -- manual "Export this book" asks for this one on purpose
                excluded = excluded + 1
            else
                rememberTags(book)
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
                    local old, from_cloud = mergeBase(book.base .. ".md", md_path,
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
                    -- The cloud copy moved on and has a zone while this
                    -- device holds a parked .bak with notes it never got (a
                    -- second Tomedown with cloud merge off, a sync conflict):
                    -- taking one of the two would lose the other. The copy
                    -- the rewrite replaces is kept as the safety copy, and
                    -- the cloud text becomes the base with the parked notes
                    -- folded in.
                    local recovered = false
                    if old and preserve and from_cloud and isZoned(old) then
                        local disk_now = readIfExists(md_path)
                        local snapshot = readIfExists(md_path .. ".bak")
                        if (not disk_now or not isZoned(disk_now))
                                and isZoned(snapshot) then
                            -- keep what the rewrite replaces: the plain file
                            -- when it holds the reader's own text, the cloud
                            -- copy otherwise
                            local safety = old
                            if disk_now
                                    and not ownCopy(record and record.disk, disk_now) then
                                safety = disk_now
                            end
                            local union = merge.uniteZones(old, snapshot)
                            if union and keepSafety(md_path, safety) then
                                old = union
                                recovered = true
                                backups = backups + 1
                            else
                                hold = hold_msg
                            end
                        end
                    end
                    if old then
                        local merged, info = merge.apply(old, md,
                            record and record.regions,
                            { mode = mode, notes_title = getNotesTitle(file),
                              bookinfo = book.imported })
                        content = merged
                        if restored or recovered then
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
                        if shared.getBookInfoRemoval(file) then
                            -- the fields are gone from the note: the book
                            -- stops being managed, tags stay editable in
                            -- the shared keyword list
                            metadata.forget(file)
                        elseif book.imported then
                            -- what the next automatic update compares to
                            metadata.saveSnapshot(file)
                        end
                    else
                        errors[#errors + 1] = book.base .. ": " .. tostring(err)
                    end
                end
            end -- exclusion
        end
    end
    mergeKnownTags(known_counts)
    local ms_books = time.to_ms(time.since(t0))
    local t1 = time.now()

    if with_index then
        local index_path = dir .. "/" .. INDEX_FILENAME
        -- index_dirty: the order changed (or the file is missing) but
        -- no book did, so the index alone has to be rebuilt
        if exported > 0 or not lfs.attributes(index_path)
                or getSetting("index_dirty", false) then
            -- the index keeps its zone when its own switch says so, or
            -- when the global switch covers it: no book choice turns it
            -- on behind the reader's back any more
            local index_preserve = getIndexPreserve()
            -- what the last export left in the file, to tell our own
            -- output from anything the reader wrote in it
            local index_disk = getSetting("index_disk")
            local entries, new_covers, hidden = self:buildIndexEntries(dir, export_records)
            local index_md = render.buildIndexMd(entries, {
                title = _("Book index"),
                exported = os.date("%Y-%m-%d"),
                show_covers = getSetting("covers", false),
                notes_title = index_title,
                markers = index_preserve,
                index_order = getSetting("index_order", "author"),
                hidden_books = hidden,
                reading_now = getSetting("reading_now", true),
            })
            -- the index is a region too: the reader may have annotated it
            local content = index_md
            local old_index, index_from_cloud = mergeBase(INDEX_FILENAME,
                index_path, readIfExists(index_path), index_preserve)
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
            -- the same recovery as the books: the cloud copy is the base
            -- and the parked index goes with it, not under it
            local recovered_index = false
            if old_index and index_preserve and index_from_cloud
                    and isZoned(old_index) then
                local disk_now = readIfExists(index_path)
                local snapshot = readIfExists(index_path .. ".bak")
                if (not disk_now or not isZoned(disk_now))
                        and isZoned(snapshot) then
                    local safety = old_index
                    if disk_now and not ownCopy(index_disk, disk_now) then
                        safety = disk_now
                    end
                    local union = merge.uniteZones(old_index, snapshot)
                    if union and keepSafety(index_path, safety) then
                        old_index = union
                        recovered_index = true
                        backups = backups + 1
                    else
                        hold_index = hold_msg
                    end
                end
            end
            if old_index then
                local merged, info = merge.apply(old_index, index_md,
                    getSetting("index_regions"),
                    { mode = index_preserve and "preserve" or "overwrite",
                      notes_title = index_title })
                content = merged
                if restored_index or recovered_index then
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
                -- the order the index was built with is now on disk
                setSetting("index_dirty", false)
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
        -- book info update: silent when it worked, the error window
        -- below is the only thing the reader ever sees from it
        if opts.auto == "bookinfo" and #errors == 0 then
            return
        end
        self:showResult(exported, skipped, errors, offline_pending,
            opts.auto, backups, excluded)
    end
    local function reportUpload(uploaded, upload_failed)
        if upload_failed > 0 then
            UIManager:show(InfoMessage:new{
                text = T(_("Cloud: %1 uploaded, %2 errors"), uploaded, upload_failed),
            })
            return
        end
        if opts.auto == "bookinfo" then
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
    if auto == "bookinfo" then
        return _("Book info")
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
function M:showResult(exported, skipped, errors, offline_pending,
        auto, backups, excluded)
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
    if excluded and excluded > 0 then
        lines[#lines + 1] = T(_("%1 files excluded from the export"), excluded)
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

return M
