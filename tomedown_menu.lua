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
        return _("Book visibility: hidden from the index")
    elseif state == "none" then
        return _("Book visibility: not exported")
    end
    return _("Book visibility: normal")
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
                local current = getSetting("index_layout", "tags_below")
                return T(_("Index layout: %1"),
                    labels[current] or labels.tags_below)
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
            text = _("Show Reading now in the index"),
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

    -- Book info: the imported fields are opt-in per book, the automatic
    -- update is one global switch for the books that were imported, and
    -- the bulk import is the one action that can cover the whole
    -- library at once. It carries its own confirmation.
    local function importableBookInfoFiles()
        local files = {}
        for __, file in ipairs(self:listBookFiles()) do
            -- "Do not export" is the reader's choice and stays one: the
            -- bulk action imports the books it can write, not those it
            -- was told to leave alone
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
        -- only the imported books are written, and only those whose
        -- information actually changed: a normal book keeps the file
        -- 1.2.0 left, exported date included
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
            text = withIcon("\xEF\x80\xAD", _("Import book info for all books")),
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
        { text = withIcon("\xEF\x81\x9A", _("Book info")), -- star-half
            sub_item_table = bookinfo },
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
        return _("Saved notes")
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
                -- asked for this book by name: "Do not export" stops
                -- automatic runs, not this one
                self:runExport({ current }, { force = true })
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
        text = _("Keep my notes in this book"),
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
        callback = function(touchmenu)
            self:editBookVisibility(file, touchmenu)
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
            text = withIcon("\xEF\x83\x87", _("Backup copies")),
            sub_item_table_func = function()
                return self:genBackupsMenu(file)
            end,
        }
    end
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
