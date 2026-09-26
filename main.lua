--[[
tomedown.koplugin

Esporta gli evidenziati (e le note) di ogni libro in un file Markdown
per libro, con frontmatter e indice automatico, e li carica su
Koofr (WebDAV) per leggerli poi in Obsidian con Remotely Save.

A differenza di "Export highlights and notes" (che produce un unico file
combinato), qui ogni volume ha il suo `.md`.
]]

local BookInfo = require("apps/filemanager/filemanagerbookinfo")
local BookList = require("ui/widget/booklist")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local ffiUtil = require("ffi/util")
local md5 = require("ffi/sha2").md5
local json = require("json")
local readhistory = require("readhistory")
local lfs = require("libs/libkoreader-lfs")
local T = ffiUtil.template
local _ = require("tomedown_i18n")
local render = require("tomedown_render")

local SETTINGS_KEY = "tomedown"
local DEFAULT_LOCAL_SUBDIR = "clipboard/tomedown"
local INDEX_FILENAME = "00 - Index.md"
local FILENAME_TEMPLATE = "%A - %T"

-- retry upload: fino a 3 tentativi totali, attesa che raddoppia
-- ogni volta (2s, 4s), per assorbire blip di rete transitori senza
-- dover rilanciare "Reload everything to Koofr" a mano.
local UPLOAD_MAX_ATTEMPTS = 3
local UPLOAD_RETRY_BASE_DELAY = 2 -- secondi

-- ha senso ritentare solo i guasti transitori: errori di rete (codice
-- non numerico), risorse temporaneamente indisponibili (5xx), timeout e
-- troppi tentativi dal server. Le 4xx (credenziali errate, cartella
-- mancante) falliscono al primo colpo: ritentarle costa solo attesa.
local function isTransient(code)
    if type(code) ~= "number" then
        return true
    end
    return code >= 500 or code == 408 or code == 429
end

local MdBook = WidgetContainer:extend{
    name = "tomedown",
}

-- impostazioni (tutto in G_reader_settings sotto una sola chiave)

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

-- utilità

local function pageLabel(item)
    local p = item.pageref
    if type(p) == "table" then
        p = nil
    end
    if p == nil or p == "" then
        p = item.pageno
    end
    -- item.page è un xpointer, lo usiamo solo se è un numero di pagina
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

-- server Koofr: prima quello scelto in "Impostazioni", poi in fallback
-- quello già usato da AnnotationSync, così chi ha già configurato Koofr su
-- KOReader non deve rifarlo.
function MdBook:getServer()
    local server = getSetting("server")
    if server and server.type then
        return server
    end
    -- chiave legacy scritta da AnnotationSync (stringa JSON)
    local legacy = G_reader_settings:readSetting("cloud_server_object")
    if type(legacy) == "string" and legacy ~= "" then
        local ok, decoded = pcall(json.decode, legacy)
        if ok and type(decoded) == "table" and decoded.type and decoded.address then
            return decoded
        end
    end
    -- impostazioni correnti di AnnotationSync (tabella "sync_server")
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

-- lettura delle annotazioni

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

-- fallback per i file .sdr scritti da versioni vecchie di KOReader
-- (prima che le annotazioni venissero salvate nella tabella "annotations")
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

-- tiene solo gli evidenziati (drawer), scarta i segnalibri di pagina
-- e gli elementi cancellati, poi li ordina per pagina
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
                    date = render.fmtDate(datetime),
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

