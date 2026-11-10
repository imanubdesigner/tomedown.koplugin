--[[
tomedown.koplugin

Exports the highlights (and notes) of every book into a Markdown file
per book, with frontmatter and an automatic index, and uploads them to
a cloud (WebDAV, Dropbox, FTP) to read them later in Obsidian or in any
Markdown app.

Unlike "Export highlights and notes" (which produces a single combined
file), here every volume gets its own `.md`.

The plugin class stays here, with the folder and server getters and the
reader events. The menus, the export run and the upload pipeline live
in tomedown_menu.lua, tomedown_export.lua and tomedown_upload.lua.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local time = require("ui/time")
local ffiUtil = require("ffi/util")
local json = require("json")
local T = ffiUtil.template
local _ = require("tomedown_i18n")
local Update = require("tomedown_update")

local shared = require("tomedown_shared")
local metadata = require("tomedown_metadata")
local SETTINGS_KEY = shared.SETTINGS_KEY
local DEFAULT_LOCAL_SUBDIR = shared.DEFAULT_LOCAL_SUBDIR
local getSetting = shared.getSetting
local setSetting = shared.setSetting

local Tomedown = WidgetContainer:extend{
    name = "tomedown",
}

-- The menu, export and upload methods live in their own modules: copy
-- them onto the class here, so the plugin instance keeps the same
-- methods as before.
local function installMethods(target, source)
    for name, fn in pairs(source) do
        if type(fn) == "function" then
            target[name] = fn
        end
    end
end
installMethods(Tomedown, require("tomedown_menu"))
installMethods(Tomedown, require("tomedown_export"))
installMethods(Tomedown, require("tomedown_upload"))

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

function Tomedown:migrateDefaults()
    local settings = G_reader_settings:readSetting(SETTINGS_KEY)
    if type(settings) ~= "table" then
        return
    end
    local changed = false
    if settings.upload == nil and settings.exports ~= nil then
        settings.upload = true
        changed = true
    end
    -- 1.3.0 moved the tags under the book title. An install that
    -- already has an index must rebuild it once, because no book hash
    -- changes when only the table shape does.
    if settings.exports ~= nil and settings.index_layout == nil then
        settings.index_layout = "tags_below"
        settings.index_dirty = true
        changed = true
    end
    if changed then
        G_reader_settings:saveSetting(SETTINGS_KEY, settings)
    end
end

local active_instance

local function registerFileDialogButtons(target)
    if type(target) ~= "table"
            or type(target.addFileDialogButtons) ~= "function" then
        return
    end
    local callback = function(file, is_file)
        if not active_instance then
            return nil
        end
        return active_instance:genFileDialogButtons(file, is_file)
    end
    target:addFileDialogButtons("tomedown", callback)
    local added = target.file_dialog_added_buttons
    local idx = type(added) == "table"
        and type(added.index) == "table"
        and added.index.tomedown
    if idx then
        added[idx] = callback
    end
end

function Tomedown:init()
    active_instance = self
    self.ui.menu:registerToMainMenu(self)
    -- Register on both the current host (when it exposes the file dialog
    -- hook) and the FileManager class: Bookshelf falls back to the class
    -- table while a book is open or hot-parked (FileManager.instance is
    -- nil then), and delegating through active_instance keeps the buttons
    -- bound to the live plugin instance across host switches.
    registerFileDialogButtons(self.ui)
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok_fm and FileManager and FileManager ~= self.ui then
        registerFileDialogButtons(FileManager)
    end
    -- Do NOT insert this instance into self.ui here: KOReader runs init()
    -- inside createPluginInstance and inserts the instance itself right
    -- after, via registerModule (ReaderUI and FileManager both do). An
    -- extra insert left the plugin in the children array twice, so every
    -- event reached it twice: on close two exports ran back to back and
    -- the silent second one (nothing changed) overwrote the recorded
    -- outcome shown by the Status panel.
    -- before anything reads the upload default (the pending flush below)
    self:migrateDefaults()
    -- watch the places where KOReader writes book information: imported
    -- books only, and only while the automatic update is on
    metadata.attach(self)
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

function Tomedown:onAnnotationsModified(items)
    local doc = self.ui and self.ui.document
    if not doc or type(doc.getSelectedWordContext) ~= "function"
            or type(items) ~= "table" then
        return
    end
    for __, item in ipairs(items) do
        if type(item) == "table" and not item.deleted and item.drawer
                and type(item.pos0) == "string" and type(item.pos1) == "string" then
            local ok_c, prev, nxt = pcall(doc.getSelectedWordContext, doc,
                item.text or "", 12, item.pos0, item.pos1, false)
            if ok_c then
                item.tomedown_context_prev = tostring(prev or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
                item.tomedown_context_next = tostring(nxt or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
            end
        end
    end
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
