--[[--
Tests for main.lua with a fake KOReader environment.

Covers: md5 hash, export, index, legacy .sdr format, menu, dialogs,
fallback servers, Koofr upload and above all the backoff patch
(UPLOAD_MAX_ATTEMPTS = 3, 2s/4s delays, transient errors only).
--]]
local HERE = arg[0]:match("^(.*)/") or "."
package.path = HERE .. "/?.lua;" .. package.path
local T = require("common")

-- --------------------------------------------------------------- environment

local store = {}
G_reader_settings = {
    readSetting = function(_, key, default)
        if store[key] == nil then
            return default
        end
        return store[key]
    end,
    saveSetting = function(_, key, value)
        store[key] = value
    end,
    isTrue = function()
        return false
    end,
}

local GetText = require("gettext")
local DataStorage = require("datastorage")
local BookList = require("ui/widget/booklist")
local ConfirmBox = require("ui/widget/confirmbox")
local readhistory = require("readhistory")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local InputDialog = require("ui/widget/inputdialog")
local PathChooser = require("ui/widget/pathchooser")
local NetworkMgr = require("ui/network/manager")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Button = require("ui/widget/button")
local ImageWidget = require("ui/widget/imagewidget")
local Update = require("tomedown_update")
local lfs = require("libs/libkoreader-lfs")
local json = require("json")
local md5 = require("ffi/sha2").md5
local logger = require("logger")

GetText.current_lang = nil

local SERVER = { name = "Koofr", type = "webdav", url = "/Bookshelf/Kindle" }

local uploads, attempt_count, upload_script = {}, {}, {}
local cloud_list_callback

local provider = {}
function provider.run(callback)
    -- KOReader: checks the connection, then runs the step
    callback()
