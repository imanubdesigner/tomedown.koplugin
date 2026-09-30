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

local MdBook = require("main")
local plugin = MdBook:new { ui = ui }

-- ------------------------------------------------------------- helpers

local function resetUpload()
    uploads, attempt_count, upload_script = {}, {}, {}
    UIManager:reset()
    Notification.last_text = nil
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
    T.check(T.contains(md, "  - kindle"), "tag kindle")
    T.check(T.contains(md, "# Blackwater"), "h1")
    T.check(T.contains(md, "**2 highlights**"), "count")
    T.check(T.contains(md, "## Capitolo I"), "chapter 1")
    T.check(T.contains(md, "## Capitolo II"), "chapter 2")
    T.check(T.contains(md, "> Prima frase."), "quote")
    T.check(T.contains(md, "- **p. 10** · 02/09/2026 · note: nota utente"), "meta with note")
    T.check(T.contains(md, "nota utente"), "note present")
    T.check(not T.contains(md, "Segnalibro"), "page bookmark excluded")
    T.check(not T.contains(md, "Cancellato"), "deleted highlight excluded")
    T.check(not T.contains(md, "cover"), "no cover")
    T.check(not T.contains(md, "![]("), "nessuna immagine")
end

T.check(Notification.last_text == "1 files exported",
    "export notification: " .. tostring(Notification.last_text))
T.check(lfs.attributes(DIR .. "/covers", "mode") ~= "directory",
    "covers folder not created")

local index = T.readFile(INDEX_PATH)
T.check(index ~= nil, "index written")
if index then
    T.check(T.contains(index, "[[Michael McDowell - Blackwater|Blackwater]]"),
        "wikilink in the index")
    T.check(T.contains(index, "| 2 |"), "index columns (count)")
    T.check(T.contains(index, os.date("%d/%m/%Y")), "today's date in the index")
end