local function hashBook(title, author, annotations)
    local parts = {
        "title:" .. tostring(title or ""),
        "author:" .. tostring(author or ""),
        "count:" .. tostring(#annotations),
    }
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
    return md5(table.concat(parts, "\n"))
end

-- nome file identico a quello dell'exporter standard ("%A - %T")
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
            if #annotations > 0 then
                local props = BookInfo.extendProps(ds:readSetting("doc_props"), file)
                local title = props.display_title or file
                local author = props.authors
                local base = self:fileBase(file, props)
                book = {
                    file = file,
                    title = title,
                    author = author,
                    base = base,
                    count = #annotations,
                    annotations = annotations,
                    exported = os.date("%Y-%m-%d"),
                    hash = hashBook(title, author, annotations),
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

-- indice

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

-- upload su Koofr

function MdBook:cloudProvider(server)
    local cloud = self.ui and self.ui.cloudstorage
    if not (cloud and server and server.type and cloud.providers) then
        return nil
    end
    return cloud.providers[server.type]
end

-- upload tramite il provider (webdav/dropbox/ftp) invece che tramite
-- Cloud:uploadFile, che non esiste su tutte le versioni di KOReader.
--
-- Ogni file viene ritentato fino a UPLOAD_MAX_ATTEMPTS volte, con
-- attesa a backoff esponenziale (UPLOAD_RETRY_BASE_DELAY * 2^(n-1))
-- tra un tentativo e il successivo, prima di essere segnato come
-- fallito definitivo. Assorbe i blip di rete transitori (WiFi che si
-- riconnette, DNS lento, ecc.) senza richiedere un "Reload everything
-- to Koofr" manuale ogni volta.
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
        -- i server presi da AnnotationSync hanno "address", non "url"
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

-- esportazione

function MdBook:runExport(files, opts)
    opts = opts or {}
    self.book_cache = {}

    local dir = self:getLocalDir()
    util.makePath(dir)
    local with_index = getSetting("with_index", true)

    local info = self:showProgress(opts.progress_text or _("Export in progress…"))

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

    setSetting("exports", export_records)
    UIManager:close(info)

    local server = self:getServer()
    if getSetting("upload", true) and server and #written > 0 then
        -- resta aperto per tutta la fase di upload, compresi i ritentativi
        -- con backoff: senza questo lo schermo resta muto per minuti
        local upload_info = self:showProgress(T(_("Uploading %1 files to Koofr…"), #written))
        self:uploadPaths(server, written, function(ok_count, fail_count, failed)
            UIManager:close(upload_info)
            self:showResult(exported, skipped, errors, ok_count, fail_count)
        end)
    else
        self:showResult(exported, skipped, errors, nil, nil)
    end
end

function MdBook:showResult(exported, skipped, errors, uploaded, upload_failed)
    local lines = {}
    if exported > 0 then
        lines[#lines + 1] = T(_("%1 files exported"), exported)
    else
        lines[#lines + 1] = _("No files exported")
    end
    if skipped > 0 then
        lines[#lines + 1] = T(_("%1 files unchanged, skipped"), skipped)
    end
    if uploaded then
        if upload_failed > 0 then
            lines[#lines + 1] = T(_("Koofr: %1 uploaded, %2 errors"), uploaded, upload_failed)
        else
            lines[#lines + 1] = T(_("Koofr: %1 files uploaded"), uploaded)
        end
    end
    if #errors > 0 then
        lines[#lines + 1] = _("Errors:") .. "\n" .. table.concat(errors, "\n")
    end

    if #errors > 0 or (uploaded and upload_failed > 0) then
        UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
    else
        UIManager:show(Notification:new{
            text = table.concat(lines, " · "),
            timeout = 3,
        })
    end
end

function MdBook:reuploadAll(touchmenu)
    if touchmenu and touchmenu.closeMenu then
        touchmenu:closeMenu()
    end
    local server = self:getServer()
    if not server then
        UIManager:show(InfoMessage:new{ text = _("Choose a Koofr server in the settings first.") })
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
    local info = self:showProgress(T(_("Uploading %1 files to Koofr…"), #paths))
    self:uploadPaths(server, paths, function(ok_count, fail_count)
        UIManager:close(info)
        if fail_count > 0 then
            UIManager:show(InfoMessage:new{
                text = T(_("Koofr: %1/%2 files uploaded, %3 errors"), ok_count, #paths, fail_count),
            })
        else
            UIManager:show(Notification:new{
                text = T(_("Koofr: %1 files uploaded"), ok_count),
                timeout = 3,
            })
        end
    end)
end

-- impostazioni / scelte

function MdBook:chooseCloudFolder(touchmenu)
    local cloud = self.ui and self.ui.cloudstorage
    if not cloud then
        UIManager:show(InfoMessage:new{
            text = _("Enable the \"Cloud storage\" plugin to upload to Koofr."),
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
        title = _("Remote folder on Koofr"),
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
    local dialog
    dialog = InputDialog:new{
        title = _("Local folder for exports"),
        input = self:getLocalDir(),
        hint = _("path on the Kindle"),
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
                        if value ~= "" then
                            setSetting("local_dir", value)
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
            check_callback_updates_menu = true,
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

function MdBook:genSettingsMenu()
    return {
        {
            text = _("Upload to Koofr"),
            enabled_func = function()
                return self:hasServer()
            end,
            checked_func = function()
                return self:hasServer() and getSetting("upload", true)
            end,
            check_callback_updates_menu = true,
            callback = function()
                setSetting("upload", not getSetting("upload", true))
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
            separator = true,
        },
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
            check_callback_updates_menu = true,
            callback = function()
                setSetting("with_index", not getSetting("with_index", true))
            end,
        },
    }
end

function MdBook:init()
    self.ui.menu:registerToMainMenu(self)
end

function MdBook:addToMainMenu(menu_items)
    menu_items.tomedown = {
        text = "Tomedown",
        sub_item_table = {
            {
                text = _("Export current book"),
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
                text = _("Only updated"),
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
                text = _("Choose books…"),
                sub_item_table_func = function()
                    return self:genPickerMenu()
                end,
            },
            {
                text = _("All books with highlights"),
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
                text = _("Reload everything to Koofr"),
                enabled_func = function()
                    return self:hasServer()
                end,
                callback = function(touchmenu)
                    self:reuploadAll(touchmenu)
                end,
            },
            {
                text = _("Settings"),
                sub_item_table_func = function()
                    return self:genSettingsMenu()
                end,
            },
        },
    }
end

return MdBook
