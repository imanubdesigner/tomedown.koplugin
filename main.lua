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

local shared = require("tomedown_shared")
local SETTINGS_KEY = shared.SETTINGS_KEY
local DEFAULT_LOCAL_SUBDIR = shared.DEFAULT_LOCAL_SUBDIR
local INDEX_FILENAME = shared.INDEX_FILENAME
local FILENAME_TEMPLATE = shared.FILENAME_TEMPLATE
local getSetting = shared.getSetting
local setSetting = shared.setSetting
local getNotesTitle = shared.getNotesTitle
local setBookNotesTitle = shared.setBookNotesTitle
local getBookPreserve = shared.getBookPreserve
local setBookPreserve = shared.setBookPreserve
local getIndexPreserve = shared.getIndexPreserve
local readIfExists = shared.readIfExists
local ownCopy = shared.ownCopy
local isZoned = shared.isZoned
local replaceFile = shared.replaceFile
local normalizeBackups = shared.normalizeBackups
local parkZone = shared.parkZone
local keepSafety = shared.keepSafety

-- upload retry: up to 3 attempts, wait doubling
-- each time (2s, 4s), to absorb transient network blips without
-- having to trigger "Upload all files again" by hand.
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

-- The menu methods live in tomedown_menu.lua: copy them onto the class
-- here, so the plugin instance keeps the same methods as before.
local function installMethods(target, source)
    for name, fn in pairs(source) do
        if type(fn) == "function" then
            target[name] = fn
        end
    end
end
installMethods(Tomedown, require("tomedown_menu"))
installMethods(Tomedown, require("tomedown_export"))



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
-- slow DNS, etc.) without needing an "Upload all files again"
-- by hand every time.
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
-- queued files and "Upload all files again" both run it.
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
--     highlights are still on the device. "Upload all files again"
--     runs this same comparison before it pushes; a reader who
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
    -- what the last export wrote for this path: the proof to tell the
    -- reader's own text from a file this plugin generated
    local function storedDisk(rel)
        if rel == INDEX_FILENAME then
            return getSetting("index_disk")
        end
        local file = bookFor(rel)
        local record = file and getSetting("exports", {})[file]
        return record and record.disk
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
            -- A card that ran the beta.1 may hold its notes in .bak.1
            -- behind a plain .bak: repair the slots before this path
            -- touches them (keepSafety below writes .bak.1).
            normalizeBackups(path)
            local cloud_copy = remote
            local safety = remote
            local call_ok, merged, info
            if not isZoned(local_md) and isZoned(remote) then
                local snapshot = readIfExists(path .. ".bak")
                if isZoned(snapshot) then
                    -- The cloud copy moved on and this device holds the
                    -- parked notes it never got: fold them in instead of
                    -- choosing a side. The union is the whole file
                    -- already, so it is written as it is; the next
                    -- export regenerates its block from the annotations.
                    local union = merge.uniteZones(remote, snapshot)
                    if union then
                        if not ownCopy(storedDisk(rel), local_md) then
                            -- the plain file holds the reader's own text:
                            -- that is the copy to keep, not the cloud one
                            safety = local_md
                        end
                        call_ok, merged, info =
                            true, union, { reason = "merged" }
                    else
                        call_ok, merged, info = false, nil,
                            { reason = "recovery" }
                        logger.warn("tomedown: the parked notes of",
                            rel or path,
                            "cannot be folded into the cloud copy, holding it back")
                    end
                end
            end
            if call_ok == nil then
                -- pcall reports its own success first: merged is the text
                -- only when the call went through
                call_ok, merged, info = pcall(merge.apply, remote, local_md,
                    rel == INDEX_FILENAME and getSetting("index_regions") or nil,
                    -- the zone is named the way the export names it
                    { mode = "preserve", notes_title = zoneTitle(rel) })
            end
            if call_ok and merged
                    and (info.reason == "merged" or info.reason == "format") then
                -- the copy in the cloud is the base the next export
                -- will compare against: keep it whole as .bak before
                -- the folded file replaces the local one. Unless it is
                -- the very copy this plugin uploaded last: nothing of
                -- the reader's can sit in it, and it would only take a
                -- slot from a copy that might hold their notes
                local cloud_base = self:cloudBase(server)
                local ours = cloud_base and cloud_base[rel]
                    and cloud_base[rel] == md5(cloud_copy)
                local kept
                if safety == cloud_copy and ours then
                    kept = true
                else
                    kept = keepSafety(path, safety)
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

--- "Upload all files again": every markdown file and leftover
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
    -- failed earlier) ride along with "Upload all files again"
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
return Tomedown
