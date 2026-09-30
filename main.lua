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
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
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
local Update = require("tomedown_update")

local SETTINGS_KEY = "tomedown"
local DEFAULT_LOCAL_SUBDIR = "clipboard/tomedown"
local INDEX_FILENAME = "00 - Index.md"
local FILENAME_TEMPLATE = "%A - %T"

-- upload retry: up to 3 attempts, wait doubling
-- each time (2s, 4s), to absorb transient network blips without
-- having to trigger "Reload everything to the cloud" by hand.
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

local MdBook = WidgetContainer:extend{
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

function MdBook:getLocalDir()
    local dir = getSetting("local_dir")
    if dir and dir ~= "" then
        return dir
    end
    return DataStorage:getFullDataDir() .. "/" .. DEFAULT_LOCAL_SUBDIR
end

function MdBook:getRemoteFolder()
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
function MdBook:getServer()
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

function MdBook:hasServer()
    return self:getServer() ~= nil and (self.ui and self.ui.cloudstorage) ~= nil
end

function MdBook:getCurrentFile()
    if self.ui and self.ui.document then
        return self.ui.document.file
    end
    return G_reader_settings:readSetting("lastfile")
end

function MdBook:showProgress(text)
    local info = InfoMessage:new{ text = text }
    UIManager:show(info)
    UIManager:forceRePaint()
    return info
end

-- reading the annotations

function MdBook:listBookFiles()
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
function MdBook:legacyAnnotations(ds)
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
function MdBook:cleanAnnotations(raw)
    local out = {}
    if type(raw) ~= "table" then
        return out
    end
    for __, item in ipairs(raw) do
        if type(item) == "table" and not item.deleted and item.drawer then
            local text = trim(item.text)
            if text then
                local datetime = item.datetime_updated or item.datetime
                out[#out + 1] = {
                    text = text,
                    note = trim(item.note),
                    chapter = trim(item.chapter),
                    page = pageLabel(item),
                    date = render.fmtDateTime(datetime),
                    sort_page = tonumber(item.pageno) or 0,
                    sort_time = tostring(datetime or ""),
                }
            end
        end
    end
    table.sort(out, function(a, b)
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
function MdBook:cleanBookmarks(raw)
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

-- keywords may be a string ("horror, gothic"), a table, or absent
local function parseKeywords(keywords)
    local out = {}
    local function add(v)
        if type(v) == "string" or type(v) == "number" then
            local s = tostring(v):gsub("^%s+", ""):gsub("%s+$", "")
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
function MdBook:fileBase(file, props)
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

function MdBook:buildBook(file, live_annotations)
    if self.book_cache and self.book_cache[file] ~= nil then
        return self.book_cache[file]
    end

    local book
    if BookList.hasBookBeenOpened(file) then
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
                local props = BookInfo.extendProps(ds:readSetting("doc_props"), file)
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

function MdBook:buildBooks(files)
    local books = {}
    for __, file in ipairs(files) do
        local live
        if self.ui and self.ui.document and self.ui.document.file == file
            and self.ui.annotation then
            live = self.ui.annotation.annotations
        end
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

function MdBook:buildIndexEntries(dir, export_records)
    local entries = {}
    for __, file in ipairs(self:listBookFiles()) do
        local book = self:buildBook(file)
        if book and lfs.attributes(dir .. "/" .. book.base .. ".md") then
            local record = export_records[file]
            entries[#entries + 1] = {
                link = book.base,
                title = book.title,
                author = book.author,
                count = book.count,
                date = record and render.fmtDate(record.date) or "",
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
    return entries
end

-- upload to the cloud

function MdBook:cloudProvider(server)
    local cloud = self.ui and self.ui.cloudstorage
    if not (cloud and server and server.type and cloud.providers) then
        return nil
    end
    return cloud.providers[server.type]
end

-- upload through the provider (webdav/dropbox/ftp) instead of via
-- Cloud:uploadFile, which does not exist in every KOReader version.
--
-- Each file is retried up to UPLOAD_MAX_ATTEMPTS times, with an
-- exponential backoff wait (UPLOAD_RETRY_BASE_DELAY * 2^(n-1))
-- between one attempt and the next, before being marked as a
-- permanent failure. It absorbs transient network blips (WiFi reconnecting,
-- slow DNS, etc.) without needing a "Reload everything
-- to the cloud" by hand every time.
function MdBook:uploadPaths(server, paths, callback)
    local provider = self:cloudProvider(server)
    if not (provider and provider.uploadFile and provider.run) then
        if callback then callback(0, #paths, paths) end
        return
    end
    local i, ok_count, fail_count, failed = 0, 0, 0, {}

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
        provider.run(function()
            local ok_call, code = pcall(provider.uploadFile, srv.url or "", path, nil, true)
            local success = ok_call and type(code) == "number" and code >= 200 and code < 300
            if success then
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
function MdBook:markPendingUploads(paths)
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

function MdBook:clearPendingUploads(paths)
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

function MdBook:runExport(files, opts)
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

    for __, file in ipairs(files) do
        local live
        if self.ui and self.ui.document and self.ui.document.file == file
            and self.ui.annotation then
            live = self.ui.annotation.annotations
        end
        local ok, book = pcall(self.buildBook, self, file, live)
        if not ok then
            logger.err("tomedown: cannot read annotations of", file, book)
            errors[#errors + 1] = ffiUtil.basename(tostring(file))
        elseif book then
            local md_path = dir .. "/" .. book.base .. ".md"
            local record = export_records[file]
            if opts.only_updated and record and record.hash == book.hash
                and lfs.attributes(md_path) then
                skipped = skipped + 1
            else
                local md = render.buildBookMd(book, { no_chapter_label = _("No chapter") })
                local written_ok, err = util.writeToFile(md, md_path, true, false, true)
                if written_ok then
                    exported = exported + 1
                    written[#written + 1] = md_path
                    export_records[file] = {
                        hash = book.hash,
                        base = book.base,
                        date = os.date("%Y-%m-%d"),
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
            local index_md = render.buildIndexMd(self:buildIndexEntries(dir, export_records), {
                title = _("Book index"),
                exported = os.date("%Y-%m-%d"),
            })
            if util.writeToFile(index_md, index_path, true, false, true) then
                written[#written + 1] = index_path
            end
        end
    end
    local ms_index = time.to_ms(time.since(t1))

    setSetting("exports", export_records)
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
        self:showResult(exported, skipped, errors, offline_pending)
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
        -- stays open for the whole upload phase, retries included
        -- with backoff: without this the screen stays silent for minutes
        local upload_info = self:showProgress(T(_("Uploading %1 files to the cloud…"), #written))
        self:uploadPaths(server, written, function(ok_count, fail_count, failed)
            UIManager:close(upload_info)
            if #failed > 0 then
                self:markPendingUploads(failed)
            end
            local failed_set = {}
            for __, path in ipairs(failed) do
                failed_set[path] = true
            end
            local ok_paths = {}
            for __, path in ipairs(written) do
                if not failed_set[path] then
                    ok_paths[#ok_paths + 1] = path
                end
            end
            self:clearPendingUploads(ok_paths)
            reportUpload(ok_count, fail_count)
        end)
    end
end

--- The local outcome: a toast right after the export finishes, an
-- InfoMessage (stays on screen) when something went wrong. The cloud
-- reports separately, in reportUpload's own notification.
function MdBook:showResult(exported, skipped, errors, offline_pending)
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
    if #errors > 0 then
        lines[#lines + 1] = _("Errors:") .. "\n" .. table.concat(errors, "\n")
        UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
        return
    end
    UIManager:show(Notification:new{
        text = table.concat(lines, " · "),
        timeout = 3,
    })
end

-- pending uploads: flushed when the connection comes back (NetworkConnected),
-- when KOReader wakes up and at plugin start, so an export made offline finds
-- the network at the next opportunity without any prompt

function MdBook:schedulePendingFlush()
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

function MdBook:flushPendingUploads()
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
    table.sort(paths)
    self._flushing = true
    local upload_info = self:showProgress(T(_("Uploading %1 files to the cloud…"), #paths))
    self:uploadPaths(server, paths, function(ok_count, fail_count, failed)
        UIManager:close(upload_info)
        self._flushing = false
        local failed_set = {}
        for __, path in ipairs(failed) do
            failed_set[path] = true
        end
        local ok_paths = {}
        for __, path in ipairs(paths) do
            if not failed_set[path] then
                ok_paths[#ok_paths + 1] = path
            end
        end
        self:clearPendingUploads(ok_paths)
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

function MdBook:reuploadAll(touchmenu)
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
    if #paths == 0 then
        UIManager:show(Notification:new{
            text = _("Nothing to upload, export something first."),
            timeout = 3,
        })
        return
    end

    table.sort(paths)
    local info = self:showProgress(T(_("Uploading %1 files to the cloud…"), #paths))
    self:uploadPaths(server, paths, function(ok_count, fail_count)
        UIManager:close(info)
        if fail_count > 0 then
            UIManager:show(InfoMessage:new{
                text = T(_("Cloud: %1/%2 files uploaded, %3 errors"), ok_count, #paths, fail_count),
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

function MdBook:chooseCloudFolder(touchmenu)
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

function MdBook:editRemoteFolder(touchmenu)
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

function MdBook:editLocalDir(touchmenu)
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
            if touchmenu and touchmenu.updateItems then
                touchmenu:updateItems()
            end
        end,
    })
end

-- menu

function MdBook:genPickerMenu()
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

--- Label of a group row: a Nerd Font glyph from the symbols font KOReader
-- already ships, two spaces, then the label. The glyph stays outside the
-- translated string, so .po files never see it. The code points are in
-- the Private Use Area on purpose (anything else risks missing glyphs in
-- other fonts) - the same rule Bookshelf's menus follow.
local function withIcon(glyph, text)
    return glyph .. "  " .. text
end

--- Settings: three groups (the structure Bookshelf uses). About lives
-- in the main menu right under Settings. Every setting keeps its own
-- row; the checkable ones keep their keep_menu_open so KOReader
-- refreshes the tick in place.
function MdBook:genSettingsMenu()
    local cloud = {
        {
            text = _("Upload to cloud"),
            enabled_func = function()
                return self:hasServer()
            end,
            checked_func = function()
                return self:hasServer() and getSetting("upload", false)
            end,
            keep_menu_open = true,
            callback = function()
                setSetting("upload", not getSetting("upload", false))
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
            text = T(_("Generate the index %1"), INDEX_FILENAME),
            checked_func = function()
                return getSetting("with_index", true)
            end,
            keep_menu_open = true,
            callback = function()
                setSetting("with_index", not getSetting("with_index", true))
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
            separator = true,
        },
        {
            -- a behaviour toggle, not a file option: kept apart by the
            -- separator, no icon (the inside of Settings stays text-only)
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
    }
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
            text = _("Developer updates"),
            sub_item_table_func = function()
                developer_table = developerItems()
                return developer_table
            end,
        },
    }
    return {
        { text = withIcon("\xEE\xB4\xBE", _("Cloud")), -- cloud-sync
            sub_item_table = cloud },
        { text = withIcon("\xEF\x83\xB6", _("Markdown files")), -- file-text
            sub_item_table = files },
        { text = withIcon("\xEE\xB6\xAE", _("Updates")), -- update
            sub_item_table = updates },
    }
end

--- About: the popup Bookshelf shows - the logo, the installed version,
-- the description from _meta.lua and the tappable GitHub URL, centred
-- on the screen. No buttons; tapping outside the frame (or Back) closes
-- it. The logo lives in assets/ (SVG or PNG) and is only shown when
-- the file is there, so a copy of the plugin without it still shows
-- the rest.
function MdBook:showAbout()
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

    -- Hard-coded English URL; not translatable. Display form drops the
    -- https:// prefix; the full URL with the scheme is what
    -- Device:openLink and the clipboard receive on tap.
    local GITHUB_URL_DISPLAY = "github.com/imanubdesigner/tomedown.koplugin"
    local GITHUB_URL = "https://github.com/imanubdesigner/tomedown.koplugin"

    local Screen = Device.screen
    local Font = require("ui/font")
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
    local function open_github()
        local ok = false
        if Device.openLink then
            local ok_call, ret = pcall(function() return Device:openLink(GITHUB_URL) end)
            if ok_call and ret then
                ok = true
            end
        end
        if not ok and Device.input and Device.input.setClipboardText then
            pcall(function() Device.input.setClipboardText(GITHUB_URL) end)
            UIManager:show(Notification:new{
                text = _("Link copied to clipboard"),
            })
        end
    end
    column[#column + 1] = Button:new{
        text = GITHUB_URL_DISPLAY,
        bordersize = 0,
        padding = 0,
        margin = 0,
        text_font_face = "cfont",
        text_font_size = 14,
        callback = open_github,
    }

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
function MdBook:migrateDefaults()
    local settings = G_reader_settings:readSetting(SETTINGS_KEY)
    if type(settings) == "table" and settings.upload == nil
            and settings.exports ~= nil then
        settings.upload = true
        G_reader_settings:saveSetting(SETTINGS_KEY, settings)
    end
end

function MdBook:init()
    self.ui.menu:registerToMainMenu(self)
    -- ensure the plugin is in the UI event chain (same guard as
    -- AnnotationSync), so onCloseDocument/onSuspend/... reach it
    local found = false
    for _, child in ipairs(self.ui) do
        if child == self then
            found = true
            break
        end
    end
    if not found then
        table.insert(self.ui, self)
    end
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

function MdBook:onCloseDocument()
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

function MdBook:onSuspend()
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

function MdBook:onResume()
    self:schedulePendingFlush()
end

function MdBook:onNetworkConnected()
    self:schedulePendingFlush()
end

-- first-run onboarding: offer to import the whole reading history
-- in one tap. Runs when the menu is first built (KOReader calls
-- addToMainMenu lazily on the first menu open of a session), so the
-- reader is already interacting with the UI. The prompt appears once
-- in a lifetime: both "Export" and "Not now" set the flag.
function MdBook:maybePromptLibraryImport()
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

function MdBook:addToMainMenu(menu_items)
    if getSetting("update_check", false) then
        UIManager:scheduleIn(0.1, function()
            Update.checkBackground()
        end)
    end
    self:maybePromptLibraryImport()
    -- Every row of the main menu carries a Nerd Font glyph (from
    -- nerdfonts/symbols.ttf, KOReader's own fallback font). Settings
    -- keeps its word plus the icon; inside, only the three group
    -- labels are iconified - no glyph is ever added to a submenu.
    menu_items.tomedown = {
        text = "Tomedown",
        sub_item_table = {
            {
                text = withIcon("\xEE\x89\xBC", _("Export current book")),
                enabled_func = function()
                    local file = self:getCurrentFile()
                    return file ~= nil and BookList.hasBookBeenOpened(file)
                end,
                callback = function(touchmenu)
                    local file = self:getCurrentFile()
                    if not file then
                        return
                    end
                    if touchmenu and touchmenu.closeMenu then
                        touchmenu:closeMenu()
                    end
                    self:runExport({ file }, {})
                end,
            },
            {
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
            },
            {
                text = withIcon("\xEE\xB9\x94", _("Choose books…")),
                sub_item_table_func = function()
                    return self:genPickerMenu()
                end,
            },
            {
                text = withIcon("\xEE\xA7\x99", _("Import all books from history")),
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
            },
            {
                text = withIcon("\xEE\xB4\xBE", _("Reload everything to the cloud")),
                enabled_func = function()
                    return self:hasServer()
                end,
                callback = function(touchmenu)
                    self:reuploadAll(touchmenu)
                end,
            },
            {
                text = withIcon("\xEF\x80\x93", _("Settings")),
                sub_item_table_func = function()
                    return self:genSettingsMenu()
                end,
                separator = true,
            },
            {
                text = withIcon("\xEE\xA7\xBC", _("About")),
                callback = function()
                    self:showAbout()
                end,
            },
        },
    }
end

return MdBook
