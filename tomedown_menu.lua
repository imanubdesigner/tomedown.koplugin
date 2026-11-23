--[[
The Tomedown menus.

Everything here is reached from the plugin's main menu: the picker that
chooses books, the Settings groups, the About popup and the per-book
menu with its backup copies. The methods were moved out of main.lua
unchanged; the entry points are the ones main.lua installed on the
plugin class.
]]

local BookList = require("ui/widget/booklist")
local ButtonDialog = require("ui/widget/buttondialog")
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
local render = require("tomedown_render")
local shared = require("tomedown_shared")
local metadata = require("tomedown_metadata")
local pubdate = require("tomedown_pubdate")

local INDEX_FILENAME = shared.INDEX_FILENAME
local DIGEST_FILENAME = shared.DIGEST_FILENAME
local getSetting = shared.getSetting
local setSetting = shared.setSetting
local getNotesTitle = shared.getNotesTitle
local setBookNotesTitle = shared.setBookNotesTitle
local getBookPreserve = shared.getBookPreserve
local setBookPreserve = shared.setBookPreserve
local getBookTags = shared.getBookTags
local setBookTags = shared.setBookTags
local getBookImported = shared.getBookImported
local getAutoBookInfo = shared.getAutoBookInfo
local setAutoBookInfo = shared.setAutoBookInfo
local getBookOverride = shared.getBookOverride
local setBookOverride = shared.setBookOverride
local getBookExclusion = shared.getBookExclusion
local setBookExclusion = shared.setBookExclusion
local getIndexPreserve = shared.getIndexPreserve
local getFilenameTemplate = shared.getFilenameTemplate
local setFilenameTemplate = shared.setFilenameTemplate
local getCoversFolder = shared.getCoversFolder
local setCoversFolder = shared.setCoversFolder
local getFolderLayout = shared.getFolderLayout
local setFolderLayout = shared.setFolderLayout
local getIndexLinks = shared.getIndexLinks
local setIndexLinks = shared.setIndexLinks
local getNoteStyle = shared.getNoteStyle
local setNoteStyle = shared.setNoteStyle
local BACKUP_SLOTS = shared.BACKUP_SLOTS
local DEFAULT_FRONTMATTER_ORDER = shared.DEFAULT_FRONTMATTER_ORDER
local isFrontmatterKeyEnabled = shared.isFrontmatterKeyEnabled
local setFrontmatterKeyEnabled = shared.setFrontmatterKeyEnabled
local getFrontmatterOrder = shared.getFrontmatterOrder
local setFrontmatterOrder = shared.setFrontmatterOrder
local getCustomFrontmatterEnabled = shared.getCustomFrontmatterEnabled
local setCustomFrontmatterEnabled = shared.setCustomFrontmatterEnabled
local getRawCustomFrontmatterFields = shared.getRawCustomFrontmatterFields
local getDefinedCustomFrontmatterFields = shared.getDefinedCustomFrontmatterFields
local getCustomFrontmatterFields = shared.getCustomFrontmatterFields
local setCustomFrontmatterFields = shared.setCustomFrontmatterFields
local serializeCustomFields = shared.serializeCustomFields
local getFrontmatterEnabled = shared.getFrontmatterEnabled
local setFrontmatterEnabled = shared.setFrontmatterEnabled
local getBookCovers = shared.getBookCovers
local getIncludeBookmarks = shared.getIncludeBookmarks
local getHighlightDetails = shared.getHighlightDetails
local setHighlightDetails = shared.setHighlightDetails
local getChapterHeadings = shared.getChapterHeadings
local setChapterHeadings = shared.setChapterHeadings
local getHighlightContext = shared.getHighlightContext
local setHighlightContext = shared.setHighlightContext
local getExportFormat = shared.getExportFormat
local setExportFormat = shared.setExportFormat
local getTopbarIcon = shared.getTopbarIcon
local setTopbarIcon = shared.setTopbarIcon
local getBookStyleOverride = shared.getBookStyleOverride
local setBookStyleOverride = shared.setBookStyleOverride
local hasBookStyleOverrides = shared.hasBookStyleOverrides
local clearBookStyleOverrides = shared.clearBookStyleOverrides
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

-- Tags for the open book, chosen where the book is read. The list is
-- stored per book file and reaches the frontmatter at the next export,
-- together with ebook, highlights and the book's own keywords. A book
-- that never chose keeps no entry at all; an empty list is stored only
-- when the reader clears a list that existed, because that is the
-- signal the merge needs to drop the tags this menu used to manage
-- while leaving the tags written by hand alone.
function M:saveBookTags(file, tags)
    local function same(a, b)
        if not a or #a ~= #b then
            return false
        end
        for i = 1, #b do
            if tostring(a[i]):lower() ~= b[i]:lower() then
                return false
            end
        end
        return true
    end
    if getBookImported(file) then
        -- the shared keyword list is the source of truth for an imported
        -- book: KOReader, Bookshelf and Tomedown all read and write it,
        -- so a tag removed here cannot come back from another copy
        if same(metadata.tags(file), tags) then
            return false
        end
        if not metadata.writeKeywords(file, tags) then
            UIManager:show(InfoMessage:new{
                text = _("Could not write the tags. Book information was left as it was."),
            })
            return false
        end
        for __, tag in ipairs(tags or {}) do
            shared.allowKnownTag(tag)
        end
        self:invalidateExportHash(file)
        return true
    end
    local stored = getBookTags(file)
    -- an untouched empty field on a book that never chose says
    -- nothing: it must not store an empty choice (which would start
    -- managing its tags)
    if stored == nil and #tags == 0 then
        return false
    end
    if same(stored, tags) then
        return false
    end
    setBookTags(file, tags)
    for __, tag in ipairs(tags or {}) do
        shared.allowKnownTag(tag)
    end
    -- this book's file carries the old tags: the next export rewrites
    -- it, and only it
    self:invalidateExportHash(file)
    return true
end

local function currentBookTags(file)
    if getBookImported(file) then
        return metadata.tags(file)
    end
    return render.parseTagList(
        table.concat(getBookTags(file) or {}, ", "))
end