end
function provider.uploadFile(url, local_path, etag, overwrite)
    local n = (attempt_count[local_path] or 0) + 1
    attempt_count[local_path] = n
    uploads[#uploads + 1] = { url = url, path = local_path, attempt = n }
    local script = upload_script[local_path]
    if type(script) == "function" then
        return script(n, url, local_path)
    end
    if type(script) == "table" then
        return script[math.min(n, #script)]
    end
    return 200
end

local cloud = {
    providers = { webdav = provider },
    getServerNameType = function(_, server)
        return tostring(server.name or "?") .. " (" .. tostring(server.type) .. ")"
    end,
    onShowCloudStorageList = function(_, callback)
        cloud_list_callback = callback
    end,
}

local ui = {
    cloudstorage = cloud,
    menu = { registerToMainMenu = function() end },
    bookinfo = {},
    document = { file = nil },
    annotation = nil,
}

-- ------------------------------------------------------------- fixture

local DATA = DataStorage:getFullDataDir()
local DIR = DATA .. "/clipboard/tomedown"
local FILE = "/mnt/us/Bookshelf/Blackwater.epub"
local FILE2 = "/mnt/us/Bookshelf/LibroVecchio.epub"
local FILE3 = "/mnt/us/Bookshelf/Senza Meta.epub"
local FILE_DIM = "/mnt/us/Bookshelf/Dim.epub"
local FILE4 = "/mnt/us/Bookshelf/SoloBookmark.epub"
local BASE = "Michael McDowell - Blackwater"
local MD_PATH = DIR .. "/" .. BASE .. ".md"
local INDEX_PATH = DIR .. "/00 - Index.md"

local function modernAnnotations()
    return {
        {
            drawer = "underline",
            text = "Prima frase.",
            pageno = 10,
            datetime = "2026-09-02 10:00:00",
            chapter = "Capitolo I",
            note = "nota utente",
        },
        {
            drawer = "underline",
            text = "Seconda riga.",
            pageno = 38,
            datetime = "2026-09-03 11:30:00",
            chapter = "Capitolo II",
        },
        -- page bookmark (page, no pos0/pos1): excluded from the highlights
        {
            page = "epubxfi(000000000000000500000)",
            pageno = 5,
            datetime = "2026-09-01 09:00:00",
            note = "Segnalibro di pagina",
        },
        -- deleted highlight: excluded
        {
            drawer = "underline",
            text = "Cancellato",
            pageno = 7,
            datetime = "2026-09-01 09:30:00",
            deleted = true,
        },
    }
end

BookList.setRegistry({
    [FILE] = {
        annotations = modernAnnotations(),
        doc_props = { title = "Blackwater", authors = "Michael McDowell" },
    },
    [FILE2] = {
        highlight = {
            [3] = {
                { drawer = "underline", text = "Vecchio evidenziato", datetime = "2026-08-01 10:00:00" },
            },
        },
        bookmarks = {
            { datetime = "2026-08-01 10:00:00", text = "nota vecchia" },
        },
    },
    [FILE3] = {
        annotations = {
            { drawer = "underline", text = "Senza metadati", pageno = 4, datetime = "2026-07-01 08:00:00" },
        },
        doc_props = { authors = "Autore X" },
    },
    [FILE_DIM] = {
        annotations = {
            { drawer = "underline", text = "Da ignorare", pageno = 1, datetime = "2026-07-02 08:00:00" },
        },
        doc_props = { title = "Ignorato", authors = "Y" },
    },
})
readhistory.hist = {
    { file = FILE },
    { file = FILE2 },
    { file = FILE3 },
    { file = FILE_DIM, dim = true },
}

local Tomedown = require("main")
local plugin = Tomedown:new { ui = ui }

-- KOReader runs init() inside createPluginInstance and only afterwards
-- calls registerModule, which inserts the instance into the ui children
-- itself. init() must not pre-insert: doing so left the plugin in the
-- chain twice and every event (CloseDocument, Suspend, ...) reached it
-- twice — on close two exports ran back to back, and the silent second
-- one (nothing changed) overwrote the recorded outcome shown by Status.
local pre_inserted = 0
for __, child in ipairs(ui) do
    if child == plugin then
        pre_inserted = pre_inserted + 1
    end
end
T.check(pre_inserted == 0,
    "init does not pre-insert into the ui chain: " .. pre_inserted)
table.insert(ui, plugin) -- what ReaderUI/FileManager registerModule does

-- ------------------------------------------------------------- helpers

local function resetUpload()
    uploads, attempt_count, upload_script = {}, {}, {}
    UIManager:reset()
    Notification.last_text = nil
    Notification.log = {}
    InfoMessage.last_text = nil
    logger.reset()
end

local function uploadSetup()
    store = {}
    store.tomedown = { server = SERVER, upload = true }
    resetUpload()
end

local function positives()
    local out = {}
    for __, d in ipairs(UIManager.delay_log) do
        if d > 0 then
            out[#out + 1] = d
        end
    end
    return out
end

local function sameList(a, b)
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

local function listStr(t)
    return "{" .. table.concat(t, ",") .. "}"
end

local function cleanDir()
    T.rmrf(DIR)
end

local function onlyWidget()
    if #UIManager.shown ~= 1 then
        return nil
    end
    return UIManager.shown[1]
end

-- ------------------------------------------------- 1. the stub's md5

T.check(md5("") == "d41d8cd98f00b204e9800998ecf8427e", "md5 of the empty string")
T.check(md5("abc") == "900150983cd24fb0d6963f7d28e17f72", "md5 of 'abc'")
T.check(md5("The quick brown fox jumps over the lazy dog")
    == "9e107d9d372bb6826bd81d3542a419d6", "md5 of a sentence")
T.check(md5(string.rep("1234567890", 10))
    == "49cb3608e2b33fad6b65df8cb8f49668", "md5 across multiple blocks")
T.check(#md5("x") == 32, "md5 esadecimale su 32 caratteri")

-- ------------------------------------------- 2. current export

cleanDir()
resetUpload()
store = {}
store.tomedown = {}

plugin:runExport({ FILE }, {})
UIManager:runPending()

local md = T.readFile(MD_PATH)
T.check(md ~= nil, "book md written to " .. MD_PATH)
if md then
    T.check(T.contains(md, 'title: "Blackwater"'), "frontmatter title")
    T.check(T.contains(md, 'author: "Michael McDowell"'), "frontmatter author")
    T.check(T.contains(md, "highlights: 2"), "only the valid highlights")
    T.check(T.contains(md, "  - ebook"), "tag ebook")
    T.check(not T.contains(md, "# Blackwater"), "no h1 in the body")
    T.check(T.contains(md, "# **HIGHLIGHTS: 2**"), "count")
    T.check(T.contains(md, "\n# Capitolo I"), "chapter 1")
    T.check(T.contains(md, "\n# Capitolo II"), "chapter 2")
    T.check(T.contains(md, "> Prima frase."), "quote")
    T.check(T.contains(md, "- **p. 10** · 02/09/2026 10:00 · note: nota utente"), "meta with note")
    T.check(T.contains(md, "nota utente"), "note present")
    T.check(not T.contains(md, "Segnalibro"), "page bookmark excluded")
    T.check(not T.contains(md, "Cancellato"), "deleted highlight excluded")
    T.check(not T.contains(md, "cover"), "no cover")
    T.check(not T.contains(md, "![]("), "nessuna immagine")
end

T.check(Notification.last_text == "1 files exported locally",
    "export notification: " .. tostring(Notification.last_text))
T.check(lfs.attributes(DIR .. "/covers", "mode") ~= "directory",
    "covers folder not created")

local index = T.readFile(INDEX_PATH)
T.check(index ~= nil, "index written")
if index then
    T.check(T.contains(index, "[[Michael McDowell - Blackwater\\|Blackwater]]"),
        "wikilink in the index")
    T.check(T.contains(index, "| 2 |"), "index columns (count)")
    T.check(T.contains(index, os.date("%d/%m/%Y")), "today's date in the index")
end

-- index with more rows after exporting every book
plugin:runExport(plugin:listBookFiles(), {})
UIManager:runPending()
T.check(#plugin:listBookFiles() == 3, "three books listed (dim excluded)")
T.check(Notification.last_text == "3 files exported locally",
    "multi export: " .. tostring(Notification.last_text))

index = T.readFile(INDEX_PATH)
if index then
    T.check(T.contains(index, "[[N_A - LibroVecchio\\|LibroVecchio]]"),
        "old .sdr book in the index")
    T.check(T.contains(index, "[[Autore X - Senza Meta\\|Senza Meta]]"),
        "title from the file name when title is missing")
end

local legacy_md = T.readFile(DIR .. "/N_A - LibroVecchio.md")
T.check(legacy_md ~= nil, "export of the book with the old .sdr")
if legacy_md then
    T.check(T.contains(legacy_md, "> Vecchio evidenziato"), "highlight from a legacy .sdr")
    T.check(T.contains(legacy_md, "note: nota vecchia"), "note from legacy bookmarks")
    T.check(T.contains(legacy_md, "**p. 3**"), "legacy page")
end

local no_props_md = T.readFile(DIR .. "/Autore X - Senza Meta.md")
T.check(no_props_md ~= nil, "export without doc_props.title")
if no_props_md then
    T.check(T.contains(no_props_md, "title: \"Senza Meta\""),
        "display_title derived from the file name")
end

-- ------------------------------------------------ 3. only_updated/hash

resetUpload()
T.check(store.tomedown.exports ~= nil and store.tomedown.exports[FILE] ~= nil,
    "export record saved")
local saved_hash = store.tomedown.exports and store.tomedown.exports[FILE]
    and store.tomedown.exports[FILE].hash
T.check(saved_hash and #saved_hash == 32, "book hash (32 hex)")

plugin:runExport({ FILE }, { only_updated = true })
UIManager:runPending()
T.check(T.contains(Notification.last_text or "", "1 files unchanged, skipped"),
    "nothing changed: " .. tostring(Notification.last_text))

local annotations = modernAnnotations()
annotations[1].text = "Prima frase modificata."
BookList.registry[FILE].annotations = annotations

plugin:runExport({ FILE }, { only_updated = true })
UIManager:runPending()
local updated = T.readFile(MD_PATH)
T.check(updated ~= nil and T.contains(updated, "Prima frase modificata."),
    "content re-exported after the change")
T.check(T.contains(Notification.last_text or "", "1 files exported"),
    "re-export: " .. tostring(Notification.last_text))
local new_hash = store.tomedown.exports[FILE].hash
T.check(new_hash ~= saved_hash, "hash changes with the new annotations")

BookList.registry[FILE].annotations = modernAnnotations()
plugin:runExport({ FILE }, { only_updated = true })
UIManager:runPending()
T.check(T.contains(Notification.last_text or "", "1 files exported"),
    "the restored version re-exported")

-- ------------------------------------------------------- 4. md5 on disk

T.check(store.tomedown.exports[FILE].hash == saved_hash,
    "hash back to the previous value")

-- ------------------------------------ 4b. rich frontmatter from doc settings
local rec = BookList.registry[FILE]
rec.doc_props = {
    title = "Blackwater",
    authors = "Michael McDowell",
    series = "Blackwater",
    series_index = 4,
    language = "it",
    keywords = "horror, gothic-fiction",
}
rec.doc_pages = 300
rec.percent_finished = 0.956
rec.summary = { status = "complete" }

plugin:runExport({ FILE }, {})
UIManager:runPending()
local richMd = T.readFile(MD_PATH)
T.check(richMd ~= nil, "re-export with the new metadata")
if richMd then
    T.check(T.contains(richMd, 'series: "Blackwater"'), "series from doc_props")
    T.check(T.contains(richMd, "series_index: 4"), "series_index as a number")
    T.check(T.contains(richMd, 'language: "it"'), "language from doc_props")
    T.check(T.contains(richMd, "pages: 300"), "pages from doc settings")
    T.check(T.contains(richMd, 'status: "complete"'), "status from summary")
    T.check(T.contains(richMd, 'progress: "96%"'), "progress rounded from percent_finished")
    T.check(T.contains(richMd, "  - horror"), "keyword tag")
    T.check(T.contains(richMd, "  - gothic-fiction"), "second keyword tag")
    local iSeries = richMd:find("series:", 1, true)
    local iIndex = richMd:find("series_index:", 1, true)
    local iLang = richMd:find('language:', 1, true)
    T.check(iSeries and iIndex and iLang and iSeries < iIndex and iIndex < iLang,
        "series, series_index, language in order")
end
T.check(store.tomedown.exports[FILE].hash ~= saved_hash,
    "hash changes with the new metadata")

-- a progress change alone re-exports the book (only updated)
rec.percent_finished = 0.5
plugin:runExport({ FILE }, { only_updated = true })
UIManager:runPending()
T.check(T.contains(Notification.last_text or "", "1 files exported"),
    "progress change picked up by only updated: " .. tostring(Notification.last_text))
local newProgressMd = T.readFile(MD_PATH)
T.check(newProgressMd and T.contains(newProgressMd, 'progress: "50%"'),
    "new progress value in the frontmatter")

-- ------------------------------------------------------------ 5. menu

local menu_items = {}
plugin:addToMainMenu(menu_items)
T.check(menu_items.tomedown ~= nil, "menu entry registered")
local sub = menu_items.tomedown.sub_item_table
T.check(#sub == 8, "main menu entries: " .. #sub)
T.check(sub[1].text == "\xEE\x89\xBC  Export current book", "menu item 1")
T.check(sub[2].text == "\xEE\xA4\xB5  Export only what changed", "menu item 2")
T.check(sub[3].text == "\xEE\xB9\x94  Choose books…", "menu item 3")
T.check(sub[4].text == "\xEE\xA7\x99  Import all books from history", "menu item 4")
T.check(sub[5].text == "\xEE\xB4\xBE  Reload everything to the cloud", "menu item 5")
T.check(sub[6].text == "\xEF\x83\xA4  Status", "menu item 6 with the dashboard")
T.check(sub[6].separator == true, "separator before Settings")
T.check(sub[7].text == "\xEF\x80\x93  Settings", "menu item 7 with the cog")
T.check(sub[7].separator == true, "separator before About")
T.check(sub[8].text == "\xEE\xA7\xBC  About", "menu item 8")

local cover_entry = false
local function scanCover(items)
    for __, item in ipairs(items) do
        local text = item.text
        if type(text) == "string" and text:lower():find("cover", 1, true) then
            cover_entry = true
        end
        if item.sub_item_table then
            scanCover(item.sub_item_table)
        end
    end
end
scanCover(menu_items)
T.check(not cover_entry, "no menu entry about covers")

ui.document = { file = FILE }
T.check(sub[1].enabled_func() == true, "export current enabled with the book open")
ui.document = nil
store.lastfile = FILE
T.check(sub[1].enabled_func() == true, "export current enabled via lastfile")
store.lastfile = nil
T.check(sub[1].enabled_func() == false, "export current disabled without a file")
ui.document = { file = nil }
T.check(sub[4].enabled_func() == true, "all books enabled")

local settings = plugin:genSettingsMenu()
T.check(#settings == 3, "settings groups: " .. #settings)
T.check(settings[1].text == "\xEE\xB4\xBE  Cloud", "cloud group with icon")
T.check(settings[2].text == "\xEF\x83\xB6  Markdown files",
    "markdown files group with icon")
T.check(settings[3].text == "\xEE\xB6\xAE  Updates", "updates group with icon")
local cloud = settings[1].sub_item_table
local files = settings[2].sub_item_table
local updates = settings[3].sub_item_table
T.check(#cloud == 3, "cloud rows: " .. #cloud)
T.check(#files == 6, "markdown files rows: " .. #files)
T.check(#updates == 4, "updates rows: " .. #updates)
T.check(cloud[1].text == "Upload to cloud", "upload entry")
T.check(cloud[2].text_func() == "Server and folder: not set", "server not set")
T.check(T.contains(cloud[3].text_func(), "Remote folder: not set"), "remote folder not set")
T.check(T.contains(files[1].text_func(), "clipboard/tomedown"), "default local folder")
T.check(T.contains(files[2].text, "00 - Index.md"), "index entry with the file name")
T.check(files[3].text == "Include page bookmarks", "page bookmarks entry")
T.check(files[3].checked_func() == false, "page bookmarks off by default")
T.check(files[4].text == "Include book covers", "covers entry")
T.check(files[4].checked_func() == false, "covers off by default")
T.check(files[5].text == "All highlights as callouts", "callout entry")
T.check(files[5].checked_func() == false, "callout off by default")
T.check(files[5].separator == true, "separator before the auto-export toggle")
T.check(files[6].text == "Auto-export on close",
    "auto-export lives in Markdown files")
T.check(files[6].checked_func() == false, "auto-export off by default")
T.check(updates[1].text_func() == "Check for updates (v"
        .. Update.getInstalledVersion() .. ")",
    "check row carries the installed version: " .. updates[1].text_func())
T.check(updates[2].text == "View changelog", "changelog entry")
T.check(updates[2].separator == true, "separator after the changelog entry")
T.check(updates[3].text == "Check for updates in background", "background entry")
T.check(updates[4].text == "Developer updates", "developer updates entry")
local developer = updates[4].sub_item_table_func()
T.check(#developer == 3, "beta check hidden by default: " .. #developer)
T.check(developer[1].text == "Beta Releases", "beta releases entry")
T.check(developer[1].checked_func() == false, "beta releases off by default")
T.check(developer[1].separator == true, "separator under the beta toggle")
T.check(developer[2].text == "\xEE\xB6\x8F  Reset to latest stable release",
    "reset entry with the bomb icon")
local installed_version = Update.getInstalledVersion()
T.check(developer[3].text_func() == "Installed: v" .. installed_version
        .. (installed_version:find("-", 1, true) and " (Beta)" or " (Release)"),
    "installed row: " .. developer[3].text_func())
T.check(developer[3].enabled == false, "installed row is a plain label")

-- ticking Beta Releases reveals the check in the open submenu at once
-- (the callback receives the TouchMenu, whose item_table is this very
-- table; it is rebuilt in place and redrawn by KOReader)
local fake_menu = { item_table = developer }
developer[1].callback(fake_menu)
T.check(store.tomedown.beta_releases == true, "beta releases toggled on")
T.check(#developer == 4, "beta check shown after ticking: " .. #developer)
T.check(developer[2].text == "Check for updates", "beta check entry")
T.check(developer[2].separator == true,
    "separator between the beta check and the reset")
T.check(developer[1].separator ~= true, "no separator under the toggle")
T.check(developer[2].callback ~= nil, "beta check row is tappable")
-- unticking hides it again, in the same open menu
developer[1].callback(fake_menu)
T.check(store.tomedown.beta_releases == false, "beta releases off again")
T.check(#developer == 3, "beta check hidden again: " .. #developer)
T.check(developer[1].separator == true, "separator back under the toggle")

-- checkable rows must keep the menu open so KOReader refreshes them
for _, group in ipairs({ sub, cloud, files, updates, developer }) do
    for i, row in ipairs(group) do
        if row.checked_func then
            T.check(row.keep_menu_open == true,
                "checkable settings row " .. i .. " keeps the menu open")
        end
    end
end
-- the About row opens the Bookshelf-style popup
local shown_before = #UIManager.shown
sub[8].callback()
T.check(#UIManager.shown == shown_before + 1, "about popup shown")
local dialog = UIManager.shown[#UIManager.shown]
T.check(dialog ~= nil and dialog.__widget == "InputContainer",
    "about is a framed popup: " .. tostring(dialog and dialog.__widget))
T.check(TextWidget.last ~= nil
        and TextWidget.last.text == "v" .. installed_version,
    "about shows the version")
T.check(T.contains(TextBoxWidget.last and TextBoxWidget.last.text or "",
    "Exports each book"), "about shows the description")
T.check(Button.last ~= nil
        and Button.last.text == "github.com/imanubdesigner/tomedown.koplugin",
    "about shows the GitHub URL")
-- the logo ships with the plugin and keeps its own ratio (viewBox)
T.check(ImageWidget.last ~= nil
        and (ImageWidget.last.file or ""):find("assets/logo.svg", 1, true) ~= nil,
    "about shows the logo: " .. tostring(ImageWidget.last and ImageWidget.last.file))
T.check(ImageWidget.last ~= nil and (ImageWidget.last.height or 0) > 0
        and ImageWidget.last.height < ImageWidget.last.width,
    "logo box follows the file ratio: "
        .. tostring(ImageWidget.last and ImageWidget.last.width)
        .. "x" .. tostring(ImageWidget.last and ImageWidget.last.height))
UIManager:close(dialog)

local main_src = T.readFile(T.plugin .. "/main.lua") or ""
T.check(not main_src:find("check_callback_updates_menu", 1, true),
    "no check_callback_updates_menu (it opts out of the menu refresh)")

cloud[1].callback()
T.check(store.tomedown.upload == true, "upload enabled from the default off")
cloud[1].callback()
T.check(store.tomedown.upload == false, "upload disabled again")
files[2].callback()
T.check(store.tomedown.with_index == false, "index disabled")
files[2].callback()
T.check(store.tomedown.with_index == true, "index re-enabled")
files[3].callback()
T.check(store.tomedown.include_bookmarks == true, "page bookmarks enabled")
files[3].callback()
T.check(store.tomedown.include_bookmarks == false, "page bookmarks disabled")
developer[1].callback()
T.check(store.tomedown.beta_releases == true, "beta releases enabled")
developer[1].callback()
T.check(store.tomedown.beta_releases == false, "beta releases disabled")

-- server picked from the Cloud storage list
plugin:chooseCloudFolder(nil)
T.check(cloud_list_callback ~= nil, "cloud list opened")
cloud_list_callback({ name = "Koofr", type = "webdav", url = "/Bookshelf/Kindle" })
T.check(store.tomedown.server and store.tomedown.server.name == "Koofr", "server saved")
T.check(cloud[2].text_func() == "Server and folder: Koofr (webdav) → /Bookshelf/Kindle",
    "server text updated: " .. cloud[2].text_func())
T.check(plugin:hasServer() == true, "hasServer true with server and cloud")

-- remote folder dialog
plugin:editRemoteFolder(nil)
local dialog = InputDialog.last
T.check(dialog ~= nil and dialog.title == "Remote folder on the server", "remote dialog opened")
dialog.input_text = "  /Cartella mia  "
dialog:simulateSave()
T.check(store.tomedown.remote_folder == "/Cartella mia", "remote folder saved and trimmed")
T.check(T.contains(cloud[3].text_func(), "/Cartella mia"), "menu entry updated")
plugin:editRemoteFolder(nil)
InputDialog.last.input_text = ""
InputDialog.last:simulateSave()
T.check(store.tomedown.remote_folder == "", "remote folder cleared")

-- local folder picker (KOReader PathChooser: long-press a folder to choose it)
plugin:editLocalDir(nil)
local chooser = PathChooser.last
T.check(chooser ~= nil, "path chooser opened")
T.check(chooser.title == "Local folder for exports",
    "chooser title: " .. tostring(chooser and chooser.title))
T.check(chooser.select_directory == true and chooser.select_file == false
    and chooser.show_files == false, "folder-only chooser")
T.check(T.contains(chooser.path, "clipboard/tomedown"),
    "default path as start: " .. tostring(chooser and chooser.path))
plugin:editLocalDir(nil)
T.check(plugin:getLocalDir() == DIR, "unchanged when closed without choosing")
PathChooser.last.onConfirm(DATA .. "/out-customi/")
T.check(plugin:getLocalDir() == DATA .. "/out-customi", "local folder changed")
plugin:editLocalDir(nil)
T.check(plugin:getLocalDir() == DATA .. "/out-customi", "reopen without choosing keeps the value")
PathChooser.last.onConfirm("/")
T.check(plugin:getLocalDir() == "/", "root folder kept as-is")
store.tomedown.local_dir = nil
T.check(plugin:getLocalDir() == DIR, "local folder back to default")

-- book picker menu
local picker = plugin:genPickerMenu()
T.check(#picker == 5, "picker: 2 commands + 3 books (" .. #picker .. ")")
T.check(T.contains(picker[1].text_func(), "Export selected (0)"), "no book selected")
T.check(picker[1].enabled_func() == false, "export selected disabled")
for i = 3, #picker do
    local text = picker[i].text_func()
    T.check(text:match("%(%d+%)$") ~= nil, "book row with count: " .. text)
    local checked = picker[i].checked_func()
    T.check(checked == nil or checked == true, "selection state: " .. tostring(checked))
end

store.tomedown.selected = { [FILE] = true }
store.tomedown.upload = false
picker = plugin:genPickerMenu()
T.check(T.contains(picker[1].text_func(), "Export selected (1)"), "one book selected")
T.check(picker[1].enabled_func() == true, "export selected enabled")
picker[1].callback(nil)
UIManager:runPending()
T.check(Notification.last_text == "1 files exported locally",
    "export of the selected: " .. tostring(Notification.last_text))

picker = plugin:genPickerMenu()
picker[2].callback(nil)
T.check(store.tomedown.selected[FILE] == nil, "deselect all")

store = {}
store.tomedown = {}
T.check(plugin:genPickerMenu()[1].text_func() == "Export selected (0)",
    "no selection after the reset")

-- MenuSorter appends the items it cannot place in the cached order
-- tables at the bottom of the first tab, prefixed with "NEW: ";
-- pinToTop() references them from the order tables instead, so the
-- row lands on top of the right tab and loses the orphan handling.
store.tomedown.import_prompt_done = true -- keep the menu rebuild quiet
local reader_order = { navi = { "table_of_contents", "bookmarks" } }
local fm_order = { filemanager_settings = { "filemanager_display_mode" } }
package.loaded["ui/elements/reader_menu_order"] = reader_order
package.loaded["ui/elements/filemanager_menu_order"] = fm_order
plugin:addToMainMenu(menu_items)
T.check(reader_order.navi[1] == "tomedown",
    "reader: row pinned first in the Navigation tab")
T.check(reader_order.navi[2] == "table_of_contents",
    "reader: Table of Contents follows")
T.check(fm_order.filemanager_settings[1] == "tomedown",
    "file browser: row pinned first in the first tab")
T.check(fm_order.filemanager_settings[2] == "filemanager_display_mode",
    "file browser: Display mode follows")
-- menu rebuilds re-run addToMainMenu: one entry, still first
plugin:addToMainMenu(menu_items)
T.check(#reader_order.navi == 3 and reader_order.navi[1] == "tomedown",
    "reader placement is idempotent: " .. #reader_order.navi)
T.check(#fm_order.filemanager_settings == 2
        and fm_order.filemanager_settings[1] == "tomedown",
    "file browser placement is idempotent: " .. #fm_order.filemanager_settings)
-- no order tables at all (bare test/host environment): no failure
package.loaded["ui/elements/reader_menu_order"] = nil
package.loaded["ui/elements/filemanager_menu_order"] = nil
T.check(pcall(plugin.addToMainMenu, plugin, menu_items),
    "addToMainMenu without order tables does not fail")

-- Status panel: the settings read back into a few lines of text
NetworkMgr.connected = false
store.tomedown.upload = false
local lines = plugin:statusLines()
local status_text = table.concat(lines, "\n")
T.check(lines[1] == "Network: offline", "status: offline line: " .. lines[1])
T.check(lines[2] == "Server: not set", "status: no server line: " .. lines[2])
T.check(T.contains(status_text, "Last export: never"), "status: no export yet")
T.check(T.contains(status_text, "Last upload: never"), "status: no upload yet")
T.check(#lines == 4, "status without pending: " .. #lines)

NetworkMgr.connected = true
store.tomedown.server = { name = "Koofr", type = "webdav", url = "/Bookshelf/Kindle" }
store.tomedown.remote_folder = "/Cartella"
store.tomedown.last_export = {
    at = os.time({ year = 2026, month = 10, day = 1, hour = 14, min = 32, sec = 0 }),
    exported = 3, skipped = 1, errors = 0,
}
store.tomedown.last_upload = {
    at = os.time({ year = 2026, month = 10, day = 1, hour = 14, min = 35, sec = 0 }),
    uploaded = 2, errors = 1,
}
store.tomedown.pending_uploads = { ["/a.md"] = true, ["/b.md"] = true }
store.tomedown.upload = true
lines = plugin:statusLines()
status_text = table.concat(lines, "\n")
T.check(lines[1] == "Network: connected",
    "status: connected line: " .. lines[1])
T.check(T.contains(status_text, "Koofr") and T.contains(status_text, "/Cartella"),
    "status: server and folder: " .. lines[2])
T.check(T.contains(status_text, "Upload pending: 2 files"),
    "status: pending count")
T.check(T.contains(status_text, "01/10/2026 14:32 — 3 exported, 1 skipped"),
    "status: last export line: " .. tostring(lines[4]))
T.check(T.contains(status_text, "01/10/2026 14:35 — 2 uploaded · 1 errors"),
    "status: last upload line: " .. tostring(lines[5]))
T.check(T.contains(status_text, "Next upload: any moment now"),
    "status: next upload queued while online")
T.check(#lines == 6, "status with pending: " .. #lines)

NetworkMgr.connected = false
T.check(T.contains(table.concat(plugin:statusLines(), "\n"),
        "Next upload: at the next connection"),
    "status: next upload waits for the connection")
NetworkMgr.connected = true
store.tomedown.upload = false
T.check(T.contains(table.concat(plugin:statusLines(), "\n"),
        "Next upload: disabled in settings"),
    "status: next upload honours the setting")

-- the panel is shown as an InfoMessage, in the smallest info face so
-- every entry fits on its own line without wrapping
local shown_before_status = #UIManager.shown
plugin:showStatus()
T.check(#UIManager.shown == shown_before_status + 1, "status panel shown")
T.check(InfoMessage.last_face and InfoMessage.last_face.name == "xx_smallinfofont",
    "status popup uses the small face: "
        .. tostring(InfoMessage.last_face and InfoMessage.last_face.name))
T.check(InfoMessage.last_width == math.floor(600 * 0.9),
    "status popup widened to 90% of the screen: "
        .. tostring(InfoMessage.last_width))
T.check(InfoMessage.last_text
        and InfoMessage.last_text:find(TextBoxWidget.PTF_HEADER, 1, true) == 1,
    "styled status text opens with the PTF header")
T.check(InfoMessage.last_text
        and InfoMessage.last_text:find(TextBoxWidget.PTF_BOLD_START
            .. "Network:" .. TextBoxWidget.PTF_BOLD_END, 1, true),
    "the Network label is wrapped in bold")
T.check(InfoMessage.last_text
        and InfoMessage.last_text:find(TextBoxWidget.PTF_BOLD_START
            .. "Last export:" .. TextBoxWidget.PTF_BOLD_END, 1, true),
    "the Last export label is wrapped in bold")

-- runExport records its outcome for the panel (upload off: no cloud)
store.tomedown.upload = false
plugin:runExport({ FILE }, {})
UIManager:runPending()
local recorded = store.tomedown.last_export
T.check(recorded ~= nil and recorded.at ~= nil and recorded.exported == 1
        and recorded.skipped == 0,
    "runExport records last_export: " .. tostring(recorded and recorded.exported))
T.check(T.contains(table.concat(plugin:statusLines(), "\n"),
        "Last export: "),
    "status reads the recorded export")

-- export notifications: automatic runs carry their trigger, manual
-- ones stay untouched; the error window always names its trigger
plugin:showResult(3, 0, {}, false, "close")
T.check(Notification.last_text == "Closing · 3 files exported locally",
    "automatic toast carries the trigger: " .. tostring(Notification.last_text))
plugin:showResult(3, 0, {}, false, nil)
T.check(Notification.last_text == "3 files exported locally",
    "manual toast is untouched: " .. tostring(Notification.last_text))
plugin:showResult(2, 0, { "book.md: broken" }, false, nil)
T.check(T.contains(InfoMessage.last_text or "", "Manual · 2 files exported locally")
        and T.contains(InfoMessage.last_text or "", "Errors:"),
    "error window always says what started it: " .. tostring(InfoMessage.last_text))
plugin:showResult(2, 0, { "book.md: broken" }, false, "close")
T.check(T.contains(InfoMessage.last_text or "", "Closing · 2 files exported locally"),
    "error window labels a background close: " .. tostring(InfoMessage.last_text))
InfoMessage.last_text = nil
Notification.last_text = nil

-- leave the store the way the sections after this one expect it
store = {}
store.tomedown = { import_prompt_done = true }

-- ----------------------------------------------- 5b. page bookmarks

files[3].callback() -- enable "Include page bookmarks"
T.check(store.tomedown.include_bookmarks == true, "page bookmarks enabled for the export")
plugin:runExport({ FILE }, {})
UIManager:runPending()
local bmMd = T.readFile(MD_PATH)
T.check(bmMd ~= nil, "export with page bookmarks")
if bmMd then
    T.check(T.contains(bmMd, "\n# Page bookmarks"), "bookmarks section")
    T.check(T.contains(bmMd, "> Segnalibro di pagina"), "bookmark note quoted")
    T.check(T.contains(bmMd, "- **p. 5** · 01/09/2026 09:00"), "bookmark meta row")
    T.check(T.contains(bmMd, "highlights: 2"), "highlight count unchanged")
    local iBm = bmMd:find("\n# Page bookmarks", 1, true)
    local iLast = bmMd:find("> Seconda riga.", 1, true)
    T.check(iBm and iLast and iLast < iBm, "the section comes after the highlights")
end

-- a book with only a bookmark is exported too
BookList.registry[FILE4] = {
    annotations = {
        { page = "epubxfi(000000000000000300000)", pageno = 3,
            datetime = "2026-09-02 08:00:00", note = "Solo un segnalibro" },
    },
    doc_props = { title = "SoloBookmark", authors = "Autore B" },
}
plugin:runExport({ FILE4 }, {})
UIManager:runPending()
local onlyBmMd = T.readFile(DIR .. "/Autore B - SoloBookmark.md")
T.check(onlyBmMd ~= nil, "bookmark-only book exported")
if onlyBmMd then
    T.check(T.contains(onlyBmMd, "highlights: 0"), "frontmatter count zero")
    T.check(not T.contains(onlyBmMd, "# **HIGHLIGHTS: 0**"), "no zero count line in the body")
    T.check(T.contains(onlyBmMd, "\n# Page bookmarks"), "bookmark-only section")
    T.check(T.contains(onlyBmMd, "> Solo un segnalibro"), "bookmark-only quote")
end

-- disabled again: the section disappears
files[3].callback()
T.check(store.tomedown.include_bookmarks == false, "page bookmarks disabled again")
plugin:runExport({ FILE }, {})
UIManager:runPending()
local bmOffMd = T.readFile(MD_PATH)
T.check(bmOffMd ~= nil and not T.contains(bmOffMd, "# Page bookmarks"),
    "bookmarks section removed when disabled")

-- ------------------------------------------------- 6. fallback servers

local srv = plugin:getServer()
T.check(srv == nil, "no server configured")

store.cloud_server_object = json.encode({
    name = "Legacy",
    type = "webdav",
    address = "https://legacy.example/dav",
})
srv = plugin:getServer()
T.check(srv ~= nil and srv.name == "Legacy" and srv.type == "webdav",
    "server from cloud_server_object (JSON)")

store.cloud_server_object = "{ not json"
T.check(plugin:getServer() == nil, "broken JSON does not break getServer")

store.cloud_server_object = nil
store.annotation_sync = { sync_server = { name = "Sync", type = "webdav", address = "https://sync.example/dav" } }
srv = plugin:getServer()
T.check(srv ~= nil and srv.name == "Sync", "server from annotation_sync.sync_server")

store.annotation_sync_plugin = { sync_server = { name = "Plugin", type = "webdav", address = "https://p.example" } }
T.check(plugin:getServer().name == "Plugin", "annotation_sync_plugin takes precedence")

-- --------------------------------------------------------- 7. upload

uploadSetup()
plugin:runExport({ FILE }, {})
T.check(#uploads == 1, "first upload started right away: " .. #uploads)
T.check(uploads[1].path == MD_PATH, "first file = book md")
T.check(InfoMessage.last_text == "Uploading 2 files to the cloud…",
    "progress window: " .. tostring(InfoMessage.last_text))
T.check(#UIManager.shown == 2
        and UIManager.shown[#UIManager.shown].text == InfoMessage.last_text,
    "export toast + upload progress during the upload phase")
UIManager:runPending()
T.check(#uploads == 2, "uploaded md and index: " .. #uploads)
T.check(uploads[2].path == INDEX_PATH, "second file = index")
T.check(uploads[1].url == "/Bookshelf/Kindle" and uploads[2].url == "/Bookshelf/Kindle",
    "Koofr folder url")
T.check(attempt_count[MD_PATH] == 1 and attempt_count[INDEX_PATH] == 1,
    "one attempt per file in normal conditions")
T.check(T.contains(Notification.last_text or "", "Cloud: 2 files uploaded"),
    "upload notification: " .. tostring(Notification.last_text))
local final = UIManager.shown[#UIManager.shown]
T.check(final and final.__widget == "Notification"
        and T.contains(final.text or "", "Cloud: 2 files uploaded"),
    "the upload result is the last notification: "
        .. tostring(final and final.text))

-- upload disabled
uploadSetup()
store.tomedown.upload = false
plugin:runExport({ FILE }, {})
UIManager:runPending()
T.check(#uploads == 0, "no upload with upload=false")
T.check(Notification.last_text == "1 files exported locally",
    "export-only notification: " .. tostring(Notification.last_text))

-- explicit remote folder
uploadSetup()
store.tomedown.remote_folder = "/Cartella mia"
plugin:runExport({ FILE }, {})
UIManager:runPending()
T.check(#uploads == 2 and uploads[1].url == "/Cartella mia",
    "upload into the chosen folder: " .. tostring(uploads[1] and uploads[1].url))

-- server without "url" but with "address" (like AnnotationSync's)
store = {}
store.tomedown = { upload = true }
store.annotation_sync = {
    sync_server = { name = "Sync", type = "webdav", address = "https://app.koofr.net/dav/Koofr/Bookshelf" },
}
resetUpload()
plugin:runExport({ FILE }, {})
UIManager:runPending()
T.check(#uploads == 2, "upload with an address-only server: " .. #uploads)
T.check(uploads[1] and uploads[1].url == "https://app.koofr.net/dav/Koofr/Bookshelf",
    "address used when url is missing: " .. tostring(uploads[1] and uploads[1].url))

-- ------------------------------------------------------- 8. backoff

-- transient failure (500) on the first attempt, then ok
uploadSetup()
upload_script[MD_PATH] = { 500, 200 }
plugin:runExport({ FILE }, {})
T.check(#uploads == 1, "first failed attempt recorded: " .. #uploads)
T.check(sameList(positives(), { 2 }),
    "retry delay scheduled at 2s: " .. listStr(positives()))
T.check(UIManager:pendingCount() == 1, "one retry queued")
UIManager:runPending()
T.check(attempt_count[MD_PATH] == 2, "md retried once: " .. attempt_count[MD_PATH])
T.check(attempt_count[INDEX_PATH] == 1, "index untouched by the md failure")
T.check(sameList(positives(), { 2 }), "backoff iniziale 2s, ottenuto " .. listStr(positives()))
T.check(T.contains(Notification.last_text or "", "Cloud: 2 files uploaded"),
    "full recovery: " .. tostring(Notification.last_text))
local up = store.tomedown.last_upload
T.check(up ~= nil and up.at ~= nil and up.uploaded == 2 and up.errors == 0,
    "uploadPaths records last_upload: " .. tostring(up and up.uploaded))
local logged = table.concat(logger.history, "\n")
T.check(T.contains(logged, "tomedown: upload start: 2 files"),
    "upload start logged to crash.log")
T.check(T.contains(logged, "tomedown: upload done: ok=2 errors=0"),
    "upload result logged to crash.log")
T.check(T.contains(table.concat(logger.history, "\n"), "retrying in"),
    "retry logged")

-- permanent failure: 3 attempts and it gives up
uploadSetup()
upload_script[MD_PATH] = { 500, 500, 500, 500 }
upload_script[INDEX_PATH] = { 500, 500, 500, 500 }
plugin:runExport({ FILE }, {})
UIManager:runPending()
T.check(#uploads == 6, "3 attempts for each of the 2 files: " .. #uploads)
T.check(attempt_count[MD_PATH] == 3 and attempt_count[INDEX_PATH] == 3,
    "maximum 3 attempts per file")
T.check(sameList(positives(), { 2, 4, 2, 4 }),
    "backoff 2s/4s for every file, got " .. listStr(positives()))
T.check(Notification.last_text == "1 files exported locally",
    "the export is reported on its own: " .. tostring(Notification.last_text))
local err_widget = UIManager.shown[#UIManager.shown]
T.check(err_widget and err_widget.__widget == "InfoMessage", "error window shown")
T.check(err_widget and T.contains(err_widget.text, "Cloud: 0 uploaded, 2 errors"),
    "upload failures in their own window: " .. tostring(err_widget and err_widget.text))

-- 4xx (missing folder): no retry
uploadSetup()
upload_script[MD_PATH] = { 404 }
upload_script[INDEX_PATH] = { 404 }
plugin:runExport({ FILE }, {})
UIManager:runPending()
T.check(#uploads == 2, "404: one attempt per file only: " .. #uploads)
T.check(#positives() == 0, "no delay on 4xx errors: " .. listStr(positives()))
err_widget = UIManager.shown[#UIManager.shown]
T.check(err_widget and T.contains(err_widget.text, "Cloud: 0 uploaded, 2 errors"),
    "404 reported as a definitive failure")

-- non-numeric network error: retried
uploadSetup()
upload_script[MD_PATH] = function(n)
    if n < 3 then
        return "connection reset"
    end
    return 200
end
plugin:runExport({ FILE }, {})
UIManager:runPending()
T.check(attempt_count[MD_PATH] == 3, "network error retried: " .. tostring(attempt_count[MD_PATH]))
T.check(sameList(positives(), { 2, 4 }),
    "backoff without a numeric code too: " .. listStr(positives()))
T.check(T.contains(Notification.last_text or "", "Cloud: 2 files uploaded"),
    "recovery after network errors: " .. tostring(Notification.last_text))

-- 429 (too many requests): transient
uploadSetup()
upload_script[MD_PATH] = { 429, 200 }
plugin:runExport({ FILE }, {})
UIManager:runPending()
T.check(attempt_count[MD_PATH] == 2, "429 retried: " .. tostring(attempt_count[MD_PATH]))
T.check(sameList(positives(), { 2 }), "backoff on 429: " .. listStr(positives()))

-- success code outside the 2xx range
uploadSetup()
upload_script[INDEX_PATH] = { 301, 301, 301, 301 }
plugin:runExport({ FILE }, {})
UIManager:runPending()
T.check(attempt_count[INDEX_PATH] == 1, "301 is not a success, but not transient either: "
    .. tostring(attempt_count[INDEX_PATH]))
T.check(#positives() == 0, "no delay on 301: " .. listStr(positives()))

-- ------------------------------------------------- 9. Reload everything

uploadSetup()
store.tomedown.upload = false
cleanDir()
plugin:runExport({ FILE }, {})
T.check(#uploads == 0, "first phase: export only")
T.check(T.fileExists(MD_PATH) and T.fileExists(INDEX_PATH), "local files present")

-- a leftover cover rides along with "Reload everything"
os.execute('mkdir -p "' .. DIR .. '/covers" && printf x > "' .. DIR .. '/covers/copertina.jpg"')

resetUpload()
store.tomedown.upload = true
plugin:reuploadAll(nil)
UIManager:runPending()
T.check(#uploads == 3, "md files plus the leftover cover re-uploaded: " .. #uploads)
T.check(uploads[1].path == INDEX_PATH, "ordered: index first")
T.check(uploads[2].path == MD_PATH, "ordered: book md second")
T.check(uploads[3].path == DIR .. "/covers/copertina.jpg", "ordered: cover last")
T.check(Notification.last_text == "Cloud: 3 files uploaded",
    "reload notification: " .. tostring(Notification.last_text))
T.check(T.fileExists(DIR .. "/covers/copertina.jpg"),
    "covers option off: the uploaded cover stays local")
T.rmrf(DIR .. "/covers")

store = {}
resetUpload()
plugin:reuploadAll(nil)
T.check(T.contains(InfoMessage.last_text or "", "Choose a cloud server"),
    "without server: " .. tostring(InfoMessage.last_text))

-- empty local folder
store = {}
store.tomedown = { server = SERVER, upload = true }
resetUpload()
cleanDir()
plugin:reuploadAll(nil)
UIManager:runPending()
T.check(#uploads == 0, "no file to re-upload")
T.check(Notification.last_text == "Nothing to upload, export something first.",
    "empty folder notification: " .. tostring(Notification.last_text))

-- ------------------------------------ 10. the cover support is wired in

local render_src = T.readFile(T.plugin .. "/tomedown_render.lua")
T.check(render_src and render_src:find("coverImg", 1, true),
    "render embeds the cover")
local cover_src = T.readFile(T.plugin .. "/tomedown_cover.lua")
T.check(cover_src ~= nil, "tomedown_cover.lua exists")
local main_src = T.readFile(T.plugin .. "/main.lua")
T.check(main_src and main_src:find("tomedown_cover", 1, true),
    "main.lua requires the cover module")

-- --------------------------------------- 11. first-run import prompt

local hist = readhistory.hist
local nbooks = #plugin:listBookFiles()
T.check(nbooks == 3, "history books for the prompt: " .. nbooks)

store.tomedown.upload = false
store.tomedown.exports = nil
store.tomedown.import_prompt_done = nil
ConfirmBox.last = nil

-- fresh install: first menu build offers the import
plugin:addToMainMenu({})
UIManager:runPending()
T.check(ConfirmBox.last ~= nil, "first-run prompt shown")
T.check(ConfirmBox.last and T.contains(ConfirmBox.last.text or "",
    "Found " .. nbooks .. " books in your KOReader reading history"),
    "prompt counts the history: " .. tostring(ConfirmBox.last and ConfirmBox.last.text))
T.check(ConfirmBox.last.ok_text == "Export", "ok button")
T.check(ConfirmBox.last.cancel_text == "Not now", "cancel button")

-- "Not now": nothing exported, never asked again
ConfirmBox.last.cancel_callback()
T.check(store.tomedown.exports == nil, "cancel exports nothing")
T.check(store.tomedown.import_prompt_done == true, "cancel sets the flag")
ConfirmBox.last = nil
plugin:addToMainMenu({})
UIManager:runPending()
T.check(ConfirmBox.last == nil, "prompt not repeated after cancel")

-- "Export": writes every book of the history in one tap
store.tomedown.import_prompt_done = nil
plugin:addToMainMenu({})
UIManager:runPending()
T.check(ConfirmBox.last ~= nil, "prompt returns while still unanswered")
ConfirmBox.last.ok_callback()
UIManager:runPending()
T.check(store.tomedown.exports ~= nil
    and store.tomedown.exports[FILE] ~= nil
    and store.tomedown.exports[FILE2] ~= nil
    and store.tomedown.exports[FILE3] ~= nil,
    "all history books exported")
T.check(T.contains(Notification.last_text or "", nbooks .. " files exported"),
    "export notification: " .. tostring(Notification.last_text))
T.check(store.tomedown.import_prompt_done == true, "flag set after export")
T.check(T.fileExists(MD_PATH), "book md written by the prompt")
ConfirmBox.last = nil
plugin:addToMainMenu({})
UIManager:runPending()
T.check(ConfirmBox.last == nil, "prompt gone once exported")

-- flag lost but the library is already exported: still no prompt
store.tomedown.import_prompt_done = nil
plugin:addToMainMenu({})
UIManager:runPending()
T.check(ConfirmBox.last == nil, "no prompt for an already exported library")

-- empty history: nothing to offer
store.tomedown.import_prompt_done = nil
store.tomedown.exports = nil
readhistory.hist = {}
ConfirmBox.last = nil
plugin:addToMainMenu({})
UIManager:runPending()
T.check(ConfirmBox.last == nil, "no prompt without history")
readhistory.hist = hist
store.tomedown.import_prompt_done = nil

-- ------------------------------------- 12. auto-export and pending uploads

NetworkMgr.connected = true

-- toggle off (default): the close does nothing at all
uploadSetup()
ui.document = { file = FILE }
plugin:onCloseDocument()
T.check(UIManager:pendingCount() == 0, "toggle off: close schedules nothing")
T.check(#uploads == 0 and Notification.last_text == nil,
    "toggle off: nothing exported or notified")
ui.document = nil

-- toggle on: the close exports after 1s and uploads right away
files[6].callback()
T.check(files[6].checked_func() == true, "auto-export toggled on")
uploadSetup()
files[6].callback() -- uploadSetup wiped the setting
ui.document = { file = FILE }
plugin:onCloseDocument()
T.check(UIManager:pendingCount() == 1, "toggle on: close schedules the export")
T.check(UIManager.delay_log[1] == 1, "export runs 1s after the close: "
    .. tostring(UIManager.delay_log[1]))
UIManager:runPending()
T.check(#uploads == 2, "online close: book and index uploaded: " .. #uploads)
T.check(T.contains(Notification.last_text or "", "Cloud: 2 files uploaded"),
    "online close notification: " .. tostring(Notification.last_text))
T.check(#Notification.log == 2,
    "online close: two separate notifications: " .. #Notification.log)
T.check(Notification.log[1] ~= nil
        and Notification.log[1]:find("1 files exported", 1, true) ~= nil
        and Notification.log[1]:find("Cloud", 1, true) == nil,
    "online close: the export never waits for the cloud: "
        .. tostring(Notification.log[1]))
T.check(Notification.log[2] ~= nil
        and Notification.log[2]:find("Cloud: 2 files uploaded", 1, true) ~= nil,
    "online close: the upload reported after: " .. tostring(Notification.log[2]))
T.check(next(store.tomedown.pending_uploads or {}) == nil,
    "online close: nothing left pending")
ui.document = nil

-- without the cloud at all: one notification, right after the export
uploadSetup()
store.tomedown.upload = false
files[6].callback() -- uploadSetup wiped the auto-export setting too
ui.document = { file = FILE }
plugin:onCloseDocument()
UIManager:runPending()
T.check(#uploads == 0, "cloud off: no upload attempted")
T.check(#Notification.log == 1, "cloud off: one notification: " .. #Notification.log)
T.check(Notification.log[1] ~= nil
        and Notification.log[1]:find("1 files exported", 1, true) ~= nil,
    "cloud off: the export result on its own: " .. tostring(Notification.log[1]))
ui.document = nil

-- same book, no new highlights: no message, no upload
resetUpload()
plugin:onCloseDocument()
UIManager:runPending()
T.check(Notification.last_text == nil, "unchanged book: no notification")
T.check(#uploads == 0, "unchanged book: no upload")
ui.document = nil

-- offline close: exported locally, queued, the network is not touched
uploadSetup()
files[6].callback()
NetworkMgr.connected = false
ui.document = { file = FILE }
plugin:onCloseDocument()
UIManager:runPending()
T.check(#uploads == 0, "offline close: no upload attempted")
T.check(store.tomedown.pending_uploads[MD_PATH] == true
    and store.tomedown.pending_uploads[INDEX_PATH] == true,
    "offline close: book and index pending")
T.check(T.contains(Notification.last_text or "", "upload when online"),
    "offline close notification: " .. tostring(Notification.last_text))
ui.document = nil

-- the connection comes back: only the pending files go up
NetworkMgr.connected = true
plugin:onNetworkConnected()
T.check(UIManager:pendingCount() == 1, "reconnect schedules the flush")
T.check(UIManager.delay_log[#UIManager.delay_log] == 1,
    "flush runs 1s after the connection")
UIManager:runPending()
T.check(#uploads == 2, "reconnect: pending files uploaded: " .. #uploads)
T.check(T.contains(Notification.last_text or "", "Cloud: 2 files uploaded"),
    "reconnect notification: " .. tostring(Notification.last_text))
T.check(next(store.tomedown.pending_uploads or {}) == nil,
    "reconnect: pending list cleared")
T.check(T.contains(table.concat(logger.history, "\n"),
        "tomedown: flushing 2 pending uploads"),
    "flush logged to crash.log")

-- reconnect with nothing to do: no flush at all
plugin:onNetworkConnected()
T.check(UIManager:pendingCount() == 0, "reconnect without pending: nothing scheduled")

-- a failed upload stays pending, the next connection retries it
uploadSetup()
upload_script[MD_PATH] = { 500, 500, 500, 500 }
upload_script[INDEX_PATH] = { 500, 500, 500, 500 }
plugin:runExport({ FILE }, {})
UIManager:runPending()
T.check(store.tomedown.pending_uploads[MD_PATH] == true,
    "failed upload stays pending (book)")
T.check(store.tomedown.pending_uploads[INDEX_PATH] == true,
    "failed upload stays pending (index)")
resetUpload()
plugin:onNetworkConnected()
UIManager:runPending()
T.check(#uploads == 2, "retry after reconnect: uploaded once each: " .. #uploads)
T.check(next(store.tomedown.pending_uploads or {}) == nil,
    "retry clears the pending list")

-- suspend: local only and totally silent, even with the network up
uploadSetup()
files[6].callback()
ui.document = { file = FILE }
plugin:onSuspend()
T.check(UIManager:pendingCount() == 0, "suspend schedules nothing")
T.check(#uploads == 0, "suspend does not upload")
T.check(Notification.last_text == nil and #UIManager.shown == 0,
    "suspend export is silent")
T.check(store.tomedown.pending_uploads[MD_PATH] == true,
    "suspend export queued for the next connection")
ui.document = nil

-- toggle off again: suspend does not fire
uploadSetup()
ui.document = { file = FILE }
plugin:onSuspend()
T.check(#uploads == 0 and Notification.last_text == nil
    and store.tomedown.pending_uploads == nil, "toggle off: suspend does nothing")
ui.document = nil

-- wake up with pending uploads and the network already on
uploadSetup()
store.tomedown.pending_uploads = { [MD_PATH] = true }
plugin:onResume()
T.check(UIManager:pendingCount() == 1, "resume schedules the pending flush")
UIManager:runPending()
T.check(#uploads == 1, "resume flush uploads the pending file: " .. #uploads)
T.check(next(store.tomedown.pending_uploads or {}) == nil,
    "resume flush clears pending")

-- pending file deleted locally: dropped, nothing to upload
uploadSetup()
store.tomedown.pending_uploads = { [DIR .. "/ghost.md"] = true }
plugin:flushPendingUploads()
T.check(next(store.tomedown.pending_uploads or {}) == nil,
    "missing file dropped from pending")
T.check(#uploads == 0, "no upload for missing files")

-- the plugin sits in the UI event chain exactly once (events must
-- reach it once, not twice)
local in_chain = 0
for __, child in ipairs(ui) do
    if child == plugin then
        in_chain = in_chain + 1
    end
end
T.check(in_chain == 1, "plugin in the UI event chain exactly once: " .. in_chain)

-- --------------------------------------- 13. upload default and migration

store.tomedown = { exports = { ["/x.md"] = "h" } }
plugin:migrateDefaults()
T.check(store.tomedown.upload == true,
    "install that already exported keeps upload on")

store.tomedown = { exports = { ["/x.md"] = "h" }, upload = false }
plugin:migrateDefaults()
T.check(store.tomedown.upload == false, "explicit upload off is respected")

store.tomedown = { server = SERVER }
plugin:migrateDefaults()
T.check(store.tomedown.upload == nil, "fresh install starts with upload off")

-- ------------------------------- 14. covers, callout, special (v0.8.0)

local BookInfo = require("apps/filemanager/filemanagerbookinfo")

-- a fake BlitBuffer like the stubs': getWidth/getHeight/free plus a
-- writeToFile that leaves the parameters it received in the file
local function fakeBB(w, h)
    return {
        getWidth = function() return w end,
        getHeight = function() return h end,
        free = function() end,
        writeToFile = function(_, path, format, quality)
            local f = io.open(path, "wb")
            if not f then
                return false
            end
            f:write(string.format("JPG:%dx%d:%s:%d",
                w, h, tostring(format), tonumber(quality) or 0))
            f:close()
            return true
        end,
    }
end

local COVER_PATH = DIR .. "/covers/" .. BASE .. ".jpg"
local COVER_REL = "covers/" .. BASE .. ".jpg"

NetworkMgr.connected = true

-- the two new checkboxes flip their setting and invalidate the hashes
-- (covers/callout are not part of hashBook: without the invalidation
-- the already exported books would never be rewritten)
uploadSetup()
plugin:runExport({ FILE }, {})
T.check(store.tomedown.exports[FILE].hash ~= nil, "hash stored by the export")
files[4].callback()
T.check(store.tomedown.covers == true, "covers toggled on")
T.check(store.tomedown.exports[FILE].hash == nil,
    "the covers toggle invalidates the stored hash")
files[4].callback()
T.check(store.tomedown.covers == false, "covers toggled off again")
plugin:runExport({ FILE }, {})
T.check(store.tomedown.exports[FILE].hash ~= nil, "hash back after the export")
files[5].callback()
T.check(store.tomedown.callout == true, "callout toggled on")
T.check(store.tomedown.exports[FILE].hash == nil,
    "the callout toggle invalidates the stored hash too")
files[5].callback()

-- extraction: capped to the 800x1200 box, quality 50, colours kept
uploadSetup()
store.tomedown.covers = true
BookInfo.cover_bb = fakeBB(1600, 2400)
cleanDir()
plugin:runExport({ FILE }, {})
local md_content = T.readFile(MD_PATH)
T.check(T.fileExists(COVER_PATH), "cover extracted next to the md files")
T.check(T.readFile(COVER_PATH) == "JPG:800x1200:jpg:50",
    "scaled into the box at quality 50: " .. tostring(T.readFile(COVER_PATH)))
T.check(T.contains(md_content or "", 'cover: "' .. COVER_REL .. '"'),
    "frontmatter carries the cover")
T.check(T.contains(md_content or "", '<img src="' .. COVER_REL .. '"'),
    "the body embeds the cover")
local index_content = T.readFile(INDEX_PATH)
T.check(T.contains(index_content or "", COVER_REL), "the index row shows the cover")
T.check(T.contains(index_content or "", "width:90px;height:120px"),
    "the index cover is sized 90x120")

-- upload succeeds: the vault copy is the master one, the cover is
-- dropped from the device while the md files stay local
resetUpload()
cleanDir()
plugin:runExport({ FILE }, {})
UIManager:runPending()
T.check(#uploads == 3, "book, index and cover uploaded: " .. #uploads)
T.check(not T.fileExists(COVER_PATH), "the uploaded cover is removed")
T.check(T.fileExists(MD_PATH), "the md files stay local")
T.check(next(store.tomedown.pending_uploads or {}) == nil, "nothing pending")

-- offline: the cover is queued with everything else and goes up at the
-- next connection
resetUpload()
cleanDir()
NetworkMgr.connected = false
plugin:runExport({ FILE }, {})
T.check(#uploads == 0, "offline: nothing uploaded")
T.check(store.tomedown.pending_uploads[COVER_PATH] == true, "cover queued offline")
T.check(T.fileExists(COVER_PATH), "cover kept while offline")
NetworkMgr.connected = true
plugin:onNetworkConnected()
UIManager:runPending()
T.check(#uploads == 3, "the flush uploads the cover too: " .. #uploads)
T.check(not T.fileExists(COVER_PATH), "the flushed cover is removed too")

-- the index backfills a cover that is missing while the option is on
local entries, new_covers = plugin:buildIndexEntries(DIR, store.tomedown.exports)
T.check(entries[1] and entries[1].cover == COVER_REL,
    "the entry got the backfilled cover")
T.check(#new_covers == 1 and new_covers[1] == COVER_PATH,
    "the backfilled cover is listed for the upload")

-- the callout option rewrites every highlight of the book
resetUpload()
store.tomedown.callout = true
plugin:runExport({ FILE }, {})
local callout_md = T.readFile(MD_PATH) or ""
local expected = tonumber(callout_md:match("highlights: (%d+)")) or 0
local n_callouts = select(2, callout_md:gsub("%[!highlight%]", ""))
T.check(expected > 0 and n_callouts == expected,
    "every highlight becomes a callout: " .. n_callouts .. "/" .. expected)
store.tomedown.callout = false

-- Special Highlight: registered when the reader is ready. The button
-- sorts right under KOReader's Highlight button (the menu is ordered
-- alphabetically by key), creates+marks on a fresh selection, toggles on
-- an existing highlight with a dynamic label, and gets a twin row
-- appended at the bottom of the compact edit menu through the
-- showHighlightDialog hook. The mark lives on the annotation itself.
local fake_highlight = {
    dialogs = {},
    ui = ui,
    onClose = function() end,
}
function fake_highlight:addToHighlightDialog(idx, fn)
    self.dialogs[idx] = fn
end
-- like ReaderHighlight:saveHighlight — a new annotation is appended and
-- its index handed back to the callback (color prompt aside)
function fake_highlight:showHighlightPrompt(caller_callback)
    table.insert(ui.annotation.annotations, {
        drawer = "underline", text = "Seconda frase.", pageno = 11,
        datetime = "2026-09-03 10:00:00",
    })
    caller_callback(#ui.annotation.annotations)
end
ui.highlight = fake_highlight
ui.annotation = { annotations = {
    { drawer = "underline", text = "Prima frase.", pageno = 10,
        datetime = "2026-09-02 10:00:00" },
} }
local saved_annotations
ui.doc_settings = {
    saveSetting = function(_, key, value)
        if key == "annotations" then
            saved_annotations = value
        end
    end,
}
plugin:onReaderReady()
local special_key = "03b_special"
local special_fn = fake_highlight.dialogs[special_key]
T.check(special_fn ~= nil, "the button is registered on ReaderReady")
T.check(special_key > "03_copy" and special_key < "04_add_note",
    "the key sorts between Copy and Add note, i.e. right under Highlight: "
        .. special_key)
local plain_button = special_fn(fake_highlight, 1)
T.check(plain_button.show_in_highlight_dialog_func == nil,
    "no visibility filter: the button is always in the menu")
T.check(plain_button.text == "Special Highlight", "plain label when not marked")
plain_button.callback()
T.check(ui.annotation.annotations[1].tomedown_special == true, "marked")
T.check(saved_annotations == ui.annotation.annotations,
    "the mark is written back to the doc settings")
T.check(Notification.last_text == "Highlight marked as special",
    "mark notification: " .. tostring(Notification.last_text))
local marked_button = special_fn(fake_highlight, 1)
T.check(marked_button.text == "Remove Special Highlight",
    "dynamic label once marked: " .. tostring(marked_button.text))
marked_button.callback()
T.check(ui.annotation.annotations[1].tomedown_special == nil, "unmarked again")
T.check(Notification.last_text == "Special mark removed",
    "unmark notification: " .. tostring(Notification.last_text))

-- on a fresh text selection the button creates the highlight first
local fresh_button = special_fn(fake_highlight, nil)
T.check(fresh_button.text == "Special Highlight", "fresh label is plain")
fresh_button.callback()
T.check(#ui.annotation.annotations == 2, "the highlight was created")
T.check(ui.annotation.annotations[2].tomedown_special == true,
    "the created highlight is marked as special")
T.check(Notification.last_text == "Highlight marked as special",
    "creation notification: " .. tostring(Notification.last_text))
table.remove(ui.annotation.annotations, 2)

-- the compact edit menu (tap on an existing highlight): the hook appends
-- a dynamic-label row after the arrows, and wraps showHighlightDialog
-- exactly once even when the reader is reopened
plugin:onReaderReady()
local ReaderHighlight = require("apps/reader/modules/readerhighlight")
local fake_reader = { ui = ui }
ReaderHighlight.showHighlightDialog(fake_reader, 1)
local edit_opts = require("ui/widget/buttondialog").last_opts
T.check(edit_opts ~= nil and edit_opts.name == "edit_highlight_dialog",
    "the compact edit menu was built")
T.check(edit_opts ~= nil and #edit_opts.buttons == 3,
    "our row appended at the bottom, after the arrows: "
        .. tostring(edit_opts and #edit_opts.buttons))
local edit_button = edit_opts.buttons[3][1]
T.check(edit_button.text == "Special Highlight",
    "plain label on an unmarked highlight")
edit_button.callback()
T.check(ui.annotation.annotations[1].tomedown_special == true,
    "one tap in the edit menu marks it")
T.check(Notification.last_text == "Highlight marked as special",
    "edit menu mark notification: " .. tostring(Notification.last_text))
-- reopen: the label tells what the next tap will do, row not duplicated
ReaderHighlight.showHighlightDialog(fake_reader, 1)
edit_opts = require("ui/widget/buttondialog").last_opts
T.check(#edit_opts.buttons == 3, "still a single row on re-open")
T.check(edit_opts.buttons[3][1].text == "Remove Special Highlight",
    "dynamic label once marked: " .. tostring(edit_opts.buttons[3][1].text))
edit_opts.buttons[3][1].callback()
T.check(ui.annotation.annotations[1].tomedown_special == nil,
    "one tap unmarks it")
T.check(Notification.last_text == "Special mark removed",
    "edit menu unmark notification: " .. tostring(Notification.last_text))

-- and the mark reaches the markdown as a callout
ui.annotation.annotations[1].tomedown_special = true
ui.document = { file = FILE }
store.tomedown.upload = false
cleanDir()
plugin:runExport({ FILE }, {})
local special_md = T.readFile(MD_PATH) or ""
T.check(T.contains(special_md, "> [!highlight]\n> Prima frase."),
    "the special highlight is rendered as a callout")
ui.document = nil
ui.annotation = nil
ui.highlight = nil
ui.doc_settings = nil
BookInfo.cover_bb = nil

T.finish("test_main")
