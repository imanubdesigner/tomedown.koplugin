--[[
The Tomedown menus.

Everything here is reached from the plugin's main menu: the picker that
chooses books, the Settings groups, the About popup and the per-book
menu with its backup copies. The methods were moved out of main.lua
unchanged; the entry points are the ones main.lua installed on the
plugin class.
]]

local BookList = require("ui/widget/booklist")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Notification = require("ui/widget/notification")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local ffiUtil = require("ffi/util")
local T = ffiUtil.template
local _ = require("tomedown_i18n")
local Update = require("tomedown_update")
local shared = require("tomedown_shared")

local INDEX_FILENAME = shared.INDEX_FILENAME
local getSetting = shared.getSetting
local setSetting = shared.setSetting
local getNotesTitle = shared.getNotesTitle
local setBookNotesTitle = shared.setBookNotesTitle
local getBookPreserve = shared.getBookPreserve
local setBookPreserve = shared.setBookPreserve
local getIndexPreserve = shared.getIndexPreserve
local readIfExists = shared.readIfExists
local isZoned = shared.isZoned

local M = {}

-- settings / choices

function M:chooseCloudFolder(touchmenu)
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

function M:editRemoteFolder(touchmenu)
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

function M:editLocalDir(touchmenu)
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
function M:editNotesTitle(touchmenu, file)
    local dialog
    -- the field shows the heading this file will actually export: the
    -- book's own when it asked for one ("" included, truthy in Lua),
    -- the global one otherwise
    local current = file and getNotesTitle(file)
        or getSetting("notes_title", nil) or _("My notes...")
    dialog = InputDialog:new{
        title = _("Notes heading"),
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

function M:genPickerMenu()
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
-- Dropping the stored hash forces the next "Export new and changed books"
-- to rewrite every book: the render options (covers, callout) are not
-- part of hashBook, so without this a settings toggle would leave the
-- already exported .md files stale until the highlights change.
function M:invalidateExportHashes()
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
-- rewrite that one file at the next "Export new and changed books" (its
-- zone appears or disappears), and must leave every other book's hash
-- alone, so the rest of the library is not exported again for nothing
function M:invalidateExportHash(file)
    local records = getSetting("exports", {})
    local record = records[file]
    if record and record.hash ~= nil then
        record.hash = nil
        setSetting("exports", records)
    end
end

function M:genSettingsMenu()
    -- Files: what is written and where. Static since 1.1: none of its
    -- rows depends on a switch, so the group is the same table every
    -- time it opens.
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
            text = T(_("Create an index note (%1)"), INDEX_FILENAME),
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
            text = _("Export when I close a book"),
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

    -- Cloud: the three rows that speak about the server and the upload.
    -- The row that folds the cloud copy back into the file now lives in
    -- My notes, where the notes are, so this group is static too.
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
                local cloud_ui = self.ui and self.ui.cloudstorage
                local name = cloud_ui and cloud_ui.getServerNameType
                    and cloud_ui:getServerNameType(server) or server.name or "?"
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

    -- My notes: the switch that governs every file, the index's own
    -- switch, the two headings and the merge of the cloud copy. The
    -- rows come and go with the switches, so the group is rebuilt every
    -- time it opens and in place when one of them flips.
    local notes_table
    local buildNotesRows
    local function rebuildNotesRows(touchmenu)
        if not touchmenu or not notes_table
                or touchmenu.item_table ~= notes_table then
            return
        end
        local fresh = buildNotesRows()
        for i = #notes_table, 1, -1 do
            notes_table[i] = nil
        end
        for _, item in ipairs(fresh) do
            notes_table[#notes_table + 1] = item
        end
    end
    buildNotesRows = function()
        local rows = {
            {
                -- what wins when the render meets a file the reader
                -- edited; opt-in since 1.0: off means the tomedown <=
                -- 0.8 behaviour (every export writes the file from
                -- scratch), and every file follows the choice it
                -- stored. On, this switch alone governs every file and
                -- names every zone, and no other row is built to choose
                -- for one file.
                text = _("Keep my notes: all books"),
                checked_func = function()
                    return getSetting("preserve", false)
                end,
                keep_menu_open = true,
                callback = function(touchmenu)
                    setSetting("preserve", not getSetting("preserve", false))
                    -- switching modes must regenerate what the other
                    -- mode left behind: the next export rewrites every
                    -- file
                    self:invalidateExportHashes()
                    -- with the switch on the index rows leave (it covers
                    -- the index too) and the global heading appears
                    rebuildNotesRows(touchmenu)
                end,
            },
        }
        -- The index is a file like the others: since 1.1 it gets its own
        -- switch and the row that names its zone, both only while the
        -- global switch is off (it governs the index too) and an index
        -- is generated at all. Its checked state is the effective one:
        -- the reader's own choice when they made one, the global switch
        -- otherwise.
        if getSetting("with_index", true)
                and not getSetting("preserve", false) then
            rows[#rows + 1] = {
                text = _("Keep my notes: index"),
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
                    -- the heading row below exists only while the index
                    -- keeps a zone to name
                    rebuildNotesRows(touchmenu)
                end,
            }
        end
        -- with the global switch on it names every zone itself
        if getSetting("preserve", false) then
            rows[#rows + 1] = {
                text_func = function()
                    return T(_("Notes heading: %1"), getNotesTitle())
                end,
                callback = function(touchmenu)
                    self:editNotesTitle(touchmenu)
                end,
            }
        end
        if getSetting("with_index", true)
                and not getSetting("preserve", false)
                and getIndexPreserve() then
            rows[#rows + 1] = {
                text_func = function()
                    return T(_("Index notes heading: %1"),
                        getNotesTitle(INDEX_FILENAME))
                end,
                callback = function(touchmenu)
                    self:editNotesTitle(touchmenu, INDEX_FILENAME)
                end,
            }
        end
        -- The cloud copy is folded back into the file before the render,
        -- but only a cloud reader has one and only while Keep my notes
        -- keeps a write zone. It belongs here because it is about the
        -- notes, and it sits last.
        if self:hasServer() and getSetting("upload", false)
                and getSetting("preserve", false) then
            rows[#rows + 1] = {
                text = _("Bring in edits made in Obsidian"),
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

    -- The three rows that speak about the highlights themselves: how a
    -- Special Highlight is marked in the note, and whether every quote
    -- carries its stable block id. Static: no row here appears or
    -- disappears (the marker row is grayed out while every highlight is
    -- a callout, because then there is nothing left to choose).
    local highlights = {
        {
            text = _("Treat every highlight as special"),
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
            text_func = function()
                local labels = {
                    callout = _("Callout"),
                    bold = _("Bold"),
                }
                return T(_("How special highlights look: %1"),
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
            text = _("Add link IDs to highlights"),
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

    -- Beta versions: everything that is not meant for daily use, in its
    -- own submenu. Receive beta versions first; while it is ticked a
    -- beta "Check for beta updates" sits right below it, then a
    -- separator, the way back to stable and the installed version as a
    -- plain grey label. The row list is rebuilt whenever the submenu
    -- opens and in place when the toggle flips, so the beta check
    -- appears at once.
    local beta_table
    local function betaItems()
        local beta_on = getSetting("beta_releases", false)
        local items = {
            {
                text = _("Receive beta versions"),
                checked_func = function()
                    return getSetting("beta_releases", false)
                end,
                keep_menu_open = true,
                callback = function(touch_menu)
                    setSetting("beta_releases",
                        not getSetting("beta_releases", false))
                    Update.clearAvailableCache()
                    -- the submenu that is open IS this table: rebuild it
                    -- in place so the check row shows up or goes away
                    -- without leaving the menu
                    if touch_menu
                            and touch_menu.item_table == beta_table then
                        local fresh = betaItems()
                        for i = #beta_table, 1, -1 do
                            beta_table[i] = nil
                        end
                        for _, item in ipairs(fresh) do
                            beta_table[#beta_table + 1] = item
                        end
                    end
                end,
                separator = not beta_on,
            },
        }
        if beta_on then
            items[#items + 1] = {
                text = _("Check for beta updates"),
                callback = function()
                    Update.check(true)
                end,
                separator = true,
            }
        end
        items[#items + 1] = {
            -- the cartoon bomb (U+ED8F): the reset blows the beta up
            text = withIcon("\xEE\xB6\x8F", _("Go back to the stable version")),
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
            text = withIcon("\xEF\x84\xA6", _("Beta versions")), -- code-fork
            sub_item_table_func = function()
                beta_table = betaItems()
                return beta_table
            end,
        },
    }

    return {
        { text = withIcon("\xEF\x83\xB6", _("Files")), -- file-text
            sub_item_table = files },
        { text = withIcon("\xEE\xB4\xBE", _("Cloud")), -- cloud-sync
            sub_item_table = cloud },
        { text = withIcon("\xEF\x89\x89", _("My notes")), -- sticky-note
            sub_item_table_func = function()
                notes_table = buildNotesRows()
                return notes_table
            end },
        { text = withIcon("\xEE\xB5\x91", _("Highlights for Obsidian")), -- marker
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
function M:showAbout()
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

    -- Logo at the top, centred: PNG first (the shipped artwork), SVG as a
    -- fallback for an older install. alpha=true so a transparent
    -- background stays transparent instead of rendering as opaque black,
    -- is_icon so night mode inverts it with the UI instead of keeping a
    -- black logo on the black background.
    -- Native size from the file's own header (PNG IHDR, or SVG
    -- viewBox/width/height): passing width alone would leave ImageWidget
    -- reserve a square box with empty bands above and below the logo
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
        -- PNG: width and height are the first two 32-bit big-endian
        -- numbers of the IHDR chunk
        if head:sub(1, 4) == "\137PNG" and head:sub(13, 16) == "IHDR" then
            local function be32(at)
                local a, b, c, d = head:byte(at, at + 3)
                if not d then
                    return nil
                end
                return ((a * 256 + b) * 256 + c) * 256 + d
            end
            local pw, ph = be32(17), be32(21)
            if pw and ph and pw > 0 and ph > 0 then
                return pw, ph
            end
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
            for __, name in ipairs({ "logo.png", "logo.svg" }) do
                local path = plugin_dir .. "/assets/" .. name
                if lfs.attributes(path) then
                    local ImageWidget = require("ui/widget/imagewidget")
                    local logo = {
                        file = path,
                        width = math.min(content_w, Screen:scaleBySize(220)),
                        scale_factor = 0,
                        alpha = true,
                        is_icon = true,
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
    column[#column + 1] = VerticalSpan:new{ width = Size.padding.default }
    column[#column + 1] = TextWidget:new{
        text = "© 2026 Manuel B.",
        face = Font:getFace("cfont", 12),
    }
    column[#column + 1] = TextWidget:new{
        text = "GNU Affero General Public License v3.0",
        face = Font:getFace("cfont", 12),
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

-- ---------------------------------------------- copies kept beside a book
--
-- The two copies that can sit beside a book's file (see parkZone and
-- keepSafety above) are shown to the reader inside the book, one at a
-- time, and removed only after a question that says what the copy
-- holds. Nothing here touches the plain file or the zone.

-- The copies that exist for `file`, the parked file first and the
-- safety copy after it: nothing when the book has not been exported
-- yet (its file name is the one recorded).
function M:bookBackups(file)
    local record = getSetting("exports", {})[file]
    if type(record) ~= "table" or not record.base then
        return {}
    end
    local md_path = self:getLocalDir() .. "/" .. record.base .. ".md"
    local copies = {}
    for __, slot in ipairs({ ".bak", ".bak.1" }) do
        local path = md_path .. slot
        local attr = lfs.attributes(path)
        if attr and attr.mode == "file" then
            copies[#copies + 1] = {
                path = path,
                slot = slot,
                md_path = md_path,
                zoned = isZoned(readIfExists(path)),
                size = attr.size or 0,
                modified = attr.modification or 0,
            }
        end
    end
    return copies
end

local function backupLabel(copy)
    if copy.slot == ".bak.1" then
        return _("Safety copy")
    elseif copy.zoned then
        return _("Notes set aside")
    end
    return _("Older copy")
end

local function backupWhat(copy)
    if copy.slot == ".bak.1" then
        return _("Text of yours that a rewrite was about to replace and that does not come back by itself.")
    elseif copy.zoned then
        return _("The file as it was when you turned Keep my notes off. It comes back when you turn it on again.")
    end
    return _("A copy kept by an earlier version.")
end

function M:askDeleteBackup(copy)
    local text = T(_("%1\n\n%2\n\nSaved %3 (%4).\n\nDelete this copy? It cannot be undone."),
        backupLabel(copy), backupWhat(copy),
        os.date("%Y-%m-%d %H:%M", copy.modified),
        T(_("%1 KB"), math.max(1, math.floor(copy.size / 1024 + 0.5))))
    -- a parked file is the only place the notes are while the book's own
    -- file has no zone: say so before it goes
    if copy.slot == ".bak" and copy.zoned
            and not isZoned(readIfExists(copy.md_path)) then
        text = text .. "\n\n" .. _("The file has no write zone right now: deleting this copy deletes those notes for good.")
    end
    -- deferred so the box lands after the submenu has closed
    UIManager:scheduleIn(0.1, function()
        UIManager:show(ConfirmBox:new{
            text = text,
            ok_text = _("Delete"),
            cancel_text = _("Keep"),
            cancel_callback = function() end,
            ok_callback = function()
                if os.remove(copy.path) then
                    UIManager:show(InfoMessage:new{
                        text = _("Copy deleted."), timeout = 2 })
                else
                    UIManager:show(InfoMessage:new{
                        text = _("The copy could not be deleted.") })
                end
                -- the Current book submenu is built again when it opens,
                -- so the row and the list are fresh by then
            end,
        })
    end)
end

function M:genBackupsMenu(file)
    local items = {}
    for __, copy in ipairs(self:bookBackups(file)) do
        items[#items + 1] = {
            text = backupLabel(copy),
            mandatory = os.date("%Y-%m-%d", copy.modified),
            callback = function()
                self:askDeleteBackup(copy)
            end,
        }
    end
    if #items == 0 then
        items[1] = {
            text = _("No backup copies for this book"),
            enabled_func = function() return false end,
        }
    end
    return items
end

-- The main Tomedown menu. Its rows are fixed: everything that needs an
-- open book lives in the Current book submenu, built by
-- genCurrentBookMenu below. In the file manager there is no document,
-- so both Export this book and Current book are left out.
function M:genBookMenu()
    local rows = {}
    -- This row needs a book open, which means the document itself: in
    -- the file manager KOReader hands the plugin the FileManager as ui,
    -- which carries no document, and "lastfile" would then name the
    -- last book read over a book nobody has open.
    if self.ui and self.ui.document then
        rows[#rows + 1] = {
            text = withIcon("\xEE\x89\xBC", _("Export this book")),
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
        text = withIcon("\xEE\xA4\xB5", _("Export new and changed books")),
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
    rows[#rows + 1] = {
        text = withIcon("\xEE\xA7\x99", _("Repair all files")),
        enabled_func = function()
            return #self:listBookFiles() > 0
        end,
        callback = function(touchmenu)
            if touchmenu and touchmenu.closeMenu then
                touchmenu:closeMenu()
            end
            self:runExport(self:listBookFiles(), {})
        end,
    }
    rows[#rows + 1] = {
        text = withIcon("\xEE\xB9\x94", _("Choose books…")),
        sub_item_table_func = function()
            return self:genPickerMenu()
        end,
        separator = true,
    }
    -- The per book rows, grouped in a submenu of their own instead of
    -- spread through the main menu. ReaderUI passes the document, so
    -- only there is the row built.
    if self.ui and self.ui.document then
        rows[#rows + 1] = {
            text = withIcon("\xEF\x81\x80", _("Current book")),
            sub_item_table_func = function()
                return self:genCurrentBookMenu()
            end,
            separator = true,
        }
    end
    rows[#rows + 1] = {
        text = withIcon("\xEE\xB4\xBE", _("Upload all files again")),
        enabled_func = function()
            return self:hasServer()
        end,
        callback = function(touchmenu)
            self:reuploadAll(touchmenu)
        end,
    }
    rows[#rows + 1] = {
        text = withIcon("\xEF\x83\xA4", _("Last export")),
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
    }
    rows[#rows + 1] = {
        text = withIcon("\xEE\xA7\xBC", _("About")),
        callback = function()
            self:showAbout()
        end,
    }
    return rows
end

-- The rows that name the open book. The switch is always there: with
-- the global one in Settings on it shows off, with the reason on the
-- right, because it is the reason the submenu exists and the stored
-- per book choice has to stay reachable when the global switch goes
-- off again (it is never touched meanwhile). The heading and the
-- copies exist only when they have something to name.
function M:genCurrentBookMenu()
    local file = self:getCurrentFile()
    local rows = {}
    if not (self.ui and self.ui.document) or not file then
        return rows
    end
    rows[#rows + 1] = {
        text = withIcon("\xEF\x81\x80", _("Keep my notes in this book")),
        enabled_func = function()
            return not getSetting("preserve", false)
        end,
        checked_func = function()
            return not getSetting("preserve", false)
                and getBookPreserve(file)
        end,
        mandatory_func = function()
            if getSetting("preserve", false) then
                return _("On for all books")
            end
        end,
        keep_menu_open = true,
        callback = function(touchmenu)
            local current = self:getCurrentFile()
            if not current or getSetting("preserve", false) then
                return
            end
            if getBookPreserve(current) then
                -- the file on disk holds a zone the reader may have
                -- written in, and turning the switch off hands the
                -- render straight back to the writer: the file is
                -- replaced with no merge and no .bak. So it is asked
                -- first, deferred so the box lands on top of the menu
                UIManager:scheduleIn(0.1, function()
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Turn off Keep my notes for %1? Your notes will not be lost. A .bak copy is created."), ffiUtil.basename(current)),
                        ok_text = _("Turn off"),
                        cancel_text = _("Keep it on"),
                        -- nothing has been touched yet, so closing
                        -- is all cancel has to do (the box says so
                        -- itself, and the work waits for OK)
                        cancel_callback = function() end,
                        ok_callback = function()
                            setBookPreserve(current, false)
                            -- the stored hash goes with it: the file
                            -- was written the other way round
                            self:invalidateExportHash(current)
                            -- and the file is rewritten plain right
                            -- away instead of waiting for the next
                            -- export: runExport keeps the zoned copy
                            -- as .bak before the plain one lands
                            self:runExport({ current }, {})
                            -- the heading row below exists only while
                            -- this book keeps a zone to name, and the
                            -- menu sat open behind the box: redraw it,
                            -- tick included
                            self:refreshCurrentBookMenu(touchmenu)
                        end,
                    })
                end)
                return
            end
            setBookPreserve(current, true)
            -- the file on disk was written the other way round: the
            -- next export has to rewrite it, so its stored hash goes,
            -- and only its hash
            self:invalidateExportHash(current)
            -- the heading row below exists only while this book keeps a
            -- zone to name
            self:refreshCurrentBookMenu(touchmenu)
        end,
    }
    if not getSetting("preserve", false) and getBookPreserve(file) then
        rows[#rows + 1] = {
            text_func = function()
                return T(_("Notes heading: %1"), getNotesTitle(file))
            end,
            callback = function(touchmenu)
                self:editNotesTitle(touchmenu, file)
            end,
        }
    end
    -- the copies kept beside this book's file, when it has any: shown
    -- one by one and deleted only after a question
    if #self:bookBackups(file) > 0 then
        rows[#rows + 1] = {
            text = withIcon("\xEF\x83\x87", _("Backup copies…")),
            sub_item_table_func = function()
                return self:genBackupsMenu(file)
            end,
        }
    end
    return rows
end

-- Rebuild the Current book submenu in place after its switch changes
-- which rows it has: TouchMenu keeps a reference to the table it is
-- showing, so filling it with the fresh rows swaps the content and
-- leaves the menu where it is, the tick included.
function M:refreshCurrentBookMenu(touchmenu)
    if not touchmenu or not touchmenu.item_table then
        return
    end
    local live = touchmenu.item_table
    local fresh = self:genCurrentBookMenu()
    for i = #live, 1, -1 do
        live[i] = nil
    end
    for _, item in ipairs(fresh) do
        live[#live + 1] = item
    end
    if touchmenu.updateItems then
        touchmenu:updateItems()
    end
end

function M:addToMainMenu(menu_items)
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
    -- The main rows are fixed; the Current book submenu is built on
    -- open, so its per book rows read the book that is open right now.
    menu_items.tomedown = {
        text = "Tomedown",
        sub_item_table_func = function()
            return self:genBookMenu()
        end,
    }
end


return M