-- Suggested tags, most used first. The cache filled during export holds
-- the books' own keywords; the per-book choices and the tags selected
-- here are folded in too, so a tag that only ever came from the menu is
-- still offered. Returns a list of { tag, count }.
function M:tagSuggestions(file, limit)
    local scores = {}
    local function add(tag, count)
        tag = render.sanitizeTag(tag)
        if tag == "" then
            return
        end
        local key = tag:lower()
        local entry = scores[key]
        if not entry then
            entry = { tag = tag, count = 0 }
            scores[key] = entry
        end
        count = tonumber(count) or 0
        if count > entry.count then
            entry.count = count
        end
    end
    for key, entry in pairs(shared.getKnownTags()) do
        if type(entry) == "table" then
            add(entry.name or key, entry.count)
        end
    end
    -- count how many books chose each tag from the menu, one per book
    for __, tags in pairs(getSetting("book_tags", {})) do
        local seen = {}
        for ___, tag in ipairs(tags or {}) do
            tag = render.sanitizeTag(tag)
            local key = tag:lower()
            if tag ~= "" and not seen[key] then
                seen[key] = true
                add(tag, 0)
                scores[key].menu_count = (scores[key].menu_count or 0) + 1
            end
        end
    end
    for key, entry in pairs(scores) do
        if entry.menu_count and entry.menu_count > entry.count then
            entry.count = entry.menu_count
        end
    end
    for __, tag in ipairs(currentBookTags(file)) do
        add(tag, 0)
    end
    local list = {}
    for __, entry in pairs(scores) do
        list[#list + 1] = { tag = entry.tag, count = entry.count }
    end
    table.sort(list, function(a, b)
        if a.count ~= b.count then
            return a.count > b.count
        end
        return a.tag:lower() < b.tag:lower()
    end)
    if limit and #list > limit then
        local kept = {}
        for i = 1, limit do
            kept[i] = list[i]
        end
        return kept
    end
    return list
end

-- Free text, for a tag nobody has used yet.
function M:editBookTagsText(touchmenu, file)
    if not file then
        return
    end
    local dialog
    -- invalid tags stored by an older build (a number alone, say) are
    -- not shown: the field starts on what Obsidian can actually use
    dialog = InputDialog:new{
        title = _("Tags for this book"),
        input = table.concat(currentBookTags(file), ", "),
        hint = _("separate tags with commas; applied at the next export"),
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
                        local tags, rejected = render.parseTagList(
                            dialog:getInputText() or "")
                        self:saveBookTags(file, tags)
                        UIManager:close(dialog)
                        if touchmenu and touchmenu.updateItems then
                            touchmenu:updateItems()
                        end
                        if #rejected > 0 then
                            UIManager:show(Notification:new{
                                text = T(
                                    _("Tags made only of numbers are ignored: %1"),
                                    table.concat(rejected, ", ")),
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

-- The tags of one book: the ones already used elsewhere (a tap toggles
-- them) plus the free-text field and the way to clear everything. The
-- dialog rebuilds after a toggle so every label shows the new state.
function M:editBookTags(touchmenu, file)
    if not file then
        return
    end
    local selected = currentBookTags(file)
    local selected_by_key = {}
    for __, tag in ipairs(selected) do
        selected_by_key[tag:lower()] = true
    end
    local shown = self:tagSuggestions(file, 12)
    local in_list = {}
    for __, entry in ipairs(shown) do
        in_list[entry.tag:lower()] = true
    end
    -- the tags already on this book stay reachable even when their count
    -- is low and the list is capped
    for __, tag in ipairs(selected) do
        if not in_list[tag:lower()] then
            shown[#shown + 1] = { tag = tag, count = 0 }
            in_list[tag:lower()] = true
        end
    end
    local dialog
    local buttons = {}
    local row = {}
    local function toggle(tag)
        local now, seen = {}, {}
        for __, current in ipairs(currentBookTags(file)) do
            if current:lower() ~= tag:lower() and not seen[current:lower()] then
                seen[current:lower()] = true
                now[#now + 1] = current
            end
        end
        if not selected_by_key[tag:lower()] then
            now[#now + 1] = tag
        end
        self:saveBookTags(file, now)
        UIManager:close(dialog)
        self:editBookTags(touchmenu, file)
    end
    for __, entry in ipairs(shown) do
        local checked = selected_by_key[entry.tag:lower()]
        row[#row + 1] = {
            text = (checked and "✓ " or "") .. entry.tag,
            callback = function() toggle(entry.tag) end,
        }
        if #row == 2 then
            buttons[#buttons + 1] = row
            row = {}
        end
    end
    if #row > 0 then
        buttons[#buttons + 1] = row
    end
    buttons[#buttons + 1] = {
        {
            text = _("Other tags…"),
            callback = function()
                UIManager:close(dialog)
                self:editBookTagsText(touchmenu, file)
            end,
        },
    }
    if #selected > 0 then
        buttons[#buttons + 1] = {
            {
                text = _("Clear all tags"),
                callback = function()
                    self:saveBookTags(file, {})
                    UIManager:close(dialog)
                    self:editBookTags(touchmenu, file)
                end,
            },
        }
    end
    buttons[#buttons + 1] = {
        {
            text = _("Delete tags…"),
            callback = function()
                UIManager:close(dialog)
                self:showTagManager(function()
                    self:editBookTags(touchmenu, file)
                end)
            end,
        },
    }
    buttons[#buttons + 1] = {
        {
            text = _("Close"),
            id = "close",
            callback = function()
                UIManager:close(dialog)
                if touchmenu and touchmenu.updateItems then
                    touchmenu:updateItems()
                end
            end,
        },
    }
    dialog = ButtonDialog:new{
        title = _("Tags for this book"),
        buttons = buttons,
    }
    UIManager:show(dialog)
    return dialog
end

-- The tags that appear in the tag menu: the suggestion cache, the
-- per-book choices from the menu and the shared keyword lists of
-- imported books. Each entry carries the number of books that currently
-- assign the tag (0 when it lives only in the suggestion cache).
function M:managedTags()
    local scores = {}
    local function add(tag, file)
        tag = render.sanitizeTag(tag)
        if tag == "" then
            return
        end
        local key = tag:lower()
        local entry = scores[key]
        if not entry then
            entry = { tag = tag, books = {} }
            scores[key] = entry
        end
        if file and not entry.books[file] then
            entry.books[file] = true
            entry.count = (entry.count or 0) + 1
        end
    end
    for key, entry in pairs(shared.getKnownTags()) do
        if type(entry) == "table" then
            add(entry.name or key, nil)
        end
    end
    for file, tags in pairs(getSetting("book_tags", {})) do
        if type(tags) == "table" then
            for __, tag in ipairs(tags) do
                add(tag, file)
            end
        end
    end
    for file in pairs(getSetting("bookinfo_imported", {})) do
        if getBookImported(file) then
            for __, tag in ipairs(metadata.tags(file)) do
                add(tag, file)
            end
        end
    end
    local list = {}
    for __, entry in pairs(scores) do
        list[#list + 1] = { tag = entry.tag, count = entry.count or 0 }
    end
    table.sort(list, function(a, b)
        return a.tag:lower() < b.tag:lower()
    end)
    return list
end

-- Delete one managed tag everywhere. An empty list is kept on purpose:
-- it is the signal the export needs to drop the old tags from the note,
-- where a missing entry would mean "this book never chose". Returns the
-- imported books whose keywords could not be written.
function M:deleteManagedTag(tag)
    tag = render.sanitizeTag(tag)
    if tag == "" then
        return {}
    end
    local key = tag:lower()
    local affected, failed = {}, {}
    local all = getSetting("book_tags", {})
    for file, tags in pairs(all) do
        if type(tags) == "table" then
            local kept, changed = {}, false
            for __, current in ipairs(tags) do
                if render.sanitizeTag(current):lower() == key then
                    changed = true
                else
                    kept[#kept + 1] = current
                end
            end
            if changed then
                all[file] = kept
                affected[file] = true
            end
        end
    end
    setSetting("book_tags", all)
    for file in pairs(getSetting("bookinfo_imported", {})) do
        if getBookImported(file) then
            local tags = metadata.tags(file)
            local kept, changed = {}, false
            for __, current in ipairs(tags) do
                if render.sanitizeTag(current):lower() == key then
                    changed = true
                else
                    kept[#kept + 1] = current
                end
            end
            if changed then
                if metadata.writeKeywords(file, kept) then
                    affected[file] = true
                else
                    failed[#failed + 1] = file
                end
            end
        end
    end
    shared.forgetKnownTag(tag)
    for file in pairs(affected) do
        self:invalidateExportHash(file)
    end
    setSetting("index_dirty", true)
    return failed
end

-- The list behind "Delete tags…". Two buttons per row, the number of
-- books in parentheses when the tag is assigned; a tap asks first, then
-- deletes it from every managed list and from the suggestion cache. The
-- dialog rebuilds after each deletion, so the list shrinks under the
-- reader's eyes. `quiet` skips the empty-state message when the manager
-- is reopened after the last deletion.
function M:showTagManager(on_close, quiet)
    local tags = self:managedTags()
    if #tags == 0 then
        if not quiet then
            UIManager:show(InfoMessage:new{
                text = _("No tags to delete."),
            })
        end
        if on_close then
            on_close()
        end
        return
    end
    local dialog
    local buttons = {}
    local row = {}
    for __, entry in ipairs(tags) do
        local label = entry.count > 0
            and (entry.tag .. " (" .. tostring(entry.count) .. ")")
            or entry.tag
        row[#row + 1] = {
            text = label,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = T(_("Delete #%1 from every book? It leaves the notes at the next export; tags written by hand stay."), entry.tag),
                    ok_text = _("Delete"),
                    cancel_text = _("Cancel"),
                    ok_callback = function()
                        local failed = self:deleteManagedTag(entry.tag)
                        UIManager:close(dialog)
                        if #failed > 0 then
                            UIManager:show(InfoMessage:new{
                                text = _("Some books could not be updated: the tag is still in their keywords."),
                            })
                        end
                        self:showTagManager(on_close, true)
                    end,
                })
            end,
        }
        if #row == 2 then
            buttons[#buttons + 1] = row
            row = {}
        end
    end
    if #row > 0 then
        buttons[#buttons + 1] = row
    end
    buttons[#buttons + 1] = {
        {
            text = _("Close"),
            id = "close",
            callback = function()
                UIManager:close(dialog)
                if on_close then
                    on_close()
                end
            end,
        },
    }
    dialog = ButtonDialog:new{
        title = _("Delete a tag from every book"),
        buttons = buttons,
    }
    UIManager:show(dialog)
    return dialog
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
    self.book_cache = {}
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
    if self.book_cache and file then
        self.book_cache[file] = nil
    end
    local records = getSetting("exports", {})
    local record = records[file]
    if record and record.hash ~= nil then
        record.hash = nil
        setSetting("exports", records)
    end
end

-- The order of the "My books" table in the index. Changing it rewrites
-- no book: index_dirty tells the next export to rebuild the index alone,
-- even when every book would otherwise be skipped.
local function setIndexOrder(order)
    if getSetting("index_order", "author") == order then
        return
    end
    setSetting("index_order", order)
    setSetting("index_dirty", true)
end

-- The shape of the index table. Like the order, it changes no book:
-- the next export rebuilds the index alone.
local function setIndexLayout(layout)
    if getSetting("index_layout", "tags_below") == layout then
        return
    end
    setSetting("index_layout", layout)
    setSetting("index_dirty", true)
end

local function setIndexLinksFormat(fmt)
    if getIndexLinks() == fmt then
        return
    end
    setIndexLinks(fmt)
    setSetting("index_dirty", true)
end

function M:editCustomFilenameTemplate(touchmenu)
    local dialog
    dialog = InputDialog:new{
        title = _("File name template"),
        input = getFilenameTemplate(),
        hint = _("%A author, %T title, %S series, %i series index"),
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
                        setFilenameTemplate(value)
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
    return dialog
end

function M:editCoversFolder(touchmenu)
    local dialog
    dialog = InputDialog:new{
        title = _("Covers folder name"),
        input = getCoversFolder(),
        hint = _("e.g. covers, _covers, assets"),
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
                        local old = getCoversFolder()
                        setCoversFolder(value)
                        local new_folder = getCoversFolder()
                        if new_folder ~= old then
                            local Cover = require("tomedown_cover")
                            Cover.migrateFolder(self:getLocalDir(), old, new_folder)
                            self:invalidateExportHashes()
                            setSetting("index_dirty", true)
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
    return dialog
end

function M:editDrawingsFolder(touchmenu)
    local dialog
    dialog = InputDialog:new{
        title = _("Drawings folder name"),
        input = shared.getDrawingsFolder(),
        hint = _("e.g. drawings, attachments, assets"),
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
                        local old = shared.getDrawingsFolder()
                        shared.setDrawingsFolder(value)
                        local new_folder = shared.getDrawingsFolder()
                        if new_folder ~= old then
                            local Handwritten = require("tomedown_handwritten")
                            Handwritten.migrateFolder(self:getLocalDir(), old, new_folder)
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
    return dialog
end

function M:editFrontmatterOrder(touchmenu, file)
    local current_order = getFrontmatterOrder(file) or DEFAULT_FRONTMATTER_ORDER
    local dialog
    dialog = InputDialog:new{
        title = _("Frontmatter key order"),
        input = table.concat(current_order, ", "),
        hint = file and _("comma-separated keys; leave empty to follow global order")
            or _("comma-separated keys; leave empty for default order"),
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
                        setFrontmatterOrder(value, file)
                        if file then
                            self:invalidateExportHash(file)
                        else
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
    return dialog
end

function M:editCustomFrontmatterFields(touchmenu, file)
    local current_fields = getRawCustomFrontmatterFields(file)
    local initial_text = current_fields and serializeCustomFields(current_fields) or ""
    local dialog
    dialog = InputDialog:new{
        title = _("Custom frontmatter fields"),
        input = initial_text,
        hint = file and _("key: value (one per line) for this book")
            or _("key: value (one per line); leave empty for none"),
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
                        setCustomFrontmatterFields(value, file)
                        if file then
                            self:invalidateExportHash(file)
                        else
                            self:invalidateExportHashes()
                        end
                        UIManager:close(dialog)
                        self:refreshFrontmatterFieldsMenu(touchmenu, file)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    return dialog
end

function M:genFrontmatterFieldsMenu(file, live_ref)
    local rows = live_ref or {}
    for i = #rows, 1, -1 do
        rows[i] = nil
    end

    local fm_defs = {
        { key = "cover",      text = _("Book cover (cover)") },
        { key = "series",     text = _("Series (series, series_index)") },
        { key = "language",   text = _("Language (language)") },
        { key = "pages",      text = _("Page count (pages)") },
        { key = "exported",   text = _("Export date (exported)") },
        { key = "highlights", text = _("Highlight count (highlights)") },
        { key = "special",    text = _("Special highlight count (special)") },
        { key = "status",     text = _("Reading status (status)") },
        { key = "progress",   text = _("Reading progress (progress)") },
    }

    if file then
        rows[#rows + 1] = {
            text = _("Follow global setting"),
            radio = true,
            keep_menu_open = true,
            separator = true,
            checked_func = function()
                return getBookStyleOverride(file, "fm_hidden") == nil
                    and getBookStyleOverride(file, "fm_custom_enabled") == nil
                    and getBookStyleOverride(file, "fm_custom_fields") == nil
                    and getBookStyleOverride(file, "fm_order") == nil
            end,
            callback = function(touchmenu)
                setBookStyleOverride(file, "fm_hidden", nil)
                setBookStyleOverride(file, "fm_custom_enabled", nil)
                setBookStyleOverride(file, "fm_custom_fields", nil)
                setBookStyleOverride(file, "fm_order", nil)
                self:invalidateExportHash(file)
                self:refreshFrontmatterFieldsMenu(touchmenu or { item_table = rows }, file)
            end,
        }
    else
        rows[#rows + 1] = {
            key = "fm_enabled",
            text = _("Include YAML frontmatter"),
            separator = true,
            checked_func = function()
                return getFrontmatterEnabled()
            end,
            keep_menu_open = true,
            callback = function()
                setFrontmatterEnabled(not getFrontmatterEnabled())
                self:invalidateExportHashes()
            end,
        }
    end

    local defined_custom = getDefinedCustomFrontmatterFields(file) or {}
    local global_custom_in_book = {}
    local book_custom_in_book = {}
    if file then
        for __, cf in ipairs(defined_custom) do
            if cf.scope == "book" then
                book_custom_in_book[#book_custom_in_book + 1] = cf
            else
                global_custom_in_book[#global_custom_in_book + 1] = cf
            end
        end
    end

    for idx, def in ipairs(fm_defs) do
        local k = def.key
        local is_last_std = (idx == #fm_defs) and (#global_custom_in_book == 0)
        rows[#rows + 1] = {
            key = k,
            text = def.text,
            separator = is_last_std or nil,
            enabled_func = not file and function()
                return getFrontmatterEnabled()
            end or nil,
            checked_func = function()
                return isFrontmatterKeyEnabled(k, file)
            end,
            keep_menu_open = true,
            callback = function()
                setFrontmatterKeyEnabled(k, not isFrontmatterKeyEnabled(k, file), file)
                if file then
                    self:invalidateExportHash(file)
                else
                    self:invalidateExportHashes()
                end
            end,
        }
    end

    -- In Current Book, global custom keys appear right in the field list
    -- so the user can uncheck any global custom key for this book.
    if file and #global_custom_in_book > 0 then
        for idx, cf in ipairs(global_custom_in_book) do
            local ck = cf.key
            local label = (cf.val and cf.val ~= "") and (ck .. ": " .. cf.val) or ck
            rows[#rows + 1] = {
                key = ck:lower(),
                text = label,
                separator = (idx == #global_custom_in_book) or nil,
                checked_func = function()
                    return isFrontmatterKeyEnabled(ck, file)
                end,
                keep_menu_open = true,
                callback = function()
                    setFrontmatterKeyEnabled(ck, not isFrontmatterKeyEnabled(ck, file), file)
                    self:invalidateExportHash(file)
                end,
            }
        end
    end

    local custom_on = getCustomFrontmatterEnabled(file)
    rows[#rows + 1] = {
        key = "custom",
        text = _("Custom fields"),
        separator = not custom_on or nil,
        enabled_func = not file and function()
            return getFrontmatterEnabled()
        end or nil,
        checked_func = function()
            return getCustomFrontmatterEnabled(file)
        end,
        keep_menu_open = true,
        callback = function(touchmenu)
            setCustomFrontmatterEnabled(not getCustomFrontmatterEnabled(file), file)
            if file then
                self:invalidateExportHash(file)
            else
                self:invalidateExportHashes()
            end
            self:refreshFrontmatterFieldsMenu(touchmenu or { item_table = rows }, file)
        end,
    }

    if custom_on then
        local own_custom = file and book_custom_in_book or defined_custom
        for __, cf in ipairs(own_custom) do
            local ck = cf.key
            local label = (cf.val and cf.val ~= "") and (ck .. ": " .. cf.val) or ck
            rows[#rows + 1] = {
                key = ck:lower(),
                text = label,
                enabled_func = not file and function()
                    return getFrontmatterEnabled()
                end or nil,
                checked_func = function()
                    return isFrontmatterKeyEnabled(ck, file)
                end,
                keep_menu_open = true,
                callback = function()
                    setFrontmatterKeyEnabled(ck, not isFrontmatterKeyEnabled(ck, file), file)
                    if file then
                        self:invalidateExportHash(file)
                    else
                        self:invalidateExportHashes()
                    end
                end,
            }
        end
        rows[#rows + 1] = {
            key = "edit_custom",
            text = _("Custom frontmatter fields…"),
            separator = true,
            enabled_func = not file and function()
                return getFrontmatterEnabled()
            end or nil,
            callback = function(touchmenu)
                return self:editCustomFrontmatterFields(touchmenu or { item_table = rows }, file)
            end,
        }
    end

    rows[#rows + 1] = {
        key = "fm_order",
        text = _("Frontmatter key order…"),
        enabled_func = not file and function()
            return getFrontmatterEnabled()
        end or nil,
        callback = function(touchmenu)
            return self:editFrontmatterOrder(touchmenu, file)
        end,
    }

    return rows
end

function M:refreshFrontmatterFieldsMenu(touchmenu, file)
    if not touchmenu or not touchmenu.item_table then
        return
    end
    self:genFrontmatterFieldsMenu(file, touchmenu.item_table)
    if touchmenu.updateItems then
        touchmenu:updateItems()
    end
end

function M:renameBookToTemplate(file, touchmenu)
    if not file then
        return false
    end
    local records = getSetting("exports", {})
    local record = records[file]
    if type(record) ~= "table" or not record.base then
        return false
    end
    local old_base = record.base
    record.base = nil
    record.hash = nil
    setSetting("exports", records)
    setSetting("index_dirty", true)
    self.book_cache = {}
    local book = self:buildBook(file)
    if book and book.base and book.base ~= old_base then
        local dir = self:getLocalDir()
        local old_md = dir .. "/" .. old_base .. ".md"
        local new_md = dir .. "/" .. book.base .. ".md"
        local new_dir = new_md:match("^(.*)/[^/]+$")
        if new_dir and new_dir ~= dir then
            local util = require("util")
            util.makePath(new_dir)
        end
        if lfs.attributes(old_md, "mode") == "file"
                and not lfs.attributes(new_md, "mode") then
            os.rename(old_md, new_md)
            for __, slot in ipairs(BACKUP_SLOTS) do
                if lfs.attributes(old_md .. slot, "mode") == "file" then
                    os.rename(old_md .. slot, new_md .. slot)
                end
            end
        end
    end
    self:runExport({ file }, { force = true })
    if touchmenu and touchmenu.updateItems then
        touchmenu:updateItems()
    end
    return true
end

-- Where the book goes. The file already written is never deleted: the
-- state decides what the next exports do, and the index alone is told
-- to rebuild because no book file has to change.
local function setBookExclusionState(file, value)
    if getBookExclusion(file) == value then
        return false
    end
    setBookExclusion(file, value)
    setSetting("index_dirty", true)
    return true
end

function M:bookVisibilityLabel(file)
    local state = getBookExclusion(file)
    if state == "index" then
        return T(_("Book visibility: %1"), _("Hidden from index"))
    elseif state == "none" then
        return T(_("Book visibility: %1"), _("Not exported"))
    end
    return T(_("Book visibility: %1"), _("Normal"))
end

function M:genBookVisibilityMenu(file)
    return {
        {
            text = _("Export and show in the index"),
            radio = true,
            keep_menu_open = true,
            checked_func = function()
                return getBookExclusion(file) == nil
            end,
            callback = function(touchmenu)
                if setBookExclusionState(file, nil) and touchmenu and touchmenu.updateItems then
                    touchmenu:updateItems()
                end
            end,
        },
        {
            text = _("Export, but hide from the index"),
            radio = true,
            keep_menu_open = true,
            checked_func = function()
                return getBookExclusion(file) == "index"
            end,
            callback = function(touchmenu)
                if setBookExclusionState(file, "index") and touchmenu and touchmenu.updateItems then
                    touchmenu:updateItems()
                end
            end,
        },
        {
            text = _("Do not export"),
            radio = true,
            keep_menu_open = true,
            checked_func = function()
                return getBookExclusion(file) == "none"
            end,
            callback = function(touchmenu)
                if setBookExclusionState(file, "none") and touchmenu and touchmenu.updateItems then
                    touchmenu:updateItems()
                end
            end,
        },
    }
end

function M:editBookVisibility(file, touchmenu)
    if not file then
        return
    end
    local dialog
    local current = getBookExclusion(file)
    local function label(value, text)
        return (current == value and "✓ " or "") .. text
    end
    local function choose(value)
        setBookExclusionState(file, value)
        UIManager:close(dialog)
        if touchmenu and touchmenu.updateItems then
            touchmenu:updateItems()
        end
    end
    dialog = ButtonDialog:new{
        title = _("Book visibility"),
        buttons = {
            {
                {
                    text = label(nil, _("Export and show in the index")),
                    callback = function() choose(nil) end,
                },
            },
            {
                {
                    text = label("index", _("Export, but hide from the index")),
                    callback = function() choose("index") end,
                },
            },
            {
                {
                    text = label("none", _("Do not export")),
                    callback = function() choose("none") end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
            },
        },
    }
    UIManager:show(dialog)
    return dialog
end

-- ------------------------------------------------ imported book information

local BOOKINFO_DATE_LABELS = {
    published = _("Published"),
    date_started = _("Started reading"),
    date_finished = _("Finished reading"),
}

local BOOKINFO_DATE_RESET = {
    published = _("Use the book's publication date"),
    date_started = _("Use the automatic start date"),
    date_finished = _("Use the automatic finish date"),
}

--- The status BookList knows for a closed book. `reading` is KOReader's
-- default for an opened book that never chose another one.
function M:bookInfoStatus(file)
    local info = BookList.getBookInfo(file)
    local status = info and info.status
    if status == "reading" or status == "abandoned" or status == "complete" then
        return status
    end
    return "reading"
end

function M:bookInfoStatusLabel(file)
    local labels = {
        reading = _("Reading"),
        complete = _("Complete"),
        abandoned = _("Abandoned"),
    }
    return labels[self:bookInfoStatus(file)] or labels.reading
end

--- Write the note of one book now. Used by an explicit Tomedown edit:
-- with the automatic update off the change only invalidates the stored
-- hash, exactly as a tag or date edit from KOReader does.
function M:afterBookInfoEdit(file, touchmenu)
    self:invalidateExportHash(file)
    if getAutoBookInfo() then
        self:runExport({ file }, { auto = "bookinfo" })
    else
        UIManager:show(Notification:new{
            text = _("Saved. It will be written at the next export."),
            timeout = 3,
        })
    end
    if touchmenu and touchmenu.updateItems then
        touchmenu:updateItems()
    end
end

--- Mark a book as imported and write its note at once. The import is
-- explicit: the caller asked for this one book.
function M:importBookInfo(file, touchmenu)
    if not file or getBookImported(file) then
        return false
    end
    if not BookList.hasBookBeenOpened(file) then
        UIManager:show(InfoMessage:new{
            text = _("KOReader has not opened this book yet."),
        })
        return false
    end
    if not metadata.import(file) then
        return false
    end
    self:invalidateExportHash(file)
    self:runExport({ file }, { force = true })
    self:refreshBookInfoMenu(touchmenu, file)
    return true
end

function M:confirmImportBookInfo(file, touchmenu)
    if not file or getBookImported(file) then
        return
    end
    local title = ffiUtil.basename(file)
    UIManager:show(ConfirmBox:new{
        text = T(_("Import the rating, review, publication date, reading dates and collections of %1 into its note? Your notes are kept."), title),
        ok_text = _("Import"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            self:importBookInfo(file, touchmenu)
        end,
    })
end

--- Remove the imported fields from the note, then stop managing the
-- book. The note itself and its tags are never deleted.
function M:removeBookInfo(file, touchmenu)
    if not file or not getBookImported(file) then
        return false
    end
    local book = self:buildBook(file)
    local md_path = book and (self:getLocalDir() .. "/" .. book.base .. ".md")
    if not book or not md_path or not lfs.attributes(md_path, "mode") then
        -- nothing on disk to clean: just stop managing the book
        metadata.forget(file)
        self:refreshBookInfoMenu(touchmenu, file)
        return true
    end
    shared.setBookInfoRemoval(file, true)
    self:invalidateExportHash(file)
    -- runExport deletes the fields through the bookinfo ownership and
    -- clears the flag only after the file was written
    self:runExport({ file }, { force = true })
    local removed = not getBookImported(file)
    if not removed then
        -- the write failed: keep the book managed, the .bak and the
        -- error window say why
        shared.setBookInfoRemoval(file, false)
    end
    self:refreshBookInfoMenu(touchmenu, file)
    return removed
end

function M:confirmRemoveBookInfo(file, touchmenu)
    if not file or not getBookImported(file) then
        return
    end
    local title = ffiUtil.basename(file)
    UIManager:show(ConfirmBox:new{
        text = T(_("Remove rating, review, dates and collections from the note of %1? The note and its tags stay. Tomedown stops updating this book."), title),
        ok_text = _("Remove"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            self:removeBookInfo(file, touchmenu)
        end,
    })
end

--- Label of one imported date: the value and whether it is fixed by
-- the reader or comes from the book, KOReader or the statistics.
function M:bookInfoDateLabel(file, field)
    local label = BOOKINFO_DATE_LABELS[field]
    local status = self:bookInfoStatus(file)
    local value = metadata.effectiveDate(file, field, status)
    if not value then
        return T(_("%1: not available"), label)
    end
    if getBookOverride(file, field) then
        return T(_("%1: %2 (fixed)"), label, value)
    end
    return T(_("%1: %2"), label, value)
end

function M:editBookInfoDate(file, field, touchmenu)
    if not file or not BOOKINFO_DATE_LABELS[field] then
        return
    end
    local override = getBookOverride(file, field)
    local automatic = metadata.autoDate(file, field,
        self:bookInfoStatus(file))
    local dialog
    dialog = InputDialog:new{
        title = T(_("%1: date"), BOOKINFO_DATE_LABELS[field]),
        input = override or automatic or "",
        hint = _("YYYY-MM-DD (or YYYY); leave empty for the automatic date"),
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
                        local text = dialog:getInputText() or ""
                        text = text:gsub("^%s+", ""):gsub("%s+$", "")
                        local date
                        if text ~= "" then
                            date = pubdate.parseDate(text)
                            if not date then
                                UIManager:show(Notification:new{
                                    text = _("That is not a date: use YYYY, YYYY-MM or YYYY-MM-DD."),
                                    timeout = 3,
                                })
                                return
                            end
                        end
                        setBookOverride(file, field, date)
                        UIManager:close(dialog)
                        self:afterBookInfoEdit(file, touchmenu)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    return dialog
end

function M:bookInfoDateMenu(file)
    local rows = {}
    for __, field in ipairs({ "published", "date_started", "date_finished" }) do
        rows[#rows + 1] = {
            text_func = function()
                return self:bookInfoDateLabel(file, field)
            end,
            callback = function(touchmenu)
                self:editBookInfoDate(file, field, touchmenu)
            end,
        }
        if getBookOverride(file, field) then
            rows[#rows + 1] = {
                text = BOOKINFO_DATE_RESET[field],
                callback = function(touchmenu)
                    setBookOverride(file, field, nil)
                    self:afterBookInfoEdit(file, touchmenu)
                end,
            }
        end
    end
    return rows
end

--- Rating, review and status are edited with KOReader's own panel: it
-- already writes summary.rating, summary.note and summary.status, and
-- the sidecar hook turns that write into an automatic export.
function M:openBookStatusEditor(file)
    local status_ui = self.ui and self.ui.status
    if self.ui and self.ui.document and self.ui.document.file == file
            and status_ui and status_ui.onShowBookStatus then
        status_ui:onShowBookStatus()
        return true
    end
    UIManager:show(InfoMessage:new{
        text = _("Open the book to edit rating, review and status with KOReader's own panel."),
    })
    return false
end

function M:bookInfoRatingLabel(file)
    local rating = tonumber(metadata.summary(file).rating)
    if rating and rating > 0 then
        return T(_("Rating: %1/5"), rating)
    end
    return _("Rating: not set")
end

function M:bookInfoReviewLabel(file)
    local note = metadata.summary(file).note
    if type(note) == "string" and note ~= "" then
        note = note:gsub("%s+", " ")
        if #note > 40 then
            note = note:sub(1, 40) .. "…"
        end
        return T(_("Review: %1"), note)
    end
    return _("Review: not set")
end

function M:bookInfoStatusRowLabel(file)
    return T(_("Status: %1"), self:bookInfoStatusLabel(file))
end

function M:genSettingsMenu()
    -- Group 1: Export (format, markdown style, folders, frontmatter, auto-export, digest, backups).
    local files_table
    local buildFilesRows
    local function rebuildFilesRows(touchmenu)
        if not files_table then
            return
        end
        local fresh = buildFilesRows()
        for i = #files_table, 1, -1 do
            files_table[i] = nil
        end
        for _, item in ipairs(fresh) do
            files_table[#files_table + 1] = item
        end
        if touchmenu and touchmenu.item_table == files_table and touchmenu.updateItems then
            touchmenu:updateItems()
        end
    end
    local filenames_folders_table = {
        {
            text_func = function()
                local tpl = getFilenameTemplate()
                local labels = {
                    ["%A - %T"] = _("Author - Title"),
                    ["%T (%A)"] = _("Title (Author)"),
                    ["%T"] = _("Title only"),
                }
                return T(_("File name template: %1"), labels[tpl] or tpl)
            end,
            sub_item_table = {
                {
                    text = _("Author - Title"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getFilenameTemplate() == "%A - %T"
                    end,
                    callback = function()
                        setFilenameTemplate("%A - %T")
                    end,
                },
                {
                    text = _("Title (Author)"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getFilenameTemplate() == "%T (%A)"
                    end,
                    callback = function()
                        setFilenameTemplate("%T (%A)")
                    end,
                },
                {
                    text = _("Title only"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getFilenameTemplate() == "%T"
                    end,
                    callback = function()
                        setFilenameTemplate("%T")
                    end,
                },
                {
                    text = _("Custom template…"),
                    callback = function(touchmenu)
                        self:editCustomFilenameTemplate(touchmenu)
                    end,
                },
            },
        },
        {
            text_func = function()
                local labels = {
                    flat = _("Single folder"),
                    author = _("By author"),
                    series = _("By series"),
                    status = _("By reading status"),
                }
                local current = getFolderLayout()
                return T(_("Folder organization: %1"),
                    labels[current] or labels.flat)
            end,
            sub_item_table = {
                {
                    text = _("Single folder"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getFolderLayout() == "flat"
                    end,
                    callback = function()
                        if getFolderLayout() ~= "flat" then
                            setFolderLayout("flat")
                            self:invalidateExportHashes()
                        end
                    end,
                },
                {
                    text = _("By author"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getFolderLayout() == "author"
                    end,
                    callback = function()
                        if getFolderLayout() ~= "author" then
                            setFolderLayout("author")
                            self:invalidateExportHashes()
                        end
                    end,
                },
                {
                    text = _("By series"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getFolderLayout() == "series"
                    end,
                    callback = function()
                        if getFolderLayout() ~= "series" then
                            setFolderLayout("series")
                            self:invalidateExportHashes()
                        end
                    end,
                },
                {
                    text = _("By reading status"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getFolderLayout() == "status"
                    end,
                    callback = function()
                        if getFolderLayout() ~= "status" then
                            setFolderLayout("status")
                            self:invalidateExportHashes()
                        end
                    end,
                },
            },
        },
        {
            text_func = function()
                return T(_("Covers folder: %1"), getCoversFolder())
            end,
            enabled_func = function()
                return getSetting("covers", false)
            end,
            callback = function(touchmenu)
                self:editCoversFolder(touchmenu)
            end,
        },
        {
            text_func = function()
                return T(_("Drawings folder: %1"), shared.getDrawingsFolder())
            end,
            enabled_func = function()
                return getSetting("include_handwritten", true) ~= false
            end,
            callback = function(touchmenu)
                self:editDrawingsFolder(touchmenu)
            end,
        },
    }
    buildFilesRows = function()
        local fm_sub = self:genFrontmatterFieldsMenu(nil)
        local rows = {
            {
                text_func = function()
                    local labels = {
                        md = _("Markdown (.md)"),
                        txt = _("Plain text (.txt)"),
                        both = _("Both (.md and .txt)"),
                    }
                    local current = getExportFormat()
                    return T(_("Export format: %1"), labels[current] or labels.md)
                end,
                sub_item_table = {
                    {
                        text = _("Markdown (.md)"),
                        radio = true,
                        keep_menu_open = true,
                        checked_func = function()
                            return getExportFormat() == "md"
                        end,
                        callback = function(touchmenu)
                            if getExportFormat() ~= "md" then
                                setExportFormat("md")
                                self:invalidateExportHashes()
                                rebuildFilesRows(touchmenu)
                            end
                        end,
                    },
                    {
                        text = _("Plain text (.txt)"),
                        radio = true,
                        keep_menu_open = true,
                        checked_func = function()
                            return getExportFormat() == "txt"
                        end,
                        callback = function(touchmenu)
                            if getExportFormat() ~= "txt" then
                                setExportFormat("txt")
                                self:invalidateExportHashes()
                                rebuildFilesRows(touchmenu)
                            end
                        end,
                    },
                    {
                        text = _("Both (.md and .txt)"),
                        radio = true,
                        keep_menu_open = true,
                        checked_func = function()
                            return getExportFormat() == "both"
                        end,
                        callback = function(touchmenu)
                            if getExportFormat() ~= "both" then
                                setExportFormat("both")
                                self:invalidateExportHashes()
                                rebuildFilesRows(touchmenu)
                            end
                        end,
                    },
                },
            },
            {
                text_func = function()
                    local labels = {
                        obsidian = _("Obsidian"),
                        standard = _("Standard"),
                    }
                    local current = shared.getMarkdownStyle()
                    return T(_("Markdown style: %1"), labels[current] or labels.obsidian)
                end,
                enabled_func = function()
                    return getExportFormat() ~= "txt"
                end,
                mandatory_func = function()
                    if getExportFormat() == "txt" then
                        return _("Not used with .txt")
                    end
                end,
                separator = true,
                sub_item_table = {
                    {
                        text = _("Obsidian"),
                        radio = true,
                        keep_menu_open = true,
                        checked_func = function()
                            return shared.getMarkdownStyle() == "obsidian"
                        end,
                        callback = function()
                            if shared.getMarkdownStyle() ~= "obsidian" then
                                shared.setMarkdownStyle("obsidian")
                                self:invalidateExportHashes()
                            end
                        end,
                    },
                    {
                        text = _("Standard"),
                        radio = true,
                        keep_menu_open = true,
                        checked_func = function()
                            return shared.getMarkdownStyle() == "standard"
                        end,
                        callback = function()
                            if shared.getMarkdownStyle() ~= "standard" then
                                shared.setMarkdownStyle("standard")
                                self:invalidateExportHashes()
                            end
                        end,
                    },
                },
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
                text = _("File names & folders"),
                sub_item_table = filenames_folders_table,
            },
            {
                text = _("Frontmatter fields"),
                separator = true,
                sub_item_table = fm_sub,
                sub_item_table_func = function()
                    return self:genFrontmatterFieldsMenu(nil, fm_sub)
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
            {
                text = T(_("Reading digest (%1)"), DIGEST_FILENAME),
                separator = true,
                checked_func = function()
                    return getSetting("with_digest", false)
                end,
                keep_menu_open = true,
                callback = function()
                    setSetting("with_digest", not getSetting("with_digest", false))
                end,
            },
            {
                text_func = function()
                    return T(_("Backup copies (%1)"), #self:allBackups())
                end,
                enabled_func = function()
                    return #self:allBackups() > 0
                end,
                mandatory_func = function()
                    if #self:allBackups() == 0 then
                        return _("None")
                    end
                end,
                sub_item_table_func = function()
                    return self:genAllBackupsMenu()
                end,
            },
            {
                text = _("Export settings to file"),
                callback = function()
                    local backup_path = self:getLocalDir() .. "/" .. shared.SETTINGS_BACKUP_FILENAME
                    if shared.exportSettingsToFile(backup_path) then
                        UIManager:show(Notification:new{
                            text = T(_("Settings exported to %1"), shared.SETTINGS_BACKUP_FILENAME),
                            timeout = 3,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("The settings backup could not be written."),
                        })
                    end
                end,
            },
            {
                text = _("Restore settings from backup…"),
                enabled_func = function()
                    local backup_path = self:getLocalDir() .. "/" .. shared.SETTINGS_BACKUP_FILENAME
                    return lfs.attributes(backup_path, "mode") == "file"
                end,
                callback = function(touchmenu)
                    local backup_path = self:getLocalDir() .. "/" .. shared.SETTINGS_BACKUP_FILENAME
                    UIManager:scheduleIn(0.1, function()
                        UIManager:show(ConfirmBox:new{
                            text = T(_("Restore all Tomedown settings from %1?\n\nCurrent settings will be replaced."),
                                shared.SETTINGS_BACKUP_FILENAME),
                            ok_text = _("Restore"),
                            cancel_text = _("Cancel"),
                            ok_callback = function()
                                if shared.restoreSettingsFromFile(backup_path) then
                                    if touchmenu and touchmenu.updateItems then
                                        touchmenu:updateItems()
                                    end
                                    UIManager:show(Notification:new{
                                        text = _("Settings restored from backup."),
                                        timeout = 3,
                                    })
                                else
                                    UIManager:show(InfoMessage:new{
                                        text = _("The settings backup could not be read."),
                                    })
                                end
                            end,
                        })
                    end)
                end,
            },
        }
        return rows
    end
    files_table = buildFilesRows()

    -- Group 2: Index & library (00 - Index.md settings, structure, and sections).
    local index = {
        {
            text = T(_("Index note (%1)"), INDEX_FILENAME),
            checked_func = function()
                return getSetting("with_index", true)
            end,
            keep_menu_open = true,
            callback = function()
                setSetting("with_index", not getSetting("with_index", true))
            end,
        },
        {
            text_func = function()
                local labels = {
                    author = _("Author"),
                    title = _("Title"),
                    last_read = _("Last read"),
                    highlights = _("Highlights"),
                }
                local current = getSetting("index_order", "author")
                return T(_("Index order: %1"),
                    labels[current] or labels.author)
            end,
            enabled_func = function()
                return getSetting("with_index", true)
            end,
            sub_item_table = {
                {
                    text = _("Author"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getSetting("index_order", "author") == "author"
                    end,
                    callback = function()
                        setIndexOrder("author")
                    end,
                },
                {
                    text = _("Title"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getSetting("index_order", "author") == "title"
                    end,
                    callback = function()
                        setIndexOrder("title")
                    end,
                },
                {
                    text = _("Last read"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getSetting("index_order", "author") == "last_read"
                    end,
                    callback = function()
                        setIndexOrder("last_read")
                    end,
                },
                {
                    text = _("Highlights"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getSetting("index_order", "author") == "highlights"
                    end,
                    callback = function()
                        setIndexOrder("highlights")
                    end,
                },
            },
        },
        {
            text_func = function()
                local labels = {
                    tags_below = _("Tags under the title"),
                    tags_column = _("Tags column"),
                    tags_column_compact = _("Tags column, compact"),
                }
                local current = shared.getMarkdownStyle() == "standard"
                    and "tags_below" or getSetting("index_layout", "tags_below")
                return T(_("Index layout: %1"),
                    labels[current] or labels.tags_below)
            end,
            enabled_func = function()
                return getSetting("with_index", true) and shared.getMarkdownStyle() ~= "standard"
            end,
            sub_item_table = {
                {
                    text = _("Tags under the title"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getSetting("index_layout", "tags_below") == "tags_below"
                    end,
                    callback = function()
                        setIndexLayout("tags_below")
                    end,
                },
                {
                    text = _("Tags column"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getSetting("index_layout", "tags_below") == "tags_column"
                    end,
                    callback = function()
                        setIndexLayout("tags_column")
                    end,
                },
                {
                    text = _("Tags column, compact"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getSetting("index_layout", "tags_below") == "tags_column_compact"
                    end,
                    callback = function()
                        setIndexLayout("tags_column_compact")
                    end,
                },
            },
        },
        {
            text_func = function()
                local labels = {
                    wikilink = _("Obsidian wikilink"),
                    markdown = _("Standard Markdown"),
                }
                local current = shared.getMarkdownStyle() == "standard"
                    and "markdown" or getIndexLinks()
                return T(_("Index links: %1"),
                    labels[current] or labels.wikilink)
            end,
            enabled_func = function()
                return getSetting("with_index", true) and shared.getMarkdownStyle() ~= "standard"
            end,
            sub_item_table = {
                {
                    text = _("Obsidian wikilink"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getIndexLinks() == "wikilink"
                    end,
                    callback = function()
                        setIndexLinksFormat("wikilink")
                    end,
                },
                {
                    text = _("Standard Markdown"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getIndexLinks() == "markdown"
                    end,
                    callback = function()
                        setIndexLinksFormat("markdown")
                    end,
                },
            },
        },
        {
            text_func = function()
                local labels = {
                    minimal = _("Minimal symbols (● / ◐)"),
                    emoji = _("Emoji (🟢 / 🟡)"),
                    badges = _("Code badges (`READING`)"),
                    editorial = _("Editorial (Reading)"),
                }
                local current = shared.getIndexStyle()
                return T(_("Index style: %1"),
                    labels[current] or labels.minimal)
            end,
            enabled_func = function()
                return getSetting("with_index", true)
            end,
            sub_item_table = {
                {
                    text = _("Minimal symbols (● / ◐)"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return shared.getIndexStyle() == "minimal"
                    end,
                    callback = function()
                        if shared.getIndexStyle() ~= "minimal" then
                            shared.setIndexStyle("minimal")
                            setSetting("index_dirty", true)
                        end
                    end,
                },
                {
                    text = _("Emoji (🟢 / 🟡)"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return shared.getIndexStyle() == "emoji"
                    end,
                    callback = function()
                        if shared.getIndexStyle() ~= "emoji" then
                            shared.setIndexStyle("emoji")
                            setSetting("index_dirty", true)
                        end
                    end,
                },
                {
                    text = _("Code badges (`READING`)"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return shared.getIndexStyle() == "badges"
                    end,
                    callback = function()
                        if shared.getIndexStyle() ~= "badges" then
                            shared.setIndexStyle("badges")
                            setSetting("index_dirty", true)
                        end
                    end,
                },
                {
                    text = _("Editorial (Reading)"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return shared.getIndexStyle() == "editorial"
                    end,
                    callback = function()
                        if shared.getIndexStyle() ~= "editorial" then
                            shared.setIndexStyle("editorial")
                            setSetting("index_dirty", true)
                        end
                    end,
                },
            },
        },
        {
            text_func = function()
                local labels = {
                    all = _("Show all"),
                    first_3 = _("First 3 (+N)"),
                    collapsible = _("Collapsible (<details>)"),
                }
                local current = shared.getIndexTagsMode()
                if shared.getMarkdownStyle() == "standard" and current == "collapsible" then
                    current = "first_3"
                end
                return T(_("Tags display: %1"),
                    labels[current] or labels.all)
            end,
            enabled_func = function()
                return getSetting("with_index", true)
            end,
            separator = true,
            sub_item_table_func = function()
                local is_std = shared.getMarkdownStyle() == "standard"
                local items = {
                    {
                        text = _("Show all"),
                        radio = true,
                        keep_menu_open = true,
                        checked_func = function()
                            return shared.getIndexTagsMode() == "all"
                        end,
                        callback = function()
                            if shared.getIndexTagsMode() ~= "all" then
                                shared.setIndexTagsMode("all")
                                setSetting("index_dirty", true)
                            end
                        end,
                    },
                    {
                        text = _("First 3 (+N)"),
                        radio = true,
                        keep_menu_open = true,
                        checked_func = function()
                            local m = shared.getIndexTagsMode()
                            return m == "first_3" or (is_std and m == "collapsible")
                        end,
                        callback = function()
                            if shared.getIndexTagsMode() ~= "first_3" then
                                shared.setIndexTagsMode("first_3")
                                setSetting("index_dirty", true)
                            end
                        end,
                    },
                }
                if not is_std then
                    items[#items + 1] = {
                        text = _("Collapsible (<details>)"),
                        radio = true,
                        keep_menu_open = true,
                        checked_func = function()
                            return shared.getIndexTagsMode() == "collapsible"
                        end,
                        callback = function()
                            if shared.getIndexTagsMode() ~= "collapsible" then
                                shared.setIndexTagsMode("collapsible")
                                setSetting("index_dirty", true)
                            end
                        end,
                    }
                end
                return items
            end,
        },
        {
            text = _("Reading now section"),
            enabled_func = function()
                return getSetting("with_index", true)
            end,
            checked_func = function()
                return getSetting("reading_now", true)
            end,
            keep_menu_open = true,
            callback = function()
                setSetting("reading_now", not getSetting("reading_now", true))
                setSetting("index_dirty", true)
            end,
        },
        {
            text = _("Completed books"),
            enabled_func = function()
                return getSetting("with_index", true)
            end,
            checked_func = function()
                return shared.getCompletedBooks()
            end,
            keep_menu_open = true,
            callback = function()
                shared.setCompletedBooks(not shared.getCompletedBooks())
                setSetting("index_dirty", true)
            end,
        },
        {
            text = _("Library dashboard"),
            enabled_func = function()
                return getSetting("with_index", true)
            end,
            checked_func = function()
                return shared.getIndexDashboard()
            end,
            keep_menu_open = true,
            callback = function()
                shared.setIndexDashboard(not shared.getIndexDashboard())
                setSetting("index_dirty", true)
            end,
        },
        {
            text = _("Tag cloud"),
            enabled_func = function()
                return getSetting("with_index", true)
            end,
            checked_func = function()
                return shared.getIndexTagCloud()
            end,
            keep_menu_open = true,
            callback = function()
                shared.setIndexTagCloud(not shared.getIndexTagCloud())
                setSetting("index_dirty", true)
            end,
        },
    }

    -- Group 3: Notes & highlights (highlight formatting, notes, chapters, and Book page).
    local style_table
    local buildStyleRows
    local function makeGlobalVisualStyleRow(title_tmpl, getter, setter, enabled_fn, sep)
        local labels = {
            minimal = _("Minimal symbols (● / ◐)"),
            emoji = _("Emoji (🟢 / 🟡)"),
            badges = _("Code badges (`READING`)"),
            editorial = _("Editorial (Reading)"),
        }
        return {
            text_func = function()
                local current = getter()
                return T(title_tmpl, labels[current] or labels.minimal)
            end,
            enabled_func = enabled_fn,
            separator = sep,
            sub_item_table = {
                {
                    text = labels.minimal,
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getter() == "minimal"
                    end,
                    callback = function()
                        if getter() ~= "minimal" then
                            setter("minimal")
                            self:invalidateExportHashes()
                        end
                    end,
                },
                {
                    text = labels.emoji,
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getter() == "emoji"
                    end,
                    callback = function()
                        if getter() ~= "emoji" then
                            setter("emoji")
                            self:invalidateExportHashes()
                        end
                    end,
                },
                {
                    text = labels.badges,
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getter() == "badges"
                    end,
                    callback = function()
                        if getter() ~= "badges" then
                            setter("badges")
                            self:invalidateExportHashes()
                        end
                    end,
                },
                {
                    text = labels.editorial,
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getter() == "editorial"
                    end,
                    callback = function()
                        if getter() ~= "editorial" then
                            setter("editorial")
                            self:invalidateExportHashes()
                        end
                    end,
                },
            },
        }
    end
    buildStyleRows = function()
    local rows = {
        {
            text_func = function()
                local labels = {
                    callout = _("Callout ([!highlight])"),
                    alert = _("Alert ([!IMPORTANT])"),
                    highlight = _("Highlight (==text==)"),
                    highlight_bold = _("Highlight & Bold (==**text**==)"),
                    star_bold = _("Star & Bold (⭐ **text**)"),
                    bold = _("Bold (**text**)"),
                }
                local cur = getSetting("special_marker", "callout")
                if shared.getMarkdownStyle() == "standard"
                        and (cur == "callout" or cur == "alert"
                            or cur == "highlight" or cur == "highlight_bold") then
                    cur = "bold"
                end
                return T(_("Special highlight style: %1"),
                    labels[cur] or labels.callout)
            end,
            enabled_func = function()
                return shared.getMarkdownStyle() == "standard" or not getSetting("callout", false)
            end,
            keep_menu_open = true,
            sub_item_table = {
                {
                    text = _("Callout ([!highlight])"),
                    radio = true,
                    enabled_func = function()
                        return shared.getMarkdownStyle() ~= "standard"
                    end,
                    checked_func = function()
                        return shared.getMarkdownStyle() ~= "standard"
                            and getSetting("special_marker", "callout") == "callout"
                    end,
                    keep_menu_open = true,
                    callback = function()
                        setSetting("special_marker", "callout")
                        self:invalidateExportHashes()
                    end,
                },
                {
                    text = _("Alert ([!IMPORTANT])"),
                    radio = true,
                    enabled_func = function()
                        return shared.getMarkdownStyle() ~= "standard"
                    end,
                    checked_func = function()
                        return shared.getMarkdownStyle() ~= "standard"
                            and getSetting("special_marker", "callout") == "alert"
                    end,
                    keep_menu_open = true,
                    callback = function()
                        setSetting("special_marker", "alert")
                        self:invalidateExportHashes()
                    end,
                },
                {
                    text = _("Highlight (==text==)"),
                    radio = true,
                    enabled_func = function()
                        return shared.getMarkdownStyle() ~= "standard"
                    end,
                    checked_func = function()
                        return shared.getMarkdownStyle() ~= "standard"
                            and getSetting("special_marker", "callout") == "highlight"
                    end,
                    keep_menu_open = true,
                    callback = function()
                        setSetting("special_marker", "highlight")
                        self:invalidateExportHashes()
                    end,
                },
                {
                    text = _("Highlight & Bold (==**text**==)"),
                    radio = true,
                    enabled_func = function()
                        return shared.getMarkdownStyle() ~= "standard"
                    end,
                    checked_func = function()
                        return shared.getMarkdownStyle() ~= "standard"
                            and getSetting("special_marker", "callout") == "highlight_bold"
                    end,
                    keep_menu_open = true,
                    callback = function()
                        setSetting("special_marker", "highlight_bold")
                        self:invalidateExportHashes()
                    end,
                },
                {
                    text = _("Star & Bold (⭐ **text**)"),
                    radio = true,
                    checked_func = function()
                        return getSetting("special_marker", "callout") == "star_bold"
                    end,
                    keep_menu_open = true,
                    callback = function()
                        setSetting("special_marker", "star_bold")
                        self:invalidateExportHashes()
                    end,
                },
                {
                    text = _("Bold (**text**)"),
                    radio = true,
                    checked_func = function()
                        local cur = getSetting("special_marker", "callout")
                        return cur == "bold"
                            or (shared.getMarkdownStyle() == "standard"
                                and (cur == "callout" or cur == "alert"
                                    or cur == "highlight" or cur == "highlight_bold"))
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
            text_func = function()
                local labels = {
                    page_date = _("Page and date"),
                    page_only = _("Page only"),
                    date_only = _("Date only"),
                    none = _("None"),
                }
                local current = getHighlightDetails()
                return T(_("Highlight details: %1"),
                    labels[current] or labels.page_date)
            end,
            sub_item_table = {
                {
                    text = _("Page and date"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getHighlightDetails() == "page_date"
                    end,
                    callback = function()
                        if getHighlightDetails() ~= "page_date" then
                            setHighlightDetails("page_date")
                            self:invalidateExportHashes()
                        end
                    end,
                },
                {
                    text = _("Page only"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getHighlightDetails() == "page_only"
                    end,
                    callback = function()
                        if getHighlightDetails() ~= "page_only" then
                            setHighlightDetails("page_only")
                            self:invalidateExportHashes()
                        end
                    end,
                },
                {
                    text = _("Date only"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getHighlightDetails() == "date_only"
                    end,
                    callback = function()
                        if getHighlightDetails() ~= "date_only" then
                            setHighlightDetails("date_only")
                            self:invalidateExportHashes()
                        end
                    end,
                },
                {
                    text = _("None"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getHighlightDetails() == "none"
                    end,
                    callback = function()
                        if getHighlightDetails() ~= "none" then
                            setHighlightDetails("none")
                            self:invalidateExportHashes()
                        end
                    end,
                },
            },
        },
        {
            text = _("Highlight context"),
            checked_func = function()
                return getHighlightContext()
            end,
            keep_menu_open = true,
            callback = function()
                setHighlightContext(not getHighlightContext())
                self:invalidateExportHashes()
            end,
        },
        {
            text = _("Link IDs on highlights"),
            enabled_func = function()
                return shared.getMarkdownStyle() ~= "standard"
            end,
            checked_func = function()
                return shared.getMarkdownStyle() ~= "standard" and getSetting("block_ids", false)
            end,
            keep_menu_open = true,
            callback = function()
                setSetting("block_ids", not getSetting("block_ids", false))
                self:invalidateExportHashes()
            end,
        },
        {
            text = _("Every highlight is special"),
            separator = true,
            enabled_func = function()
                return shared.getMarkdownStyle() ~= "standard"
            end,
            checked_func = function()
                return shared.getMarkdownStyle() ~= "standard" and getSetting("callout", false)
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
                    inline = _("Inline"),
                    footnote = _("Footnotes"),
                }
                local current = getNoteStyle()
                return T(_("Personal notes format: %1"),
                    labels[current] or labels.inline)
            end,
            sub_item_table = {
                {
                    text = _("Inline"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getNoteStyle() == "inline"
                    end,
                    callback = function()
                        if getNoteStyle() ~= "inline" then
                            setNoteStyle("inline")
                            self:invalidateExportHashes()
                        end
                    end,
                },
                {
                    text = _("Footnotes"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getNoteStyle() == "footnote"
                    end,
                    callback = function()
                        if getNoteStyle() ~= "footnote" then
                            setNoteStyle("footnote")
                            self:invalidateExportHashes()
                        end
                    end,
                },
            },
        },
        {
            text_func = function()
                local labels = {
                    h1 = _("Heading 1 (# Chapter)"),
                    h2 = _("Heading 2 (## Chapter)"),
                    h3 = _("Heading 3 (### Chapter)"),
                    none = _("None (continuous list)"),
                }
                local current = getChapterHeadings()
                return T(_("Chapter headings: %1"),
                    labels[current] or labels.h1)
            end,
            sub_item_table = {
                {
                    text = _("Heading 1 (# Chapter)"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getChapterHeadings() == "h1"
                    end,
                    callback = function()
                        if getChapterHeadings() ~= "h1" then
                            setChapterHeadings("h1")
                            self:invalidateExportHashes()
                        end
                    end,
                },
                {
                    text = _("Heading 2 (## Chapter)"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getChapterHeadings() == "h2"
                    end,
                    callback = function()
                        if getChapterHeadings() ~= "h2" then
                            setChapterHeadings("h2")
                            self:invalidateExportHashes()
                        end
                    end,
                },
                {
                    text = _("Heading 3 (### Chapter)"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getChapterHeadings() == "h3"
                    end,
                    callback = function()
                        if getChapterHeadings() ~= "h3" then
                            setChapterHeadings("h3")
                            self:invalidateExportHashes()
                        end
                    end,
                },
                {
                    text = _("None (continuous list)"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function()
                        return getChapterHeadings() == "none"
                    end,
                    callback = function()
                        if getChapterHeadings() ~= "none" then
                            setChapterHeadings("none")
                            self:invalidateExportHashes()
                        end
                    end,
                },
            },
        },
        {
            text = _("Page bookmarks"),
            checked_func = function()
                return getSetting("include_bookmarks", false)
            end,
            keep_menu_open = true,
            callback = function()
                setSetting("include_bookmarks", not getSetting("include_bookmarks", false))
            end,
        },
        {
            text = _("Handwritten notes"),
            separator = true,
            checked_func = function()
                return getSetting("include_handwritten", true) ~= false
            end,
            keep_menu_open = true,
            callback = function()
                local cur = getSetting("include_handwritten", true) ~= false
                setSetting("include_handwritten", not cur and true or false)
                self:invalidateExportHashes()
            end,
        },
        (function()
            local sec_style_table
            local buildSecStyleRows
            local function rebuildSecStyleRows(touchmenu)
                if not sec_style_table then
                    return
                end
                local fresh = buildSecStyleRows()
                for i = #sec_style_table, 1, -1 do
                    sec_style_table[i] = nil
                end
                for __, item in ipairs(fresh) do
                    sec_style_table[#sec_style_table + 1] = item
                end
                if touchmenu and touchmenu.item_table == sec_style_table and touchmenu.updateItems then
                    touchmenu:updateItems()
                end
            end
            buildSecStyleRows = function()
                local harmonized = shared.getHarmonizeBookStyle()
                local s_rows = {
                    {
                        text = _("Harmonize book styles"),
                        checked_func = function()
                            return shared.getHarmonizeBookStyle()
                        end,
                        keep_menu_open = true,
                        separator = true,
                        callback = function(touchmenu)
                            shared.setHarmonizeBookStyle(not shared.getHarmonizeBookStyle())
                            self:invalidateExportHashes()
                            rebuildSecStyleRows(touchmenu)
                        end,
                    },
                }
                if harmonized then
                    s_rows[#s_rows + 1] = makeGlobalVisualStyleRow(
                        _("Book style: %1"),
                        shared.getBookVisualStyle,
                        shared.setBookVisualStyle
                    )
                else
                    s_rows[#s_rows + 1] = makeGlobalVisualStyleRow(
                        _("Dashboard style: %1"),
                        shared.getDashboardStyle,
                        shared.setDashboardStyle,
                        function()
                            return shared.getReadingDashboard()
                        end
                    )
                    s_rows[#s_rows + 1] = makeGlobalVisualStyleRow(
                        _("Synopsis style: %1"),
                        shared.getSynopsisStyle,
                        shared.setSynopsisStyle,
                        function()
                            return shared.getBookSynopsis()
                        end
                    )
                    s_rows[#s_rows + 1] = makeGlobalVisualStyleRow(
                        _("Tags style: %1"),
                        shared.getBodyTagsStyle,
                        shared.setBodyTagsStyle,
                        function()
                            return shared.getBodyTags()
                        end
                    )
                    s_rows[#s_rows + 1] = makeGlobalVisualStyleRow(
                        _("Showcase style: %1"),
                        shared.getShowcaseStyle,
                        shared.setShowcaseStyle,
                        function()
                            return shared.getSpecialShowcase()
                        end
                    )
                end
                return s_rows
            end
            sec_style_table = buildSecStyleRows()
            local card_table = {
                {
                    text = _("Book title in body"),
                    checked_func = function()
                        return shared.getBookHeading()
                    end,
                    keep_menu_open = true,
                    callback = function()
                        shared.setBookHeading(not shared.getBookHeading())
                        self:invalidateExportHashes()
                    end,
                },
                {
                    text = _("Book cover image"),
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
                    text_func = function()
                        local labels = {
                            inline = _("Inline / Heading"),
                            blockquote = _("Classic blockquote"),
                            callout = _("Callout ([!summary])"),
                            table = _("Table"),
                        }
                        local current = shared.getOverviewStyle()
                        if shared.getMarkdownStyle() == "standard" and current == "callout" then
                            current = "blockquote"
                        end
                        return T(_("Overview style: %1"),
                            labels[current] or labels.inline)
                    end,
                    separator = true,
                    sub_item_table = {
                        {
                            text = _("Inline / Heading"),
                            radio = true,
                            keep_menu_open = true,
                            checked_func = function()
                                return shared.getOverviewStyle() == "inline"
                            end,
                            callback = function()
                                if shared.getOverviewStyle() ~= "inline" then
                                    shared.setOverviewStyle("inline")
                                    self:invalidateExportHashes()
                                end
                            end,
                        },
                        {
                            text = _("Classic blockquote"),
                            radio = true,
                            keep_menu_open = true,
                            checked_func = function()
                                local cur = shared.getOverviewStyle()
                                return cur == "blockquote"
                                    or (shared.getMarkdownStyle() == "standard" and cur == "callout")
                            end,
                            callback = function()
                                if shared.getOverviewStyle() ~= "blockquote" then
                                    shared.setOverviewStyle("blockquote")
                                    self:invalidateExportHashes()
                                end
                            end,
                        },
                        {
                            text = _("Callout ([!summary])"),
                            radio = true,
                            keep_menu_open = true,
                            enabled_func = function()
                                return shared.getMarkdownStyle() ~= "standard"
                            end,
                            checked_func = function()
                                return shared.getMarkdownStyle() ~= "standard"
                                    and shared.getOverviewStyle() == "callout"
                            end,
                            callback = function()
                                if shared.getOverviewStyle() ~= "callout" then
                                    shared.setOverviewStyle("callout")
                                    self:invalidateExportHashes()
                                end
                            end,
                        },
                        {
                            text = _("Table"),
                            radio = true,
                            keep_menu_open = true,
                            checked_func = function()
                                return shared.getOverviewStyle() == "table"
                            end,
                            callback = function()
                                if shared.getOverviewStyle() ~= "table" then
                                    shared.setOverviewStyle("table")
                                    self:invalidateExportHashes()
                                end
                            end,
                        },
                    },
                },
                {
                    text = _("Reading dashboard"),
                    checked_func = function()
                        return shared.getReadingDashboard()
                    end,
                    keep_menu_open = true,
                    callback = function()
                        shared.setReadingDashboard(not shared.getReadingDashboard())
                        self:invalidateExportHashes()
                    end,
                },
                {
                    text = _("Book synopsis"),
                    checked_func = function()
                        return shared.getBookSynopsis()
                    end,
                    keep_menu_open = true,
                    callback = function()
                        shared.setBookSynopsis(not shared.getBookSynopsis())
                        self:invalidateExportHashes()
                    end,
                },
                {
                    text_func = function()
                        local labels = {
                            collapsed = _("Collapsed (foldable)"),
                            short = _("Short preview (~300 chars)"),
                            collapsed_short = _("Collapsed + Short preview"),
                            expanded = _("Expanded (full text)"),
                        }
                        local current = shared.getSynopsisMode()
                        return T(_("Synopsis display: %1"),
                            labels[current] or labels.collapsed)
                    end,
                    enabled_func = function()
                        return shared.getBookSynopsis()
                    end,
                    separator = true,
                    sub_item_table = {
                        {
                            text = _("Collapsed (foldable)"),
                            radio = true,
                            keep_menu_open = true,
                            checked_func = function()
                                return shared.getSynopsisMode() == "collapsed"
                            end,
                            callback = function()
                                if shared.getSynopsisMode() ~= "collapsed" then
                                    shared.setSynopsisMode("collapsed")
                                    self:invalidateExportHashes()
                                end
                            end,
                        },
                        {
                            text = _("Short preview (~300 chars)"),
                            radio = true,
                            keep_menu_open = true,
                            checked_func = function()
                                return shared.getSynopsisMode() == "short"
                            end,
                            callback = function()
                                if shared.getSynopsisMode() ~= "short" then
                                    shared.setSynopsisMode("short")
                                    self:invalidateExportHashes()
                                end
                            end,
                        },
                        {
                            text = _("Collapsed + Short preview"),
                            radio = true,
                            keep_menu_open = true,
                            checked_func = function()
                                return shared.getSynopsisMode() == "collapsed_short"
                            end,
                            callback = function()
                                if shared.getSynopsisMode() ~= "collapsed_short" then
                                    shared.setSynopsisMode("collapsed_short")
                                    self:invalidateExportHashes()
                                end
                            end,
                        },
                        {
                            text = _("Expanded (full text)"),
                            radio = true,
                            keep_menu_open = true,
                            checked_func = function()
                                return shared.getSynopsisMode() == "expanded"
                            end,
                            callback = function()
                                if shared.getSynopsisMode() ~= "expanded" then
                                    shared.setSynopsisMode("expanded")
                                    self:invalidateExportHashes()
                                end
                            end,
                        },
                    },
                },
                {
                    text = _("Tags in body"),
                    checked_func = function()
                        return shared.getBodyTags()
                    end,
                    keep_menu_open = true,
                    callback = function()
                        shared.setBodyTags(not shared.getBodyTags())
                        self:invalidateExportHashes()
                    end,
                },
                {
                    text = _("Special highlights showcase"),
                    checked_func = function()
                        return shared.getSpecialShowcase()
                    end,
                    keep_menu_open = true,
                    separator = true,
                    callback = function()
                        shared.setSpecialShowcase(not shared.getSpecialShowcase())
                        self:invalidateExportHashes()
                    end,
                },
                {
                    text = _("Section styles"),
                    sub_item_table = sec_style_table,
                    sub_item_table_func = function()
                        sec_style_table = buildSecStyleRows()
                        return sec_style_table
                    end,
                },
            }
            return {
                text = _("Book page"),
                sub_item_table = card_table,
            }
        end)(),
    }
    return rows
    end
    style_table = buildStyleRows()

    -- Group 4: Book info (automatic updates and bulk import).
    local function importableBookInfoFiles()
        local files = {}
        for __, file in ipairs(self:listBookFiles()) do
            if getBookExclusion(file) ~= "none" then
                files[#files + 1] = file
            end
        end
        return files
    end
    local function importAllBookInfo()
        local files = importableBookInfoFiles()
        for __, file in ipairs(files) do
            metadata.import(file)
        end
        local imported = {}
        for __, file in ipairs(files) do
            if getBookImported(file) then
                imported[#imported + 1] = file
            end
        end
        self:runExport(imported, { only_updated = true })
    end
    local bookinfo = {
        {
            text = _("Update book info automatically"),
            checked_func = function()
                return getAutoBookInfo()
            end,
            keep_menu_open = true,
            callback = function()
                setAutoBookInfo(not getAutoBookInfo())
            end,
        },
        {
            text = withIcon("\xEF\x80\xAD", _("Import book info for all books…")),
            enabled_func = function()
                return #importableBookInfoFiles() > 0
            end,
            callback = function(touchmenu)
                local count = #importableBookInfoFiles()
                UIManager:show(ConfirmBox:new{
                    text = T(_("Import rating, review, dates and collections for all %1 books? Their notes are rewritten, your own notes stay."), count),
                    ok_text = _("Import all"),
                    cancel_text = _("Cancel"),
                    ok_callback = function()
                        if touchmenu and touchmenu.closeMenu then
                            touchmenu:closeMenu()
                        end
                        importAllBookInfo()
                    end,
                })
            end,
        },
    }

    -- Group 5: Cloud upload (upload switch, unified destination, and re-upload).
    local dest_table
    local function buildDestinationRows()
        local items = {
            {
                text = _("Choose in cloud storage…"),
                callback = function(touchmenu)
                    self:chooseCloudFolder(touchmenu)
                end,
            },
            {
                text = _("Enter remote path…"),
                callback = function(touchmenu)
                    self:editRemoteFolder(touchmenu)
                end,
            },
        }
        if getSetting("remote_folder", "") ~= "" then
            items[#items + 1] = {
                text = _("Clear remote path…"),
                callback = function(touchmenu)
                    UIManager:scheduleIn(0.1, function()
                        UIManager:show(ConfirmBox:new{
                            text = _("Clear the custom remote path and use the folder chosen in cloud storage?"),
                            ok_text = _("Clear"),
                            cancel_text = _("Cancel"),
                            ok_callback = function()
                                setSetting("remote_folder", "")
                                if touchmenu and touchmenu.item_table == dest_table then
                                    local fresh = buildDestinationRows()
                                    for i = #dest_table, 1, -1 do
                                        dest_table[i] = nil
                                    end
                                    for __, item in ipairs(fresh) do
                                        dest_table[#dest_table + 1] = item
                                    end
                                    if touchmenu.updateItems then
                                        touchmenu:updateItems()
                                    end
                                end
                            end,
                        })
                    end)
                end,
            }
        end
        return items
    end
    dest_table = buildDestinationRows()
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
                local folder = self:getRemoteFolder()
                if not server then
                    if folder ~= "" then
                        return T(_("Destination: %1"), folder)
                    end
                    return _("Destination: Not set")
                end
                local cloud_ui = self.ui and self.ui.cloudstorage
                local name = cloud_ui and cloud_ui.getServerNameType
                    and cloud_ui:getServerNameType(server) or server.name or "?"
                if folder ~= "" then
                    return T(_("Destination: %1 → %2"), name, folder)
                end
                return T(_("Destination: %1"), name)
            end,
            separator = true,
            sub_item_table = dest_table,
            sub_item_table_func = function()
                dest_table = buildDestinationRows()
                return dest_table
            end,
        },
        {
            text = withIcon("\xEE\xB4\xBE", _("Re-upload all files…")),
            enabled_func = function()
                return self:hasServer()
            end,
            callback = function(touchmenu)
                self:reuploadAll(touchmenu)
            end,
        },
    }

    -- Group 6: My notes (global switch, index switch, headings, and cloud merge).
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
                text = _("Keep my notes for all books"),
                checked_func = function()
                    return getSetting("preserve", false)
                end,
                keep_menu_open = true,
                callback = function(touchmenu)
                    setSetting("preserve", not getSetting("preserve", false))
                    self:invalidateExportHashes()
                    rebuildNotesRows(touchmenu)
                end,
            },
        }
        if getSetting("with_index", true)
                and not getSetting("preserve", false) then
            rows[#rows + 1] = {
                text = _("Keep my notes in the index"),
                checked_func = function()
                    return getIndexPreserve()
                end,
                keep_menu_open = true,
                callback = function(touchmenu)
                    setSetting("preserve_index",
                        not getIndexPreserve())
                    self:invalidateExportHashes()
                    rebuildNotesRows(touchmenu)
                end,
            }
        end
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

    -- Group 7: App & updates (top bar icon, update check, release channel, background check, changelog).
    local beta_table
    local function betaItems()
        local beta_on = getSetting("beta_releases", false)
        local function setChannel(want_beta, touch_menu)
            if getSetting("beta_releases", false) == want_beta then
                return
            end
            setSetting("beta_releases", want_beta)
            Update.clearAvailableCache()
            if touch_menu and touch_menu.item_table == beta_table then
                local fresh = betaItems()
                for i = #beta_table, 1, -1 do
                    beta_table[i] = nil
                end
                for _, item in ipairs(fresh) do
                    beta_table[#beta_table + 1] = item
                end
                if touch_menu.updateItems then
                    touch_menu:updateItems()
                end
            end
        end
        local items = {
            {
                text = _("Stable"),
                radio = true,
                keep_menu_open = true,
                checked_func = function()
                    return not getSetting("beta_releases", false)
                end,
                callback = function(touch_menu)
                    setChannel(false, touch_menu)
                end,
            },
            {
                text = _("Beta"),
                radio = true,
                keep_menu_open = true,
                separator = true,
                checked_func = function()
                    return getSetting("beta_releases", false)
                end,
                callback = function(touch_menu)
                    setChannel(true, touch_menu)
                end,
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
            text = withIcon("\xEE\xB6\x8F", _("Go back to the stable version…")),
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
            text = _("Top bar icon"),
            separator = true,
            checked_func = function()
                return getTopbarIcon()
            end,
            keep_menu_open = true,
            callback = function(touchmenu)
                setTopbarIcon(not getTopbarIcon())
                self:refreshMenuPlacement(touchmenu)
            end,
        },
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
            text_func = function()
                local ch = getSetting("beta_releases", false) and _("Beta") or _("Stable")
                return T(_("Release channel: %1"), ch)
            end,
            sub_item_table_func = function()
                beta_table = betaItems()
                return beta_table
            end,
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
            text = _("View changelog"),
            callback = function()
                Update.showChangelog()
            end,
        },
    }

    return {
        { text = withIcon("\xEF\x83\xB6", _("Export")), -- file-text
            sub_item_table = files_table,
            sub_item_table_func = function()
                files_table = buildFilesRows()
                return files_table
            end },
        { text = withIcon("\xEE\xBC\xB4", _("Index & library")), -- table-of-contents
            sub_item_table = index },
        { text = withIcon("\xEE\x9F\xA2", _("Notes & highlights")), -- brush
            sub_item_table = style_table,
            sub_item_table_func = function()
                style_table = buildStyleRows()
                return style_table
            end },
        { text = withIcon("\xEF\x81\x9A", _("Book info")), -- star-half
            sub_item_table = bookinfo },
        { text = withIcon("\xEE\xB4\xBE", _("Cloud upload")), -- cloud-sync
            sub_item_table = cloud },
        { text = withIcon("\xEF\x89\x89", _("My notes")), -- sticky-note
            sub_item_table_func = function()
                notes_table = buildNotesRows()
                return notes_table
            end },
        { text = withIcon("\xEE\xB6\xAE", _("App & updates")), -- update
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

    local movable = MovableContainer:new{ frame }
    local dialog
    dialog = InputContainer:new{
        align = "center",
        dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
        CenterContainer:new{
            dimen = Geom:new{ w = sw, h = sh },
            movable,
        },
    }
    dialog.onShow = function()
        UIManager:setDirty(dialog, function()
            return "ui", movable.dimen or frame.dimen
        end)
    end
    dialog.onCloseWidget = function()
        UIManager:setDirty(nil, function()
            return "flashui", movable.dimen or frame.dimen
        end)
    end
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

local TOPBAR_ICON_NAME = "appbar.tomedown"

local function ensureTopbarIconRegistered()
    local src = debug.getinfo(1, "S").source
    if not src or src:sub(1, 1) ~= "@" then
        return
    end
    local plugin_dir = src:sub(2):match("^(.*)/[^/]+$")
    if not plugin_dir then
        return
    end
    local assets_dir = plugin_dir .. "/assets"
    local svg_src = assets_dir .. "/" .. TOPBAR_ICON_NAME .. ".svg"
    if not lfs.attributes(svg_src) then
        return
    end
    -- Copy into DataStorage:getDataDir() .. "/icons" so KOReader's
    -- standard user_icons_dir has it on future launches
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage and type(DataStorage.getDataDir) == "function" then
        local icons_dir = DataStorage:getDataDir() .. "/icons"
        if lfs.attributes(icons_dir, "mode") ~= "directory" then
            pcall(lfs.mkdir, icons_dir)
        end
        local dst = icons_dir .. "/" .. TOPBAR_ICON_NAME .. ".svg"
        local content = readIfExists(svg_src)
        if content and readIfExists(dst) ~= content then
            local f = io.open(dst, "wb")
            if f then
                f:write(content)
                f:close()
            end
        end
    end
    -- Also register assets_dir in IconWidget's live lookup table so the
    -- icon renders immediately on the very first run without a restart
    local ok_iw, IconWidget = pcall(require, "ui/widget/iconwidget")
    if ok_iw and type(IconWidget) == "table"
            and type(IconWidget.init) == "function"
            and debug and type(debug.getupvalue) == "function" then
        for i = 1, 10 do
            local name, val = debug.getupvalue(IconWidget.init, i)
            if not name then
                break
            end
            if name == "ICONS_DIRS" and type(val) == "table" then
                local found = false
                for _, dir in ipairs(val) do
                    if dir == assets_dir then
                        found = true
                        break
                    end
                end
                if not found then
                    table.insert(val, 1, assets_dir)
                end
            elseif name == "ICONS_PATH" and type(val) == "table" then
                val[TOPBAR_ICON_NAME] = nil
            end
        end
    end
    local ok_img, ImageWidget = pcall(require, "ui/widget/imagewidget")
    if ok_img and type(ImageWidget) == "table"
            and type(ImageWidget._loadfile) == "function"
            and debug and type(debug.getupvalue) == "function" then
        for i = 1, 10 do
            local name, val = debug.getupvalue(ImageWidget._loadfile, i)
            if not name then
                break
            end
            if name == "ImageCache" and type(val) == "table" and type(val.clear) == "function" then
                pcall(val.clear, val)
                break
            end
        end
    end
end

local function removeFromArray(arr, target)
    if type(arr) ~= "table" then
        return
    end
    for i = #arr, 1, -1 do
        if arr[i] == target then
            table.remove(arr, i)
        end
    end
end

local function applyMenuOrder(order_module, default_group_id, use_topbar)
    local ok, order = pcall(require, order_module)
    if not ok or type(order) ~= "table" then
        -- outside KOReader (tests): no order tables, no placement
        return
    end
    removeFromArray(order[default_group_id], "tomedown")
    removeFromArray(order.tools, "tomedown")
    removeFromArray(order["KOMenu:menu_buttons"], "tomedown")
    if use_topbar then
        local buttons = order["KOMenu:menu_buttons"]
        if type(buttons) == "table" then
            local pos
            for i, id in ipairs(buttons) do
                if id == "main" then
                    pos = i
                    break
                end
            end
            if not pos then
                pos = #buttons + 1
            end
            table.insert(buttons, pos, "tomedown")
            order.tomedown = {}
            return
        end
    end
    order.tomedown = nil
    local group = order[default_group_id]
    if type(group) == "table" then
        table.insert(group, 1, "tomedown")
    end
end

local function applyMenuPlacement(use_topbar)
    applyMenuOrder("ui/elements/reader_menu_order", "navi", use_topbar)
    applyMenuOrder("ui/elements/filemanager_menu_order", "filemanager_settings", use_topbar)
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
    for __, slot in ipairs(BACKUP_SLOTS) do
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
    local d = os.date("%d %b %y", copy.modified or 0)
    if copy.slot == ".bak.1" then
        return T(_("Latest snapshot · %1"), d)
    elseif copy.slot == ".bak.2" then
        return T(_("Snapshot 2 · %1"), d)
    elseif copy.slot == ".bak.3" then
        return T(_("Snapshot 3 · %1"), d)
    elseif copy.slot ~= ".bak" then
        return T(_("Safety copy · %1"), d)
    elseif copy.zoned then
        return T(_("Saved notes · %1"), d)
    end
    return T(_("Older copy · %1"), d)
end

local function backupWhat(copy)
    if copy.slot ~= ".bak" then
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

function M:indexBackups()
    local md_path = self:getLocalDir() .. "/" .. INDEX_FILENAME
    local copies = {}
    for __, slot in ipairs(BACKUP_SLOTS) do
        local path = md_path .. slot
        local attr = lfs.attributes(path)
        if attr and attr.mode == "file" then
            copies[#copies + 1] = {
                path = path,
                slot = slot,
                md_path = md_path,
                title = _("Book index"),
                zoned = isZoned(readIfExists(path)),
                size = attr.size or 0,
                modified = attr.modification or 0,
            }
        end
    end
    return copies
end

function M:allBackups()
    local copies = {}
    local seen_paths = {}
    for __, copy in ipairs(self:indexBackups()) do
        seen_paths[copy.path] = true
        copies[#copies + 1] = copy
    end
    local records = getSetting("exports", {})
    local files = {}
    for file, rec in pairs(records) do
        if type(rec) == "table" and type(rec.base) == "string" and rec.base ~= "" then
            files[#files + 1] = { file = file, base = rec.base }
        end
    end
    table.sort(files, function(a, b) return a.base:lower() < b.base:lower() end)
    for __, entry in ipairs(files) do
        local leaf = entry.base:match("([^/]+)$") or entry.base
        for ___, copy in ipairs(self:bookBackups(entry.file)) do
            if not seen_paths[copy.path] then
                seen_paths[copy.path] = true
                copy.title = leaf
                copies[#copies + 1] = copy
            end
        end
    end
    return copies
end

function M:genAllBackupsMenu()
    local items = {}
    local all = self:allBackups()
    for __, copy in ipairs(all) do
        items[#items + 1] = {
            text = tostring(copy.title or "") .. " — " .. backupLabel(copy),
            mandatory = os.date("%Y-%m-%d", copy.modified),
            callback = function()
                self:askDeleteBackup(copy)
            end,
        }
    end
    if #all > 0 then
        items[#items].separator = true
        items[#items + 1] = {
            text = _("Delete all backup copies…"),
            callback = function()
                local list = self:allBackups()
                UIManager:scheduleIn(0.1, function()
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Delete all %1 backup copies (.bak)?\n\nIt cannot be undone."), #list),
                        ok_text = _("Delete"),
                        cancel_text = _("Keep"),
                        ok_callback = function()
                            local removed = 0
                            for __, c in ipairs(list) do
                                if os.remove(c.path) then
                                    removed = removed + 1
                                end
                            end
                            UIManager:show(Notification:new{
                                text = T(_("%1 backup copies deleted."), removed),
                                timeout = 3,
                            })
                        end,
                    })
                end)
            end,
        }
    else
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
                if self.book_cache then
                    self.book_cache[current] = nil
                end
                self:runExport({ current }, { force = true })
            end,
        }
    end
    rows[#rows + 1] = {
        text = withIcon("\xEE\xA4\xB5", _("All books")),
        separator = true,
        sub_item_table = {
            {
                text = withIcon("\xEE\xA4\xB5", _("Export changed books")),
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
                text = withIcon("\xEE\xA7\x99", _("Export all books again…")),
                enabled_func = function()
                    return #self:listBookFiles() > 0
                end,
                callback = function(touchmenu)
                    if touchmenu and touchmenu.closeMenu then
                        touchmenu:closeMenu()
                    end
                    self:runExport(self:listBookFiles(), {})
                end,
            },
            {
                text = withIcon("\xEE\xB9\x94", _("Select books…")),
                sub_item_table_func = function()
                    return self:genPickerMenu()
                end,
            },
            {
                text = withIcon("\xEF\x87\xAA", _("Export reading digest")),
                enabled_func = function()
                    return #self:listBookFiles() > 0
                end,
                callback = function(touchmenu)
                    self:exportDigest(touchmenu)
                end,
            },
        },
    }
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

-- The rows that name the open book. Book summary is first (identity card),
-- followed by Special highlights if any, then Book info and Book visibility
-- (radio submenu), then Keep my notes + heading + backups, and Format & layout.
function M:genCurrentBookMenu()
    local file = self:getCurrentFile()
    local rows = {}
    if not (self.ui and self.ui.document) or not file then
        return rows
    end
    local specials = self:bookSpecialHighlights(file)
    rows[#rows + 1] = {
        text = _("Book summary"),
        separator = #specials == 0,
        callback = function()
            self:showBookSummaryCard(file)
        end,
    }
    if #specials > 0 then
        rows[#rows + 1] = {
            text = "★ " .. _("Special highlights"),
            mandatory = tostring(#specials),
            separator = true,
            callback = function()
                self:openSpecialHighlights(file)
            end,
        }
    end
    rows[#rows + 1] = {
        text = _("Book info"),
        sub_item_table_func = function()
            return self:genBookInfoMenu(file)
        end,
    }
    rows[#rows + 1] = {
        text_func = function()
            return self:bookVisibilityLabel(file)
        end,
        separator = true,
        sub_item_table_func = function()
            return self:genBookVisibilityMenu(file)
        end,
    }
    local has_notes_heading = not getSetting("preserve", false) and getBookPreserve(file)
    local has_backups = #self:bookBackups(file) > 0
    rows[#rows + 1] = {
        text = _("Keep my notes in this book"),
        separator = not has_notes_heading and not has_backups,
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
                UIManager:scheduleIn(0.1, function()
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Turn off Keep my notes for %1? Your notes will not be lost. A .bak copy is created."), ffiUtil.basename(current)),
                        ok_text = _("Turn off"),
                        cancel_text = _("Keep it on"),
                        cancel_callback = function() end,
                        ok_callback = function()
                            setBookPreserve(current, false)
                            self:invalidateExportHash(current)
                            self:runExport({ current }, {})
                            self:refreshCurrentBookMenu(touchmenu)
                        end,
                    })
                end)
                return
            end
            setBookPreserve(current, true)
            self:invalidateExportHash(current)
            self:refreshCurrentBookMenu(touchmenu)
        end,
    }
    if has_notes_heading then
        rows[#rows + 1] = {
            text_func = function()
                return T(_("Notes heading: %1"), getNotesTitle(file))
            end,
            separator = not has_backups,
            callback = function(touchmenu)
                self:editNotesTitle(touchmenu, file)
            end,
        }
    end
    if has_backups then
        rows[#rows + 1] = {
            text = withIcon("\xEF\x83\x87", _("Backup copies")),
            separator = true,
            sub_item_table_func = function()
                return self:genBackupsMenu(file)
            end,
        }
    end
    rows[#rows + 1] = {
        text = _("Format & layout"),
        sub_item_table_func = function()
            return self:genBookStyleMenu(file)
        end,
    }
    return rows
end

-- Shared helper to build Tomedown's rounded dashboard/quote card with clean
-- framebuffer repaint on close (onCloseWidget) and button show_parent wiring.
local function buildTomedownCard(column, btn_specs, content_w, pad, extra_buttons)
    local Screen = Device.screen
    local Geom = require("ui/geometry")
    local Size = require("ui/size")
    local Blitbuffer = require("ffi/blitbuffer")
    local Button = require("ui/widget/button")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local GestureRange = require("ui/gesturerange")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local LineWidget = require("ui/widget/linewidget")
    local MovableContainer = require("ui/widget/container/movablecontainer")
    local VerticalSpan = require("ui/widget/verticalspan")

    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local gap_m = Screen:scaleBySize(14)

    column[#column + 1] = VerticalSpan:new{ width = gap_m }
    column[#column + 1] = LineWidget:new{
        dimen = Geom:new{ w = content_w, h = (Size.line and Size.line.thin) or 1 },
        background = Blitbuffer.COLOR_LIGHT_GRAY,
    }
    column[#column + 1] = VerticalSpan:new{ width = gap_m }

    local dialog
    local btn_gap = Screen:scaleBySize(10)
    local btn_w = math.floor((content_w - btn_gap * (#btn_specs - 1)) / #btn_specs)
    local btn_row = HorizontalGroup:new{ align = "center" }
    local created_btns = {}
    for idx, spec in ipairs(btn_specs) do
        if idx > 1 then
            btn_row[#btn_row + 1] = HorizontalSpan:new{ width = btn_gap }
        end
        local cb = spec.callback
        local b = Button:new{
            text = spec.text,
            width = btn_w,
            bordersize = (Size.border and Size.border.button) or 1,
            radius = (Size.radius and Size.radius.button) or 4,
            text_font_face = "cfont",
            text_font_size = 15,
            callback = function()
                if cb then
                    cb(dialog)
                end
            end,
        }
        created_btns[#created_btns + 1] = b
        btn_row[#btn_row + 1] = b
    end
    column[#column + 1] = btn_row

    local frame = FrameContainer:new{
        radius = Size.radius.window,
        padding = pad,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        column,
    }
    local movable = MovableContainer:new{ frame }

    dialog = InputContainer:new{
        align = "center",
        dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
        CenterContainer:new{
            dimen = Geom:new{ w = sw, h = sh },
            movable,
        },
    }
    for __, b in ipairs(created_btns) do
        b.show_parent = dialog
    end
    for __, b in ipairs(extra_buttons or {}) do
        b.show_parent = dialog
    end
    dialog.onShow = function()
        UIManager:setDirty(dialog, function()
            return "ui", movable.dimen or frame.dimen
        end)
    end
    dialog.onCloseWidget = function()
        UIManager:setDirty(nil, function()
            return "flashui", movable.dimen or frame.dimen
        end)
    end
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
    return dialog
end

function M:showBookSummaryCard(file)
    if not file then
        return
    end
    local Screen = Device.screen
    local Geom = require("ui/geometry")
    local Size = require("ui/size")
    local Blitbuffer = require("ffi/blitbuffer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local LineWidget = require("ui/widget/linewidget")
    local TextWidget = require("ui/widget/textwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")

    local open = self:openReader(file)
    local live = open and open.annotation and open.annotation.annotations
    local ok_b, book = pcall(self.buildBook, self, file, live)
    book = ok_b and book or nil

    local props = open and open.document and open.document.getProps and open.document:getProps() or {}
    local title = (book and book.title) or props.title or ffiUtil.basename(tostring(file))
    local author = (book and book.author) or props.authors or ""
    local annots = (book and book.annotations) or {}
    local hl_count = #annots
    local sp_count, note_count = 0, 0
    for __, a in ipairs(annots) do
        if a.special then sp_count = sp_count + 1 end
        if a.note and tostring(a.note) ~= "" then note_count = note_count + 1 end
    end

    local sw = Screen:getWidth()
    local frame_w = math.min(math.floor(sw * 0.86), Screen:scaleBySize(460))
    local pad = Screen:scaleBySize(22)
    local content_w = frame_w - pad * 2
    local gap_s = Screen:scaleBySize(8)
    local gap_m = Screen:scaleBySize(14)

    local function divider()
        return LineWidget:new{
            dimen = Geom:new{ w = content_w, h = (Size.line and Size.line.thin) or 1 },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        }
    end
    local function ptfRow(label, value)
        return TextBoxWidget:new{
            text = TextBoxWidget.PTF_HEADER
                .. TextBoxWidget.PTF_BOLD_START .. label .. TextBoxWidget.PTF_BOLD_END
                .. " " .. tostring(value or ""),
            face = Font:getFace("cfont", 14),
            width = content_w,
        }
    end

    local column = VerticalGroup:new{ align = "center" }
    column[#column + 1] = TextBoxWidget:new{
        text = TextBoxWidget.PTF_HEADER
            .. TextBoxWidget.PTF_BOLD_START .. tostring(title) .. TextBoxWidget.PTF_BOLD_END,
        face = Font:getFace("tfont", 20),
        alignment = "center",
        width = content_w,
    }
    if author and author ~= "" and author ~= "N/A" then
        column[#column + 1] = VerticalSpan:new{ width = Screen:scaleBySize(4) }
        column[#column + 1] = TextWidget:new{
            text = tostring(author),
            face = Font:getFace("cfont", 14),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = content_w,
        }
    end

    column[#column + 1] = VerticalSpan:new{ width = gap_m }
    column[#column + 1] = divider()
    column[#column + 1] = VerticalSpan:new{ width = gap_m }

    local col_w = math.floor(content_w / 3)
    local Button = require("ui/widget/button")
    local dialog
    local extra_btns = {}
    local function kpiTile(num, caption, on_tap)
        local n = num or 0
        local num_widget
        if on_tap and n > 0 then
            num_widget = Button:new{
                text = tostring(n),
                width = col_w - Screen:scaleBySize(12),
                bordersize = (Size.line and Size.line.thin) or 1,
                radius = (Size.radius and Size.radius.button) or 4,
                padding_v = Screen:scaleBySize(4),
                text_font_face = "tfont",
                text_font_size = 22,
                text_font_bold = true,
                callback = function()
                    if dialog then
                        UIManager:close(dialog)
                    end
                    on_tap()
                end,
            }
            extra_btns[#extra_btns + 1] = num_widget
        else
            num_widget = TextWidget:new{
                text = tostring(n),
                face = Font:getFace("tfont", 22),
                bold = true,
            }
        end
        return CenterContainer:new{
            dimen = Geom:new{ w = col_w, h = Screen:scaleBySize(64) },
            VerticalGroup:new{
                align = "center",
                num_widget,
                VerticalSpan:new{ width = Screen:scaleBySize(4) },
                TextWidget:new{
                    text = caption,
                    face = Font:getFace("cfont", 12),
                    fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                },
            },
        }
    end
    column[#column + 1] = HorizontalGroup:new{
        align = "center",
        kpiTile(hl_count, _("Highlights"), function()
            self:openBookHighlights(file, "all")
        end),
        kpiTile(sp_count, "★ " .. _("Special"), function()
            self:openBookHighlights(file, "special")
        end),
        kpiTile(note_count, _("Notes"), function()
            self:openBookHighlights(file, "notes")
        end),
    }

    column[#column + 1] = VerticalSpan:new{ width = gap_m }
    column[#column + 1] = divider()
    column[#column + 1] = VerticalSpan:new{ width = gap_m }

    local details = VerticalGroup:new{ align = "left" }
    local fmt_labels = {
        md = _("Markdown (.md)"),
        txt = _("Plain text (.txt)"),
        both = _("Both (.md and .txt)"),
    }
    local style_labels = {
        obsidian = _("Obsidian"),
        standard = _("Standard"),
    }
    local cur_fmt = getExportFormat(file)
    local fmt_desc = fmt_labels[cur_fmt] or fmt_labels.md
    if cur_fmt ~= "txt" then
        fmt_desc = fmt_desc .. " · " .. (style_labels[shared.getMarkdownStyle(file)] or style_labels.obsidian)
    end
    details[#details + 1] = ptfRow(_("Format:"), fmt_desc)

    local exports = getSetting("exports", {})
    local rec = exports[file]
    local exp_status = _("Not exported yet")
    if rec and rec.hash then
        exp_status = (book and book.hash == rec.hash)
            and _("Up to date") or _("Updates pending")
    end
    details[#details + 1] = VerticalSpan:new{ width = gap_s }
    details[#details + 1] = ptfRow(_("Status") .. ":", exp_status)

    local btags = book and book.tags or getBookTags(file)
    if type(btags) == "table" and #btags > 0 then
        local tag_pills = {}
        for __, tg in ipairs(btags) do
            tag_pills[#tag_pills + 1] = "#" .. tostring(tg)
        end
        details[#details + 1] = VerticalSpan:new{ width = gap_s }
        details[#details + 1] = ptfRow(_("Tags") .. ":", table.concat(tag_pills, " "))
    end
    column[#column + 1] = details

    local btn_specs = {
        {
            text = _("Export this book"),
            callback = function(dlg)
                UIManager:close(dlg)
                self:runExport({ file }, { force = true })
            end,
        },
        {
            text = _("Close"),
            callback = function(dlg)
                UIManager:close(dlg)
            end,
        },
    }
    dialog = buildTomedownCard(column, btn_specs, content_w, pad, extra_btns)
    UIManager:show(dialog)
end

function M:bookHighlights(file, filter)
    local out = {}
    local open = self:openReader(file)
    local annots = open and open.annotation and open.annotation.annotations
    if type(annots) ~= "table" and file then
        local ok_ds, DocSettings = pcall(require, "docsettings")
        if ok_ds and DocSettings and type(DocSettings.open) == "function" then
            local ok_open, ds = pcall(DocSettings.open, DocSettings, file)
            if ok_open and ds then
                annots = ds:readSetting("annotations")
            end
        end
    end
    if type(annots) ~= "table" then
        return out
    end
    for __, item in ipairs(annots) do
        if type(item) == "table" and item.drawer ~= nil and not item.deleted
                and type(item.text) == "string" and item.text ~= "" then
            if filter == "special" then
                if item.tomedown_special then out[#out + 1] = item end
            elseif filter == "notes" then
                if type(item.note) == "string" and item.note ~= "" then out[#out + 1] = item end
            else
                out[#out + 1] = item
            end
        end
    end
    return out
end

function M:bookSpecialHighlights(file)
    return self:bookHighlights(file, "special")
end

function M:openSpecialHighlights(file)
    return self:openBookHighlights(file, "special")
end

function M:openBookHighlights(file, filter, page_num)
    filter = filter or "all"
    local list = self:bookHighlights(file, filter)
    if #list == 0 then
        return
    end
    local open = self:openReader(file)
    local Button = require("ui/widget/button")
    local Event = require("ui/event")
    local Geom = require("ui/geometry")
    local Size = require("ui/size")
    local Blitbuffer = require("ffi/blitbuffer")
    local LineWidget = require("ui/widget/linewidget")
    local TextWidget = require("ui/widget/textwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local Screen = Device.screen

    local function snippet(text, max)
        local s = tostring(text or ""):gsub("%s*\n%s*", " "):gsub("^%s+", ""):gsub("%s+$", "")
        if #s <= max then return s end
        s = s:sub(1, max - 1)
        while #s > 0 and s:byte(#s) >= 128 and s:byte(#s) < 192 do s = s:sub(1, -2) end
        if #s > 0 and s:byte(#s) >= 192 then s = s:sub(1, -2) end
        return s .. "…"
    end

    local function jumpToItem(item)
        if not open or not item then return end
        if type(item.pos0) == "string" and item.pos0:sub(1, 1) == "/" then
            open:handleEvent(Event:new("GotoXPointer", item.pos0))
        elseif type(item.page) == "string" and item.page:sub(1, 1) == "/" then
            open:handleEvent(Event:new("GotoXPointer", item.page))
        elseif tonumber(item.pageno or item.page) then
            open:handleEvent(Event:new("GotoPage", tonumber(item.pageno or item.page)))
        end
    end

    local function cardTitle(count)
        if filter == "special" then
            return "★ " .. _("Special highlights") .. " (" .. tostring(count) .. ")"
        elseif filter == "notes" then
            return _("Notes") .. " (" .. tostring(count) .. ")"
        end
        return _("Highlights") .. " (" .. tostring(count) .. ")"
    end

    -- Adapt items per page to screen height so Kindle/Kobo 6" (portrait & landscape) never overflow
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local per_page = sh >= Screen:scaleBySize(720) and 4 or 3
    local total_pages = math.max(1, math.ceil(#list / per_page))
    local cur_page = math.max(1, math.min(page_num or 1, total_pages))
    local first_idx = (cur_page - 1) * per_page + 1
    local last_idx = math.min(#list, first_idx + per_page - 1)

    local frame_w = math.min(math.floor(sw * 0.88), Screen:scaleBySize(480))
    local pad = Screen:scaleBySize(20)
    local content_w = frame_w - pad * 2
    local gap_s = Screen:scaleBySize(6)
    local gap_m = Screen:scaleBySize(12)

    local function divider()
        return LineWidget:new{
            dimen = Geom:new{ w = content_w, h = (Size.line and Size.line.thin) or 1 },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        }
    end

    local is_notes = (filter == "notes")
    local column = VerticalGroup:new{ align = "center" }
    column[#column + 1] = TextWidget:new{
        text = cardTitle(#list),
        face = Font:getFace("tfont", 20),
        bold = true,
    }
    column[#column + 1] = VerticalSpan:new{ width = Screen:scaleBySize(3) }
    local sub_parts = {}
    if total_pages > 1 then
        sub_parts[#sub_parts + 1] = string.format("%d / %d", cur_page, total_pages)
    end
    sub_parts[#sub_parts + 1] = is_notes
        and _("Tap to jump · Hold to edit")
        or _("Tap to jump · Hold for ★")
    column[#column + 1] = TextWidget:new{
        text = table.concat(sub_parts, "  ·  "),
        face = Font:getFace("cfont", 12),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        max_width = content_w,
    }
    column[#column + 1] = VerticalSpan:new{ width = gap_m }
    column[#column + 1] = divider()

    local card_dialog
    local row_buttons = {}
    local list_group = VerticalGroup:new{ align = "left" }

    for i = first_idx, last_idx do
        local item = list[i]
        if i > first_idx then
            list_group[#list_group + 1] = divider()
        end

        local has_note = type(item.note) == "string" and item.note ~= ""
        local prefix = item.tomedown_special and "★ " or "• "
        if has_note then
            prefix = prefix .. "✎ "
        end

        local loc = {}
        if type(item.chapter) == "string" and item.chapter ~= "" then
            loc[#loc + 1] = item.chapter
        end
        if item.pageno then
            loc[#loc + 1] = "p. " .. tostring(item.pageno)
        end
        if is_notes and type(item.text) == "string" and item.text ~= "" then
            loc[#loc + 1] = "“" .. snippet(item.text, 40) .. "”"
        end

        local row_label = is_notes
            and ("✎ " .. snippet(item.note, 90))
            or (prefix .. snippet(item.text, 85))

        list_group[#list_group + 1] = VerticalSpan:new{ width = gap_s }
        local row_btn = Button:new{
            text = row_label,
            align = "left",
            width = content_w,
            bordersize = 0,
            padding_h = 0,
            padding_v = Screen:scaleBySize(4),
            text_font_face = "cfont",
            text_font_size = 14,
            text_font_bold = false,
            callback = function()
                if card_dialog then
                    UIManager:close(card_dialog)
                end
                jumpToItem(item)
            end,
            hold_callback = function()
                if is_notes then
                    local edit_dlg
                    edit_dlg = InputDialog:new{
                        title = _("Edit note"),
                        input = tostring(item.note or ""),
                        allow_newline = true,
                        buttons = {
                            {
                                {
                                    text = _("Cancel"),
                                    callback = function()
                                        UIManager:close(edit_dlg)
                                    end,
                                },
                                {
                                    text = _("Save"),
                                    is_enter_default = true,
                                    callback = function()
                                        local raw = tostring(edit_dlg:getInputText() or "")
                                        local clean = raw:gsub("^%s+", ""):gsub("%s+$", "")
                                        item.note = (clean ~= "") and clean or nil
                                        item.datetime_updated = os.date("%Y-%m-%d %H:%M:%S")
                                        if open and open.doc_settings and open.annotation then
                                            open.doc_settings:saveSetting("annotations", open.annotation.annotations)
                                            if type(open.doc_settings.flush) == "function" then
                                                open.doc_settings:flush()
                                            end
                                        end
                                        UIManager:close(edit_dlg)
                                        if card_dialog then
                                            UIManager:close(card_dialog)
                                        end
                                        self:openBookHighlights(file, filter, cur_page)
                                    end,
                                },
                            },
                        },
                    }
                    UIManager:show(edit_dlg)
                    edit_dlg:onShowKeyboard()
                    return
                end
                local marked = not item.tomedown_special
                item.tomedown_special = marked or nil
                if open and open.doc_settings and open.annotation then
                    open.doc_settings:saveSetting("annotations", open.annotation.annotations)
                end
                UIManager:show(Notification:new{
                    text = marked and _("Highlight marked as special")
                        or _("Special mark removed"),
                    timeout = 1.5,
                })
                if card_dialog then
                    UIManager:close(card_dialog)
                end
                self:openBookHighlights(file, filter, cur_page)
            end,
        }
        row_buttons[#row_buttons + 1] = row_btn
        list_group[#list_group + 1] = row_btn
        if #loc > 0 then
            list_group[#list_group + 1] = TextWidget:new{
                text = table.concat(loc, "  ·  "),
                face = Font:getFace("cfont", 12),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                max_width = content_w,
            }
        end
        list_group[#list_group + 1] = VerticalSpan:new{ width = gap_s }
    end

    column[#column + 1] = list_group

    local btn_specs = {}
    if total_pages > 1 then
        btn_specs[#btn_specs + 1] = {
            text = "◀",
            callback = function(dlg)
                if cur_page > 1 then
                    UIManager:close(dlg)
                    self:openBookHighlights(file, filter, cur_page - 1)
                end
            end,
        }
        btn_specs[#btn_specs + 1] = {
            text = "▶",
            callback = function(dlg)
                if cur_page < total_pages then
                    UIManager:close(dlg)
                    self:openBookHighlights(file, filter, cur_page + 1)
                end
            end,
        }
    end
    btn_specs[#btn_specs + 1] = {
        text = _("Close"),
        callback = function(dlg)
            UIManager:close(dlg)
        end,
    }

    card_dialog = buildTomedownCard(column, btn_specs, content_w, pad, row_buttons)
    UIManager:show(card_dialog)
end

-- Per-book style and format overrides for the open book. Each option can
-- either follow the global setting or be pinned for this book alone.
function M:genBookStyleMenu(file, target_table)
    local rows = target_table or {}
    for i = #rows, 1, -1 do
        rows[i] = nil
    end
    if not file then
        return rows
    end

    local function choiceRow(title_tmpl, key, effective_fn, labels, options, sep, on_change)
        local sub = {
            {
                text = _("Follow global setting"),
                radio = true,
                keep_menu_open = true,
                separator = true,
                checked_func = function()
                    return getBookStyleOverride(file, key) == nil
                end,
                callback = function(touchmenu)
                    if getBookStyleOverride(file, key) ~= nil then
                        setBookStyleOverride(file, key, nil)
                        self:invalidateExportHash(file)
                        if on_change then
                            on_change(touchmenu)
                        end
                    end
                end,
            },
        }
        for __, opt in ipairs(options) do
            local val = opt.val
            local opt_enabled_fn = opt.enabled_func
            local opt_checked_fn = opt.checked_func
            sub[#sub + 1] = {
                text = opt.text,
                radio = true,
                keep_menu_open = true,
                enabled_func = opt_enabled_fn,
                checked_func = opt_checked_fn or function()
                    return getBookStyleOverride(file, key) == val
                end,
                callback = function(touchmenu)
                    if getBookStyleOverride(file, key) ~= val then
                        setBookStyleOverride(file, key, val)
                        self:invalidateExportHash(file)
                        if on_change then
                            on_change(touchmenu)
                        end
                    end
                end,
            }
        end
        return {
            key = key,
            separator = sep,
            text_func = function()
                local cur = effective_fn(file)
                return T(title_tmpl, labels[cur] or tostring(cur))
            end,
            mandatory_func = function()
                return getBookStyleOverride(file, key) == nil
                    and _("Global") or _("Custom")
            end,
            sub_item_table = sub,
        }
    end

    rows[#rows + 1] = choiceRow(
        _("Export format: %1"),
        "export_format",
        getExportFormat,
        {
            md = _("Markdown (.md)"),
            txt = _("Plain text (.txt)"),
            both = _("Both (.md and .txt)"),
        },
        {
            { val = "md",   text = _("Markdown (.md)") },
            { val = "txt",  text = _("Plain text (.txt)") },
            { val = "both", text = _("Both (.md and .txt)") },
        },
        getExportFormat(file) == "txt",
        function(touchmenu)
            self:refreshBookStyleMenu(touchmenu, file, rows)
        end
    )

    if getExportFormat(file) ~= "txt" then
        rows[#rows + 1] = choiceRow(
            _("Markdown style: %1"),
            "markdown_style",
            shared.getMarkdownStyle,
            {
                obsidian = _("Obsidian"),
                standard = _("Standard"),
            },
            {
                { val = "obsidian", text = _("Obsidian") },
                { val = "standard", text = _("Standard") },
            },
            true,
            function(touchmenu)
                self:refreshBookStyleMenu(touchmenu, file, rows)
            end
        )
    end

    rows[#rows + 1] = choiceRow(
        _("Personal notes format: %1"),
        "note_style",
        getNoteStyle,
        {
            inline = _("Inline"),
            footnote = _("Footnotes"),
        },
        {
            { val = "inline",   text = _("Inline") },
            { val = "footnote", text = _("Footnotes") },
        }
    )

    rows[#rows + 1] = choiceRow(
        _("Highlight details: %1"),
        "highlight_details",
        getHighlightDetails,
        {
            page_date = _("Page and date"),
            page_only = _("Page only"),
            date_only = _("Date only"),
            none = _("None"),
        },
        {
            { val = "page_date", text = _("Page and date") },
            { val = "page_only", text = _("Page only") },
            { val = "date_only", text = _("Date only") },
            { val = "none",      text = _("None") },
        }
    )

    rows[#rows + 1] = choiceRow(
        _("Chapter headings: %1"),
        "chapter_headings",
        getChapterHeadings,
        {
            h1 = _("Heading 1 (# Chapter)"),
            h2 = _("Heading 2 (## Chapter)"),
            h3 = _("Heading 3 (### Chapter)"),
            none = _("None (continuous list)"),
        },
        {
            { val = "h1",   text = _("Heading 1 (# Chapter)") },
            { val = "h2",   text = _("Heading 2 (## Chapter)") },
            { val = "h3",   text = _("Heading 3 (### Chapter)") },
            { val = "none", text = _("None (continuous list)") },
        }
    )

    rows[#rows + 1] = choiceRow(
        _("Highlight context: %1"),
        "highlight_context",
        getHighlightContext,
        {
            [true] = _("Enabled"),
            [false] = _("Disabled"),
        },
        {
            { val = true,  text = _("Enabled") },
            { val = false, text = _("Disabled") },
        },
        true
    )

    rows[#rows + 1] = choiceRow(
        _("Book cover: %1"),
        "covers",
        getBookCovers,
        {
            [true] = _("Enabled"),
            [false] = _("Disabled"),
        },
        {
            { val = true,  text = _("Enabled") },
            { val = false, text = _("Disabled") },
        }
    )

    rows[#rows + 1] = choiceRow(
        _("Page bookmarks: %1"),
        "include_bookmarks",
        getIncludeBookmarks,
        {
            [true] = _("Enabled"),
            [false] = _("Disabled"),
        },
        {
            { val = true,  text = _("Enabled") },
            { val = false, text = _("Disabled") },
        }
    )

    rows[#rows + 1] = choiceRow(
        _("Handwritten notes: %1"),
        "include_handwritten",
        shared.getIncludeHandwritten,
        {
            [true] = _("Enabled"),
            [false] = _("Disabled"),
        },
        {
            { val = true,  text = _("Enabled") },
            { val = false, text = _("Disabled") },
        },
        true
    )

    -- Book page submenu in Current book -> Format & layout:
    -- groups title in body, overview style, harmonize/diversify, and the
    -- 4 book sections onto one single KOReader menu page.
    local book_card_keys = {
        "book_heading", "overview_style", "harmonize_book_style",
        "book_visual_style", "reading_dashboard", "dashboard_style",
        "book_synopsis", "synopsis_mode", "synopsis_style",
        "body_tags", "body_tags_style", "special_showcase", "showcase_style",
    }
    local book_card_rows = {}
    local function buildBookCardMenu(target)
        local c_rows = target or {}
        for i = #c_rows, 1, -1 do
            c_rows[i] = nil
        end
        local function refreshCardMenu(touchmenu)
            buildBookCardMenu(c_rows)
            if touchmenu and touchmenu.item_table == c_rows and touchmenu.updateItems then
                touchmenu:updateItems()
            end
        end
        local visual_style_labels = {
            minimal   = _("Minimal symbols (● / ◐)"),
            emoji     = _("Emoji (🟢 / 🟡)"),
            badges    = _("Code badges (`READING`)"),
            editorial = _("Editorial (Reading)"),
        }
        local visual_style_options = {
            { val = "minimal",   text = _("Minimal symbols (● / ◐)") },
            { val = "emoji",     text = _("Emoji (🟢 / 🟡)") },
            { val = "badges",    text = _("Code badges (`READING`)") },
            { val = "editorial", text = _("Editorial (Reading)") },
        }
        local function makeBookVisualStyleRow(title_tmpl, key, getter, enabled_fn, sep)
            local r = choiceRow(title_tmpl, key, getter, visual_style_labels, visual_style_options, sep)
            if enabled_fn then
                r.enabled_func = enabled_fn
            end
            return r
        end

        c_rows[#c_rows + 1] = choiceRow(
            _("Book title in body: %1"),
            "book_heading",
            shared.getBookHeading,
            {
                [true] = _("Enabled"),
                [false] = _("Disabled"),
            },
            {
                { val = true,  text = _("Enabled") },
                { val = false, text = _("Disabled") },
            }
        )

        c_rows[#c_rows + 1] = choiceRow(
            _("Overview style: %1"),
            "overview_style",
            function(f)
                local cur = shared.getOverviewStyle(f)
                if shared.getMarkdownStyle(f) == "standard" and cur == "callout" then
                    return "blockquote"
                end
                return cur
            end,
            {
                inline     = _("Inline / Heading"),
                blockquote = _("Classic blockquote"),
                callout    = _("Callout ([!summary])"),
                table      = _("Table"),
            },
            {
                { val = "inline",     text = _("Inline / Heading") },
                {
                    val = "blockquote",
                    text = _("Classic blockquote"),
                    checked_func = function()
                        local ov = getBookStyleOverride(file, "overview_style")
                        return ov == "blockquote"
                            or (shared.getMarkdownStyle(file) == "standard" and ov == "callout")
                    end,
                },
                {
                    val = "callout",
                    text = _("Callout ([!summary])"),
                    enabled_func = function()
                        return shared.getMarkdownStyle(file) ~= "standard"
                    end,
                    checked_func = function()
                        return shared.getMarkdownStyle(file) ~= "standard"
                            and getBookStyleOverride(file, "overview_style") == "callout"
                    end,
                },
                { val = "table",      text = _("Table") },
            },
            true
        )

        c_rows[#c_rows + 1] = choiceRow(
            _("Reading dashboard: %1"),
            "reading_dashboard",
            shared.getReadingDashboard,
            {
                [true] = _("Enabled"),
                [false] = _("Disabled"),
            },
            {
                { val = true,  text = _("Enabled") },
                { val = false, text = _("Disabled") },
            },
            false,
            refreshCardMenu
        )

        c_rows[#c_rows + 1] = choiceRow(
            _("Book synopsis: %1"),
            "book_synopsis",
            shared.getBookSynopsis,
            {
                [true] = _("Enabled"),
                [false] = _("Disabled"),
            },
            {
                { val = true,  text = _("Enabled") },
                { val = false, text = _("Disabled") },
            },
            false,
            refreshCardMenu
        )
        local syn_mode_row = choiceRow(
            _("Synopsis display: %1"),
            "synopsis_mode",
            shared.getSynopsisMode,
            {
                collapsed       = _("Collapsed (foldable)"),
                short           = _("Short preview (~300 chars)"),
                collapsed_short = _("Collapsed + Short preview"),
                expanded        = _("Expanded (full text)"),
            },
            {
                { val = "collapsed",       text = _("Collapsed (foldable)") },
                { val = "short",           text = _("Short preview (~300 chars)") },
                { val = "collapsed_short", text = _("Collapsed + Short preview") },
                { val = "expanded",        text = _("Expanded (full text)") },
            },
            true
        )
        syn_mode_row.enabled_func = function()
            return shared.getBookSynopsis(file)
        end
        c_rows[#c_rows + 1] = syn_mode_row

        c_rows[#c_rows + 1] = choiceRow(
            _("Tags in body: %1"),
            "body_tags",
            shared.getBodyTags,
            {
                [true] = _("Enabled"),
                [false] = _("Disabled"),
            },
            {
                { val = true,  text = _("Enabled") },
                { val = false, text = _("Disabled") },
            },
            false,
            refreshCardMenu
        )

        c_rows[#c_rows + 1] = choiceRow(
            _("Special highlights showcase: %1"),
            "special_showcase",
            shared.getSpecialShowcase,
            {
                [true] = _("Enabled"),
                [false] = _("Disabled"),
            },
            {
                { val = true,  text = _("Enabled") },
                { val = false, text = _("Disabled") },
            },
            true,
            refreshCardMenu
        )

        local sec_style_keys = {
            "harmonize_book_style", "book_visual_style", "dashboard_style",
            "synopsis_style", "body_tags_style", "showcase_style",
        }
        local book_sec_style_rows = {}
        local function buildBookSecStyleMenu(st_target)
            local s_rows = st_target or {}
            for i = #s_rows, 1, -1 do
                s_rows[i] = nil
            end
            local function refreshSecStyle(touchmenu)
                buildBookSecStyleMenu(s_rows)
                if touchmenu and touchmenu.item_table == s_rows and touchmenu.updateItems then
                    touchmenu:updateItems()
                end
            end
            local book_harmonized = shared.getHarmonizeBookStyle(file)
            s_rows[#s_rows + 1] = choiceRow(
                _("Harmonize book styles: %1"),
                "harmonize_book_style",
                shared.getHarmonizeBookStyle,
                {
                    [true] = _("Enabled"),
                    [false] = _("Disabled"),
                },
                {
                    { val = true,  text = _("Enabled") },
                    { val = false, text = _("Disabled") },
                },
                true,
                refreshSecStyle
            )
            if book_harmonized then
                s_rows[#s_rows + 1] = makeBookVisualStyleRow(
                    _("Book style: %1"),
                    "book_visual_style",
                    shared.getBookVisualStyle
                )
            else
                s_rows[#s_rows + 1] = makeBookVisualStyleRow(
                    _("Dashboard style: %1"),
                    "dashboard_style",
                    shared.getDashboardStyle,
                    function()
                        return shared.getReadingDashboard(file)
                    end
                )
                s_rows[#s_rows + 1] = makeBookVisualStyleRow(
                    _("Synopsis style: %1"),
                    "synopsis_style",
                    shared.getSynopsisStyle,
                    function()
                        return shared.getBookSynopsis(file)
                    end
                )
                s_rows[#s_rows + 1] = makeBookVisualStyleRow(
                    _("Tags style: %1"),
                    "body_tags_style",
                    shared.getBodyTagsStyle,
                    function()
                        return shared.getBodyTags(file)
                    end
                )
                s_rows[#s_rows + 1] = makeBookVisualStyleRow(
                    _("Showcase style: %1"),
                    "showcase_style",
                    shared.getShowcaseStyle,
                    function()
                        return shared.getSpecialShowcase(file)
                    end
                )
            end
            return s_rows
        end
        buildBookSecStyleMenu(book_sec_style_rows)
        c_rows[#c_rows + 1] = {
            key = "book_card_style",
            text = _("Section styles"),
            mandatory_func = function()
                for __, k in ipairs(sec_style_keys) do
                    if getBookStyleOverride(file, k) ~= nil then
                        return _("Custom")
                    end
                end
                return _("Global")
            end,
            sub_item_table = book_sec_style_rows,
            sub_item_table_func = function()
                return buildBookSecStyleMenu(book_sec_style_rows)
            end,
        }
        return c_rows
    end
    buildBookCardMenu(book_card_rows)
    rows[#rows + 1] = {
        key = "book_card_sections",
        text = _("Book page"),
        mandatory_func = function()
            for __, k in ipairs(book_card_keys) do
                if getBookStyleOverride(file, k) ~= nil then
                    return _("Custom")
                end
            end
            return _("Global")
        end,
        sub_item_table = book_card_rows,
        sub_item_table_func = function()
            return buildBookCardMenu(book_card_rows)
        end,
    }

    rows[#rows + 1] = choiceRow(
        _("YAML frontmatter: %1"),
        "fm_enabled",
        getFrontmatterEnabled,
        {
            [true] = _("Enabled"),
            [false] = _("Disabled"),
        },
        {
            { val = true,  text = _("Enabled") },
            { val = false, text = _("Disabled") },
        },
        getFrontmatterEnabled(file) == false,
        function(touchmenu)
            self:refreshBookStyleMenu(touchmenu, file, rows)
        end
    )

    if getFrontmatterEnabled(file) then
        local sub_fields = self:genFrontmatterFieldsMenu(file)
        rows[#rows + 1] = {
            key = "fm_fields",
            text = _("Frontmatter fields"),
            separator = true,
            mandatory_func = function()
                local has_hidden = getBookStyleOverride(file, "fm_hidden") ~= nil
                local has_custom_on = getBookStyleOverride(file, "fm_custom_enabled") ~= nil
                local has_custom = getBookStyleOverride(file, "fm_custom_fields") ~= nil
                local has_order = getBookStyleOverride(file, "fm_order") ~= nil
                return (not has_hidden and not has_custom_on and not has_custom and not has_order)
                    and _("Global") or _("Custom")
            end,
            sub_item_table = sub_fields,
            sub_item_table_func = function()
                return self:genFrontmatterFieldsMenu(file, sub_fields)
            end,
        }
    end

    rows[#rows + 1] = {
        key = "reset_book_style",
        text = _("Reset to global style settings"),
        keep_menu_open = true,
        enabled_func = function()
            return hasBookStyleOverrides(file)
        end,
        callback = function(touchmenu)
            clearBookStyleOverrides(file)
            self:invalidateExportHash(file)
            self:refreshBookStyleMenu(touchmenu, file)
        end,
    }

    return rows
end

-- The metadata rows of the open book: tags are always there, followed
-- by Import book info or, once imported, by rating, review, status,
-- dates and Remove imported book info.
function M:genBookInfoMenu(file)
    local rows = {}
    if not file then
        return rows
    end
    rows[#rows + 1] = {
        text_func = function()
            local tags = currentBookTags(file)
            return T(_("Tags: %1"),
                #tags > 0 and table.concat(tags, ", ") or _("none"))
        end,
        callback = function(touchmenu)
            self:editBookTags(touchmenu, file)
        end,
        separator = true,
    }
    if not getBookImported(file) then
        rows[#rows + 1] = {
            text = _("Import book info"),
            callback = function(touchmenu)
                self:confirmImportBookInfo(file, touchmenu)
            end,
        }
    else
        -- rating, review and status use KOReader's own panel; the dates
        -- and the way out are Tomedown's own rows
        rows[#rows + 1] = {
            text_func = function()
                return self:bookInfoRatingLabel(file)
            end,
            callback = function()
                self:openBookStatusEditor(file)
            end,
        }
        rows[#rows + 1] = {
            text_func = function()
                return self:bookInfoReviewLabel(file)
            end,
            callback = function()
                self:openBookStatusEditor(file)
            end,
        }
        rows[#rows + 1] = {
            text_func = function()
                return self:bookInfoStatusRowLabel(file)
            end,
            callback = function()
                self:openBookStatusEditor(file)
            end,
        }
        rows[#rows + 1] = {
            text = _("Dates"),
            sub_item_table_func = function()
                return self:bookInfoDateMenu(file)
            end,
            separator = true,
        }
        rows[#rows + 1] = {
            text = _("Remove imported book info…"),
            callback = function(touchmenu)
                self:confirmRemoveBookInfo(file, touchmenu)
            end,
        }
    end
    return rows
end

-- The buttons Tomedown adds to KOReader's file dialog (the long press on
-- a file in the file manager, History, Collections and Bookshelf). The
-- same row serves every host: only the path arrives, never a document.
function M:genFileDialogButtons(file, is_file)
    if not file or not is_file then
        return nil
    end
    local buttons = {
        {
            text = _("Export this book"),
            enabled = BookList.hasBookBeenOpened(file),
            callback = function()
                self:runExport({ file }, { force = true })
            end,
        },
        {
            text = _("Tags…"),
            callback = function()
                self:editBookTags(nil, file)
            end,
        },
        {
            text = _("Book visibility…"),
            callback = function()
                self:editBookVisibility(file)
            end,
        },
    }
    if not getBookImported(file) then
        buttons[#buttons + 1] = {
            text = _("Import book info"),
            enabled = BookList.hasBookBeenOpened(file),
            callback = function()
                self:confirmImportBookInfo(file)
            end,
        }
    else
        buttons[#buttons + 1] = {
            text = _("Remove imported book info…"),
            callback = function()
                self:confirmRemoveBookInfo(file)
            end,
        }
    end
    return buttons
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

function M:refreshBookInfoMenu(touchmenu, file)
    if not touchmenu or not touchmenu.item_table then
        return
    end
    local live = touchmenu.item_table
    local fresh = self:genBookInfoMenu(file or self:getCurrentFile())
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

function M:refreshBookStyleMenu(touchmenu, file, target_table)
    local live = target_table or (touchmenu and touchmenu.item_table)
    if not live then
        return
    end
    self:genBookStyleMenu(file or self:getCurrentFile(), live)
    if touchmenu and touchmenu.item_table == live and touchmenu.updateItems then
        touchmenu:updateItems()
    end
end

function M:buildMenuItem()
    local item = {
        id = "tomedown",
        text = "Tomedown",
        icon = TOPBAR_ICON_NAME,
        sub_item_table_func = function()
            return self:genBookMenu()
        end,
    }
    local function populateRows()
        local fresh = self:genBookMenu()
        for i = #item, 1, -1 do
            item[i] = nil
        end
        for i, row in ipairs(fresh) do
            item[i] = row
        end
    end
    populateRows()
    item.callback = populateRows
    return item
end

function M:refreshMenuPlacement(touchmenu)
    local use_topbar = getTopbarIcon()
    ensureTopbarIconRegistered()
    applyMenuPlacement(use_topbar)
    local tabs = self.ui and self.ui.menu and self.ui.menu.tab_item_table
    if type(tabs) ~= "table" then
        return
    end
    -- Remove any existing tomedown entry from top-level tabs and first tab
    for i = #tabs, 1, -1 do
        if type(tabs[i]) == "table" and tabs[i].id == "tomedown" then
            table.remove(tabs, i)
        end
    end
    if type(tabs[1]) == "table" then
        for i = #tabs[1], 1, -1 do
            if type(tabs[1][i]) == "table" and tabs[1][i].id == "tomedown" then
                table.remove(tabs[1], i)
            end
        end
    end
    local item = self:buildMenuItem()
    local tomedown_tab_idx = 1
    if use_topbar then
        local pos
        for i, tab in ipairs(tabs) do
            if type(tab) == "table" and tab.id == "main" then
                pos = i
                break
            end
        end
        if not pos then
            pos = #tabs + 1
        end
        table.insert(tabs, pos, item)
        tomedown_tab_idx = pos
    elseif type(tabs[1]) == "table" then
        table.insert(tabs[1], 1, item)
        tomedown_tab_idx = 1
    end
    -- If TouchMenu is currently open, rebuild its top bar and navigation stack live
    if touchmenu and touchmenu.bar and type(touchmenu.bar.new) == "function"
            and touchmenu.tab_item_table == tabs then
        local icons = {}
        for _, v in ipairs(tabs) do
            table.insert(icons, v.icon)
        end
        touchmenu.bar = touchmenu.bar:new{
            width = touchmenu.width,
            icons = icons,
            show_parent = touchmenu.show_parent,
            menu = touchmenu,
        }
        touchmenu.cur_tab = tomedown_tab_idx
        if type(touchmenu.bar.switchToTab) == "function" then
            touchmenu.bar:switchToTab(tomedown_tab_idx)
        end
        if type(touchmenu.item_table_stack) == "table" then
            local settings_tbl = touchmenu.item_table_stack[#touchmenu.item_table_stack]
            if use_topbar then
                touchmenu.item_table_stack = { item }
                if settings_tbl and settings_tbl ~= item then
                    table.insert(touchmenu.item_table_stack, settings_tbl)
                end
            else
                touchmenu.item_table_stack = {}
                if type(tabs[1]) == "table" then
                    table.insert(touchmenu.item_table_stack, tabs[1])
                end
                table.insert(touchmenu.item_table_stack, item)
                if settings_tbl and settings_tbl ~= item then
                    table.insert(touchmenu.item_table_stack, settings_tbl)
                end
            end
        end
    end
end

function M:addToMainMenu(menu_items)
    if getSetting("update_check", false) then
        UIManager:scheduleIn(0.1, function()
            Update.checkBackground()
        end)
    end
    self:maybePromptLibraryImport()
    ensureTopbarIconRegistered()
    applyMenuPlacement(getTopbarIcon())
    -- Every row of the main menu carries a Nerd Font glyph (from
    -- nerdfonts/symbols.ttf, KOReader's own fallback font). Settings
    -- keeps its word plus the icon; inside, group labels and submenu
    -- rows are iconified - plain setting rows stay text-only.
    -- The main rows are fixed; the Current book submenu is built on
    -- open, so its per book rows read the book that is open right now.
    menu_items.tomedown = self:buildMenuItem()
end

return M