-- index with more rows after exporting every book
plugin:runExport(plugin:listBookFiles(), {})
UIManager:runPending()
T.check(#plugin:listBookFiles() == 3, "three books listed (dim excluded)")
T.check(Notification.last_text == "3 files exported",
    "multi export: " .. tostring(Notification.last_text))

index = T.readFile(INDEX_PATH)
if index then
    T.check(T.contains(index, "[[N_A - LibroVecchio|LibroVecchio]]"),
        "old .sdr book in the index")
    T.check(T.contains(index, "[[Autore X - Senza Meta|Senza Meta]]"),
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
T.check(#sub == 6, "main menu entries: " .. #sub)
T.check(sub[1].text == "Export current book", "menu item 1")
T.check(sub[2].text == "Only updated", "menu item 2")
T.check(sub[3].text == "Choose books…", "menu item 3")
T.check(sub[4].text == "Import all books from history", "menu item 4")
T.check(sub[5].text == "Reload everything to the cloud", "menu item 5")
T.check(sub[6].text == "Settings", "menu item 6")

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
T.check(#settings == 11, "settings entries: " .. #settings)
T.check(settings[1].text == "Upload to cloud", "upload entry")
T.check(settings[2].text_func() == "Server and folder: not set", "server not set")
T.check(T.contains(settings[3].text_func(), "Remote folder: not set"), "remote folder not set")
T.check(T.contains(settings[4].text_func(), "clipboard/tomedown"), "default local folder")
T.check(T.contains(settings[5].text, "00 - Index.md"), "index entry with the file name")
T.check(settings[6].text == "Include page bookmarks", "page bookmarks entry")
T.check(settings[6].checked_func() == false, "page bookmarks off by default")
T.check(settings[7].text == "Auto-export on close", "auto-export entry")
T.check(settings[7].checked_func() == false, "auto-export off by default")
T.check(settings[11].text == "Beta Releases", "beta releases entry")
T.check(settings[11].checked_func() == false, "beta releases off by default")

-- checkable rows must keep the menu open so KOReader refreshes them
for i, row in ipairs(settings) do
    if row.checked_func then
        T.check(row.keep_menu_open == true,
            "checkable settings row " .. i .. " keeps the menu open")
    end
end
local main_src = T.readFile(T.plugin .. "/main.lua") or ""
T.check(not main_src:find("check_callback_updates_menu", 1, true),
    "no check_callback_updates_menu (it opts out of the menu refresh)")

settings[1].callback()
T.check(store.tomedown.upload == false, "upload disabled")
settings[1].callback()
T.check(store.tomedown.upload == true, "upload re-enabled")
settings[5].callback()
T.check(store.tomedown.with_index == false, "index disabled")
settings[5].callback()
T.check(store.tomedown.with_index == true, "index re-enabled")
settings[6].callback()
T.check(store.tomedown.include_bookmarks == true, "page bookmarks enabled")
settings[6].callback()
T.check(store.tomedown.include_bookmarks == false, "page bookmarks disabled")
settings[11].callback()
T.check(store.tomedown.beta_releases == true, "beta releases enabled")
settings[11].callback()
T.check(store.tomedown.beta_releases == false, "beta releases disabled")

-- server picked from the Cloud storage list
plugin:chooseCloudFolder(nil)
T.check(cloud_list_callback ~= nil, "cloud list opened")
cloud_list_callback({ name = "Koofr", type = "webdav", url = "/Bookshelf/Kindle" })
T.check(store.tomedown.server and store.tomedown.server.name == "Koofr", "server saved")
T.check(settings[2].text_func() == "Server and folder: Koofr (webdav) → /Bookshelf/Kindle",
    "server text updated: " .. settings[2].text_func())
T.check(plugin:hasServer() == true, "hasServer true with server and cloud")

-- remote folder dialog
plugin:editRemoteFolder(nil)
local dialog = InputDialog.last
T.check(dialog ~= nil and dialog.title == "Remote folder on the server", "remote dialog opened")
dialog.input_text = "  /Cartella mia  "
dialog:simulateSave()
T.check(store.tomedown.remote_folder == "/Cartella mia", "remote folder saved and trimmed")
T.check(T.contains(settings[3].text_func(), "/Cartella mia"), "menu entry updated")
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
T.check(Notification.last_text == "1 files exported",
    "export of the selected: " .. tostring(Notification.last_text))

picker = plugin:genPickerMenu()
picker[2].callback(nil)
T.check(store.tomedown.selected[FILE] == nil, "deselect all")

store = {}
store.tomedown = {}
T.check(plugin:genPickerMenu()[1].text_func() == "Export selected (0)",
    "no selection after the reset")

-- ----------------------------------------------- 5b. page bookmarks

settings[6].callback() -- enable "Include page bookmarks"
T.check(store.tomedown.include_bookmarks == true, "page bookmarks enabled for the export")
plugin:runExport({ FILE }, {})
UIManager:runPending()
local bmMd = T.readFile(MD_PATH)
T.check(bmMd ~= nil, "export with page bookmarks")
if bmMd then
    T.check(T.contains(bmMd, "## Page bookmarks"), "bookmarks section")
    T.check(T.contains(bmMd, "> Segnalibro di pagina"), "bookmark note quoted")
    T.check(T.contains(bmMd, "- **p. 5** · 01/09/2026"), "bookmark meta row")
    T.check(T.contains(bmMd, "highlights: 2"), "highlight count unchanged")
    local iBm = bmMd:find("## Page bookmarks", 1, true)
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
    T.check(not T.contains(onlyBmMd, "**0 highlights**"), "no zero count line in the body")
    T.check(T.contains(onlyBmMd, "## Page bookmarks"), "bookmark-only section")
    T.check(T.contains(onlyBmMd, "> Solo un segnalibro"), "bookmark-only quote")
end

-- disabled again: the section disappears
settings[6].callback()
T.check(store.tomedown.include_bookmarks == false, "page bookmarks disabled again")
plugin:runExport({ FILE }, {})
UIManager:runPending()
local bmOffMd = T.readFile(MD_PATH)
T.check(bmOffMd ~= nil and not T.contains(bmOffMd, "## Page bookmarks"),
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
T.check(#UIManager.shown == 1 and UIManager.shown[1].text == InfoMessage.last_text,
    "progress still open during the upload phase")
UIManager:runPending()
T.check(#uploads == 2, "uploaded md and index: " .. #uploads)
T.check(uploads[2].path == INDEX_PATH, "second file = index")
T.check(uploads[1].url == "/Bookshelf/Kindle" and uploads[2].url == "/Bookshelf/Kindle",
    "Koofr folder url")
T.check(attempt_count[MD_PATH] == 1 and attempt_count[INDEX_PATH] == 1,
    "one attempt per file in normal conditions")
T.check(T.contains(Notification.last_text or "", "Cloud: 2 files uploaded"),
    "upload notification: " .. tostring(Notification.last_text))
local widget = onlyWidget()
T.check(widget and widget.__widget == "Notification",
    "only the final notification stays open")

-- upload disabled
uploadSetup()
store.tomedown.upload = false
plugin:runExport({ FILE }, {})
UIManager:runPending()
T.check(#uploads == 0, "no upload with upload=false")
T.check(Notification.last_text == "1 files exported",
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
T.check(Notification.last_text == nil, "no success notification")
local err_widget = onlyWidget()
T.check(err_widget and err_widget.__widget == "InfoMessage", "error window shown")
T.check(err_widget and T.contains(err_widget.text, "Cloud: 0 uploaded, 2 errors"),
    "result with errors: " .. tostring(err_widget and err_widget.text))
T.check(err_widget and T.contains(err_widget.text, "1 files exported"),
    "the result also includes the export: " .. tostring(err_widget and err_widget.text))

-- 4xx (missing folder): no retry
uploadSetup()
upload_script[MD_PATH] = { 404 }
upload_script[INDEX_PATH] = { 404 }
plugin:runExport({ FILE }, {})
UIManager:runPending()
T.check(#uploads == 2, "404: one attempt per file only: " .. #uploads)
T.check(#positives() == 0, "no delay on 4xx errors: " .. listStr(positives()))
err_widget = onlyWidget()
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

-- a leftover covers folder must not end up in the upload
os.execute('mkdir -p "' .. DIR .. '/covers" && printf x > "' .. DIR .. '/covers/copertina.jpg"')

resetUpload()
store.tomedown.upload = true
plugin:reuploadAll(nil)
UIManager:runPending()
T.check(#uploads == 2, "only the .md files re-uploaded: " .. #uploads)
T.check(uploads[1].path == INDEX_PATH, "ordered: index first")
T.check(uploads[2].path == MD_PATH, "ordered: book md second")
T.check(Notification.last_text == "Cloud: 2 files uploaded",
    "reload notification: " .. tostring(Notification.last_text))
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

-- ------------------------------------------- 10. no cover anywhere

local sources = { "main.lua", "tomedown_render.lua", "README.md" }
for __, name in ipairs(sources) do
    local src = T.readFile(T.plugin .. "/" .. name)
    if src then
        local lower = src:lower()
        T.check(not lower:find("buildcover") and not lower:find("cover_path")
            and not lower:find("covers/", 1, true),
            name .. " has no cover references left")
    end
end

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
settings[7].callback()
T.check(settings[7].checked_func() == true, "auto-export toggled on")
uploadSetup()
settings[7].callback() -- uploadSetup wiped the setting
ui.document = { file = FILE }
plugin:onCloseDocument()
T.check(UIManager:pendingCount() == 1, "toggle on: close schedules the export")
T.check(UIManager.delay_log[1] == 1, "export runs 1s after the close: "
    .. tostring(UIManager.delay_log[1]))
UIManager:runPending()
T.check(#uploads == 2, "online close: book and index uploaded: " .. #uploads)
T.check(T.contains(Notification.last_text or "", "Cloud: 2 files uploaded"),
    "online close notification: " .. tostring(Notification.last_text))
T.check(next(store.tomedown.pending_uploads or {}) == nil,
    "online close: nothing left pending")
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
settings[7].callback()
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
settings[7].callback()
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

-- the plugin sits in the UI event chain (events reach it)
local in_chain = false
for __, child in ipairs(ui) do
    if child == plugin then
        in_chain = true
    end
end
T.check(in_chain, "plugin registered in the UI event chain")

T.finish("test_main")
