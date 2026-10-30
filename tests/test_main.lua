--[[--
Tests for main.lua with a fake KOReader environment.

Covers: md5 hash, export, index, legacy .sdr format, menu, dialogs,
fallback servers, Koofr upload and above all the backoff patch
(UPLOAD_MAX_ATTEMPTS = 3, 2s/4s delays, transient errors only).

Everything below is one script, so every local shares the same function,
and Lua caps a function at 200 local variables: Lua 5.4 (the one CI
runs) refuses to compile past that, the versions before and after it do
not complain. A section that grows wraps itself in `do ... end`, whose
variables are freed the moment the block closes, which is what keeps the
count down here.
--]]
local HERE = arg[0]:match("^(.*)/") or "."
package.path = HERE .. "/?.lua;" .. package.path
local T = require("common")

-- --------------------------------------------------------------- environment

local store = {}
-- how many times the settings reached the disk: the local folder
-- picker must flush on its own, KOReader only saves every 15 minutes
local flushes = 0
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
    flush = function()
        flushes = flushes + 1
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
local created_folders = {}
local cloud_list_callback

local provider = {}
function provider.run(callback)
    -- KOReader: checks the connection, then runs the step
    callback()
end
function provider.createFolder(url, folder_name)
    created_folders[#created_folders + 1] = { url = url, name = folder_name }
    return true
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

-- what the cloud holds right now, per file name: the tests write the
-- "remote copy" here to play an edit made in Obsidian and synced back
local remote_files, download_fails, downloads = {}, {}, {}
function provider.downloadFile(url, local_path)
    downloads[#downloads + 1] = url
    local name = url:match("([^/]+)$")
    if download_fails[name] then
        return 500
    end
    local content = remote_files[name]
    if not content then
        return 404
    end
    local f = io.open(local_path, "wb")
    if not f then
        return 404
    end
    f:write(content)
    f:close()
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

-- the same highlights plus a new one: what the reader marks while the
-- device is away from the network
local function modernAnnotationsWithExtra()
    local list = modernAnnotations()
    list[#list + 1] = {
        drawer = "underline",
        text = "Una frase letta offline.",
        pageno = 12,
        datetime = "2026-09-04 08:00:00",
        chapter = "Capitolo I",
    }
    return list
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
    { file = FILE, time = os.time() },
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

-- the export follows the order of the text, like a paper book:
-- positions beat page numbers, which only describe one layout
local sorted = plugin:cleanAnnotations({
    { drawer = "underline", text = "B", pageno = 37,
        datetime = "2026-10-04 19:00:00",
        pos0 = "/body/DocFragment[16]/body/p[10]/text().0" },
    { drawer = "underline", text = "A", pageno = 39,
        datetime = "2026-10-04 20:00:00",
        pos0 = "/body/DocFragment[8]/body/p[2]/text().0" },
    { drawer = "underline", text = "C", pageno = 38,
        datetime = "2026-10-04 21:00:00",
        pos0 = "/body/DocFragment[16]/body/p[8]/text().0" },
})
T.check(sorted[1].text == "A" and sorted[2].text == "C" and sorted[3].text == "B",
    "positions in the text sort the highlights, not the page numbers: "
    .. sorted[1].text .. sorted[2].text .. sorted[3].text)

-- ------------------------------------------------------------- helpers

local function resetUpload()
    uploads, attempt_count, upload_script = {}, {}, {}
    created_folders = {}
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
    T.check(T.contains(md, "# **2 highlights**"), "count")
    T.check(T.contains(md, "\n# Capitolo I"), "chapter 1")
    T.check(T.contains(md, "\n# Capitolo II"), "chapter 2")
    T.check(T.contains(md, "> Prima frase."), "quote")
    T.check(T.contains(md, "- **p. 10** · 02/09/2026 10:00\n  - **NOTE:** *nota utente*"), "meta with note")
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
    T.check(T.contains(index, os.date("%d/%m/%Y")),
        "today's date in the index (last read)")
    T.check(not T.contains(index, "Last export"),
        "the export date column is gone from the index")
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
    T.check(T.contains(legacy_md, "**NOTE:** *nota vecchia*"), "note from legacy bookmarks")
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
    keywords = "horror, gothic-fiction, Occult & Supernatural, "
        .. "American Horror tales, Horror tales; American, !!!",
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
    T.check(T.contains(richMd, "  - Occult-Supernatural"),
        "dirty keyword sanitized: spaces and &")
    T.check(T.contains(richMd, "  - American-Horror-tales"),
        "keyword with spaces becomes a dash tag")
    T.check(T.contains(richMd, "  - Horror-tales-American"),
        "keyword with a semicolon sanitized")
    T.check(not T.contains(richMd, "Occult &"),
        "the raw keyword never reaches the frontmatter")
    T.check(not T.contains(richMd, "!!!"),
        "a keyword that sanitizes to nothing is dropped")
    local iSeries = richMd:find("series:", 1, true)
    local iIndex = richMd:find("series_index:", 1, true)
    local iLang = richMd:find('language:', 1, true)
    T.check(iSeries and iIndex and iLang and iSeries < iIndex and iIndex < iLang,
        "series, series_index, language in order")
end
-- the index reads what the book record carries: series, status,
-- progress and when it was last opened
local rich_index = T.readFile(INDEX_PATH)
T.check(T.contains(rich_index or "", "| Blackwater #4 | Complete<br>"),
    "the index row carries the series and the status")
T.check(T.contains(rich_index or "", "▰▰▰▰▰▰▰▰▰▰&nbsp;96% |"),
    "the reading bar with the percent glued to it")
T.check(T.contains(rich_index or "", "| Status | Last read | Highlights |"),
    "the date sits in a column of its own")
T.check(T.contains(rich_index or "", os.date("%d/%m/%Y")),
    "the index row carries the last read date")
T.check(T.contains(rich_index or "", "### Series books")
        and T.contains(rich_index or "", "### My books"),
    "the series books and the rest sit under their own headings")
T.check(not T.contains(rich_index or "", "Last export"),
    "no export date column in the rich index either")
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
-- the rows are fixed (v1.1): everything that names the open book lives
-- in the Current book submenu, so only that row and the export come and
-- go with the document
T.check(type(menu_items.tomedown.sub_item_table_func) == "function",
    "the book menu builds its rows on open")
local sub = menu_items.tomedown.sub_item_table_func()
T.check(#sub == 9, "main menu entries: " .. #sub)
T.check(sub[1].text == "\xEE\x89\xBC  Export this book", "menu item 1")
T.check(sub[2].text == "\xEE\xA4\xB5  Export new and changed books", "menu item 2")
T.check(sub[3].text == "\xEE\xA7\x99  Export all books", "menu item 3")
T.check(sub[4].text == "\xEE\xB9\x94  Choose books…", "menu item 4")
T.check(sub[4].separator == true, "separator after Choose books")
T.check(sub[5].text == "\xEF\x81\x80  Current book",
    "menu item 5, the per book submenu")
T.check(sub[5].separator == true, "separator after Current book")
T.check(sub[6].text == "\xEE\xB4\xBE  Upload all files again", "menu item 6")
T.check(sub[7].text == "\xEF\x83\xA4  Last export", "menu item 7")
T.check(sub[7].separator == true, "separator before Settings")
T.check(sub[8].text == "\xEF\x80\x93  Settings", "menu item 8 with the cog")
T.check(sub[8].separator ~= true, "no separator before About")
T.check(sub[9].text == "\xEE\xA7\xBC  About", "menu item 9")

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
T.check(sub[1].enabled_func() == true, "export this book enabled with the book open")
ui.document = nil
-- the two rows that name a book need the document: "lastfile" names the
-- last one read, and must not bring either row back onto the dashboard
store.lastfile = FILE
local dashboard = menu_items.tomedown.sub_item_table_func()
T.check(#dashboard == 7,
    "no book rows on the dashboard: " .. #dashboard)
T.check(dashboard[1].text == "\xEE\xA4\xB5  Export new and changed books",
    "the dashboard menu starts on the first row that needs no book")
T.check(dashboard[3].text == "\xEE\xB9\x94  Choose books…"
        and dashboard[3].separator == true,
    "Choose books closes the first group on the dashboard")
T.check(dashboard[4].text == "\xEE\xB4\xBE  Upload all files again",
    "the dashboard skips Current book")
T.check(dashboard[5].text == "\xEF\x83\xA4  Last export"
        and dashboard[5].separator == true,
    "Last export sits where the book rows were")
T.check(dashboard[6].text == "\xEF\x80\x93  Settings", "settings follows")
T.check(dashboard[7].text == "\xEE\xA7\xBC  About", "about closes the dashboard menu")
local offered_current = false
for __, item in ipairs(dashboard) do
    if item.text and item.text:find("Current book", 1, true) then
        offered_current = true
    end
end
T.check(not offered_current,
    "the Current book row is not offered without a book open")
store.lastfile = nil
ui.document = { file = nil }
T.check(sub[1].enabled_func() == false, "export this book disabled without a file")
ui.document = { file = nil }
T.check(sub[3].enabled_func() == true, "export all books enabled")

-- Current book: the keep row is always there while a book is open, so
-- the stored per book choice stays reachable when the global switch in
-- Settings goes off again. Off with the global switch on, with the
-- reason on the right, since the switch is disabled but not hidden.
do
    ui.document = { file = FILE }
    local current = sub[5].sub_item_table_func()
    T.check(#current == 1, "Current book starts with the keep row: " .. #current)
    T.check(current[1].text == "\xEF\x81\x80  Keep my notes in this book",
        "the per book keep row")
    T.check(current[1].enabled_func() == true, "keep row enabled with the book open")
    T.check(current[1].checked_func() == false,
        "the row shows the global default until the book chooses")
    T.check(current[1].mandatory_func() == nil,
        "no reason on the right while the row is in charge")
    T.check(current[1].keep_menu_open == true,
        "the keep row keeps the menu open for its tick")
    ui.document = nil
    store.lastfile = FILE
    T.check(#menu_items.tomedown.sub_item_table_func() == 7,
        "the keep row stays off the dashboard")
    store.lastfile = nil
    ui.document = { file = nil }
end

local settings = plugin:genSettingsMenu()
T.check(#settings == 5, "settings groups: " .. #settings)
T.check(settings[1].text == "\xEF\x83\xB6  Files", "files group with icon")
T.check(settings[1].sub_item_table ~= nil, "Files is a static group")
T.check(settings[2].text == "\xEE\xB4\xBE  Cloud", "cloud group with icon")
T.check(settings[3].text == "\xEF\x89\x89  My notes", "my notes group with icon")
T.check(settings[4].text == "\xEE\xB5\x91  Highlights for Obsidian",
    "highlights group with icon")
T.check(settings[5].text == "\xEE\xB6\xAE  Updates", "updates group with icon")
-- Cloud: three fixed rows since 1.1. The row that brings the cloud copy
-- back now lives in My notes, where the notes are.
local cloud = settings[2].sub_item_table
local updates = settings[5].sub_item_table
T.check(#cloud == 3, "cloud rows without a server: " .. #cloud)
T.check(#updates == 4, "updates rows: " .. #updates)
T.check(cloud[1].text == "Upload to cloud", "upload entry")
T.check(cloud[2].text_func() == "Server and folder: not set", "server not set")
T.check(T.contains(cloud[3].text_func(), "Remote folder: not set"), "remote folder not set")
-- Files: five static rows, none of them appears or disappears
local files = settings[1].sub_item_table
T.check(#files == 5, "files rows: " .. #files)
T.check(T.contains(files[1].text_func(), "clipboard/tomedown"), "default local folder")
T.check(files[2].text == "Create an index note (00 - Index.md)",
    "index entry with the file name")
T.check(files[3].text == "Include page bookmarks", "page bookmarks entry")
T.check(files[3].checked_func() == false, "page bookmarks off by default")
T.check(files[4].text == "Include book covers", "covers entry")
T.check(files[4].checked_func() == false, "covers off by default")
T.check(files[5].text == "Export when I close a book", "auto-export entry")
T.check(files[5].checked_func() == false, "auto-export off by default")
-- My notes: the global switch, the index switch while the global one is
-- off, the headings of the zones, and the cloud merge. Rebuilt on open
-- and in place when a switch in it flips.
local notes = settings[3].sub_item_table_func()
T.check(#notes == 2, "notes rows with preserve off: " .. #notes)
T.check(notes[1].text == "Keep my notes: all books", "global switch entry")
T.check(notes[1].checked_func() == false,
    "manual edits off by default (the tomedown <= 0.8 behaviour)")
T.check(notes[2].text == "Keep my notes: index",
    "the index keep entry")
T.check(notes[2].checked_func() == false,
    "the index follows the global switch by default")
T.check(notes[3] == nil,
    "no heading row while preserve is off and the index is plain")

-- Highlights for Obsidian: its own group since 1.1, the three rows that
-- speak about the highlights themselves
local highlights = settings[4].sub_item_table
T.check(#highlights == 3, "highlights rows: " .. #highlights)
T.check(highlights[1].text == "Treat every highlight as special",
    "callout entry")
T.check(highlights[1].checked_func() == false, "callout off by default")
T.check(type(highlights[2].text_func) == "function", "special marker row present")
T.check(T.contains(highlights[2].text_func(), "Callout"),
    "special marker default Callout")
T.check(highlights[2].enabled_func() == true,
    "special marker enabled while every highlight is not a callout yet")
T.check(highlights[2].sub_item_table
        and #highlights[2].sub_item_table == 2,
    "special marker submenu has 2 items: callout and bold")
local marker_items = highlights[2].sub_item_table
T.check(marker_items[1].text == "Callout" and marker_items[1].checked_func(),
    "the callout choice is the one on")
T.check(marker_items[2].text == "Bold" and marker_items[2].checked_func() == false,
    "the bold choice starts off")
T.check(highlights[3].text == "Add link IDs to highlights", "block ids entry")
T.check(highlights[3].checked_func() == false, "block ids off by default")
-- with every highlight becoming a callout the marker row has nothing
-- left to choose, and graying it out is the only way to say so
highlights[1].callback()
T.check(highlights[2].enabled_func() == false,
    "special marker row disabled while every highlight is a callout")
highlights[1].callback()
T.check(highlights[2].enabled_func() == true,
    "special marker row back once the callout option is off")

-- flipping preserve shows the heading row in the open group, without
-- leaving it, and takes the index rows away: with the switch on it
-- alone governs every file, so nothing else is on show
local live = settings[3].sub_item_table_func()
local open_menu = { item_table = live }
live[1].callback(open_menu)
T.check(store.tomedown.preserve == true, "preserve toggled on")
T.check(#live == 2, "heading row appears with preserve on: " .. #live)
local notes_row = live[2]
T.check(notes_row.text_func() == "Notes heading: My notes...",
    "notes heading entry: " .. notes_row.text_func())
T.check(live[2] == notes_row and live[3] == nil,
    "the heading row sits right under the switch: the index rows are hidden")

-- rename dialog
plugin:editNotesTitle(nil)
T.check(InputDialog.last ~= nil
        and InputDialog.last.title == "Notes heading",
    "notes heading dialog opened")
InputDialog.last.input_text = "  Appunti miei  "
InputDialog.last:simulateSave()
T.check(store.tomedown.notes_title == "Appunti miei",
    "heading saved and trimmed")
T.check(notes_row.text_func() == "Notes heading: Appunti miei",
    "menu entry updated")
plugin:editNotesTitle(nil)
InputDialog.last.input_text = ""
InputDialog.last:simulateSave()
T.check(store.tomedown.notes_title == "", "an empty title clears the heading")
store.tomedown.notes_title = nil
T.check(notes_row.text_func() == "Notes heading: My notes...",
    "back to the default heading")

-- back off: the heading row leaves the open group again and the index
-- switch comes back to take its place
live[1].callback(open_menu)
T.check(store.tomedown.preserve == false, "preserve toggled back off")
T.check(#live == 2, "heading row disappears with preserve off: " .. #live)
T.check(live[2].text == "Keep my notes: index",
    "the index switch is back, with no heading row under it")
T.check(notes[1].checked_func() == false, "the toggle reflects the setting")
store.tomedown.preserve = nil

-- Generate off takes the index keep row away too, and back on brings it
-- (v1.1): there is no index to keep edits in without it
files[2].callback()
T.check(store.tomedown.with_index == false, "index generation toggled off")
live = plugin:genSettingsMenu()[3].sub_item_table_func()
T.check(#live == 1, "the index row leaves with the index: " .. #live)
files[2].callback()
T.check(store.tomedown.with_index == true, "index generation back on")
live = plugin:genSettingsMenu()[3].sub_item_table_func()
T.check(#live == 2, "the index row comes back with the index: " .. #live)
T.check(live[2].checked_func() == false,
    "the index switch still follows the global one")

-- ------------- 16b. the Merge row needs the full cloud setup
-- server + upload + preserve: without all three it is not shown at all,
-- and My notes rebuilds in place when its own switch flips (so the
-- reader never has to leave and re-enter the group to see it appear or
-- vanish)
do
uploadSetup()
store.tomedown.preserve = false
local notes_live = settings[3].sub_item_table_func()
T.check(#notes_live == 2,
    "no Merge row with preserve off: " .. #notes_live)

-- the settings speak about the global switch only: a book's own choice
-- lives in its own menu, so a preserved book brings no Merge row here
-- (the choice is cleared again below)
store.tomedown.preserve_books = { [FILE] = true }
notes_live = settings[3].sub_item_table_func()
T.check(#notes_live == 2,
    "no Merge row for a preserved book while the global is off: "
        .. #notes_live)
store.tomedown.preserve_books = nil
notes_live = settings[3].sub_item_table_func()
T.check(#notes_live == 2,
    "no Merge row once the book's choice is cleared: " .. #notes_live)

-- flip the global switch while My notes is open: the row appears in
-- place, without leaving the menu
local notes_menu = { item_table = notes_live }
notes_live[1].callback(notes_menu)
T.check(store.tomedown.preserve == true, "preserve on from My notes")
T.check(#notes_live == 3,
    "Merge row appears with preserve on: " .. #notes_live)
T.check(notes_live[3].text == "Bring in edits made in Obsidian",
    "the Merge row itself")

-- flip Upload off and reopen the group: there is no cloud copy to bring
-- back without it, so the row leaves
cloud[1].callback()
T.check(store.tomedown.upload == false, "upload toggled off")
notes_live = settings[3].sub_item_table_func()
T.check(#notes_live == 2,
    "Merge row leaves when upload goes off: " .. #notes_live)

-- flip the global switch off again with upload on: same rebuild
cloud[1].callback() -- upload back on
notes_live = settings[3].sub_item_table_func()
notes_menu = { item_table = notes_live }
notes_live[1].callback(notes_menu) -- preserve off
T.check(store.tomedown.preserve == false, "preserve off again")
T.check(#notes_live == 2,
    "Merge row leaves the open group when preserve goes off: "
        .. #notes_live)

-- put the shared store back the way the sections below expect it: a
-- server, upload not chosen yet, preserve off (nothing above leaks)
uploadSetup()
store.tomedown.upload = nil
store.tomedown.preserve = nil
end

-- the rows that used to sit in the Style and Behaviour submenus, kept
-- under the names the sections below toggle: auto-export in Files and
-- the global switch in My notes
local behaviour = { [1] = files[5], [2] = notes[1] }
T.check(updates[1].text_func() == "Check for updates (v"
        .. Update.getInstalledVersion() .. ")",
    "check row carries the installed version: " .. updates[1].text_func())
T.check(updates[2].text == "View changelog", "changelog entry")
T.check(updates[2].separator == true, "separator after the changelog entry")
T.check(updates[3].text == "Check for updates in background", "background entry")
T.check(updates[4].text == "\xEF\x84\xA6  Beta versions",
    "beta versions entry with icon")
local developer = updates[4].sub_item_table_func()
T.check(#developer == 3, "beta check hidden by default: " .. #developer)
T.check(developer[1].text == "Receive beta versions", "beta versions entry")
T.check(developer[1].checked_func() == false, "beta versions off by default")
T.check(developer[1].separator == true, "separator under the beta toggle")
T.check(developer[2].text == "\xEE\xB6\x8F  Go back to the stable version",
    "reset entry with the bomb icon")
local installed_version = Update.getInstalledVersion()
T.check(developer[3].text_func() == "Installed: v" .. installed_version
        .. (installed_version:find("-", 1, true) and " (Beta)" or " (Release)"),
    "installed row: " .. developer[3].text_func())
T.check(developer[3].enabled == false, "installed row is a plain label")

-- ticking Receive beta versions reveals the check in the open submenu at
-- once (the callback receives the TouchMenu, whose item_table is this
-- very table; it is rebuilt in place and redrawn by KOReader)
local fake_menu = { item_table = developer }
developer[1].callback(fake_menu)
T.check(store.tomedown.beta_releases == true, "beta versions toggled on")
T.check(#developer == 4, "beta check shown after ticking: " .. #developer)
T.check(developer[2].text == "Check for beta updates", "beta check entry")
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
for _, group in ipairs({ sub, cloud, files, notes, highlights,
        updates, developer }) do
    for i, row in ipairs(group) do
        if row.checked_func then
            T.check(row.keep_menu_open == true,
                "checkable settings row " .. i .. " keeps the menu open")
        end
    end
end
-- the About row opens the Bookshelf-style popup
local shown_before = #UIManager.shown
sub[9].callback()
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
T.check(#Button.all >= 2
        and Button.all[#Button.all - 1].text
            == "codeberg.org/imanubdesigner/tomedown.koplugin",
    "about shows the Codeberg URL first")
T.check(type(Button.last.callback) == "function"
        and type(Button.all[#Button.all - 1].callback) == "function",
    "both repository URLs are tappable")
-- the logo ships with the plugin and keeps its own ratio (PNG header)
T.check(ImageWidget.last ~= nil
        and (ImageWidget.last.file or ""):find("assets/logo.png", 1, true) ~= nil,
    "about shows the logo: " .. tostring(ImageWidget.last and ImageWidget.last.file))
T.check(ImageWidget.last ~= nil and (ImageWidget.last.height or 0) > 0
        and (ImageWidget.last.height or 0) < ImageWidget.last.width,
    "logo box follows the file ratio: "
        .. tostring(ImageWidget.last and ImageWidget.last.width)
        .. "x" .. tostring(ImageWidget.last and ImageWidget.last.height))
T.check(ImageWidget.last ~= nil
        and math.abs(ImageWidget.last.height
            - ImageWidget.last.width * 250 / 1045) <= 1,
    "logo box reads the PNG size: "
        .. tostring(ImageWidget.last and ImageWidget.last.width)
        .. "x" .. tostring(ImageWidget.last and ImageWidget.last.height))
T.check(ImageWidget.last ~= nil and ImageWidget.last.is_icon == true,
    "logo follows the UI in night mode")
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
local flushes_before_choice = flushes
PathChooser.last.onConfirm(DATA .. "/out-customi/")
T.check(plugin:getLocalDir() == DATA .. "/out-customi", "local folder changed")
T.check(flushes == flushes_before_choice + 1, "the folder choice is written to disk at once")
plugin:editLocalDir(nil)
T.check(plugin:getLocalDir() == DATA .. "/out-customi", "reopen without choosing keeps the value")
T.check(flushes == flushes_before_choice + 1, "closing the picker without choosing flushes nothing")
PathChooser.last.onConfirm("/")
T.check(plugin:getLocalDir() == "/", "root folder kept as-is")
T.check(flushes == flushes_before_choice + 2, "every confirmed choice flushes once")
-- a KOReader exposing no flush() must not break the choice itself
local saved_flush = G_reader_settings.flush
G_reader_settings.flush = nil
PathChooser.last.onConfirm(DATA .. "/out-nofush")
T.check(plugin:getLocalDir() == DATA .. "/out-nofush",
    "the folder is stored even without flush()")
T.check(flushes == flushes_before_choice + 2, "nothing to flush when flush() is absent")
G_reader_settings.flush = saved_flush
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
    T.check(not T.contains(onlyBmMd, "# **0 highlight"), "no zero count line in the body")
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

-- ------------------------------------------------- 9. Upload everything

uploadSetup()
store.tomedown.upload = false
cleanDir()
plugin:runExport({ FILE }, {})
T.check(#uploads == 0, "first phase: export only")
T.check(T.fileExists(MD_PATH) and T.fileExists(INDEX_PATH), "local files present")

-- a leftover cover rides along with "Upload everything"
os.execute('mkdir -p "' .. DIR .. '/covers" && printf x > "' .. DIR .. '/covers/copertina.jpg"')

resetUpload()
store.tomedown.upload = true
plugin:reuploadAll(nil)
UIManager:runPending()
T.check(#uploads == 3, "md files plus the leftover cover re-uploaded: " .. #uploads)
T.check(uploads[1].path == INDEX_PATH, "ordered: index first")
T.check(uploads[2].path == MD_PATH, "ordered: book md second")
T.check(uploads[3].path == DIR .. "/covers/copertina.jpg", "ordered: cover last")
T.check(uploads[1].url == "/Bookshelf/Kindle"
        and uploads[3].url == "/Bookshelf/Kindle/covers",
    "reupload keeps root files and covers apart: "
        .. tostring(uploads[3] and uploads[3].url))
T.check(#created_folders == 1 and created_folders[1].name == "covers",
    "reupload creates the remote covers folder too")
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
behaviour[1].callback()
T.check(behaviour[1].checked_func() == true, "auto-export toggled on")
uploadSetup()
behaviour[1].callback() -- uploadSetup wiped the setting
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
behaviour[1].callback() -- uploadSetup wiped the auto-export setting too
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
behaviour[1].callback()
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
behaviour[1].callback()
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
local Cover = require("tomedown_cover")
local Device = require("device")
local CanvasContext = require("document/canvascontext")
local saved_screen_flag = Device.hasColorScreen

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
highlights[1].callback()
T.check(store.tomedown.callout == true, "callout toggled on")
T.check(store.tomedown.exports[FILE].hash == nil,
    "the callout toggle invalidates the stored hash too")
highlights[1].callback()

-- the same for the two rows the Highlights group took over: neither
-- special_marker nor block_ids is part of hashBook, so choosing one has
-- to wipe the stored hashes or the book would never be rewritten
plugin:runExport({ FILE }, {})
T.check(store.tomedown.exports[FILE].hash ~= nil, "hash back before the next flip")
highlights[3].callback()
T.check(store.tomedown.block_ids == true, "block ids toggled on")
T.check(store.tomedown.exports[FILE].hash == nil,
    "the block ids toggle invalidates the stored hash too")
highlights[3].callback()
plugin:runExport({ FILE }, {})
T.check(store.tomedown.exports[FILE].hash ~= nil, "hash back once again")
marker_items[2].callback()
T.check(store.tomedown.special_marker == "bold",
    "the bold marker sticks")
T.check(store.tomedown.exports[FILE].hash == nil,
    "the special marker choice invalidates the stored hash too")
marker_items[1].callback()
T.check(store.tomedown.special_marker == "callout",
    "back to the default callout marker")
T.check(highlights[2].text_func() == "How special highlights look: Callout",
    "the row label follows the choice: " .. highlights[2].text_func())

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
T.check(T.contains(md_content or "", '<p align="center"><img src="' .. COVER_REL .. '"'),
    "the body embeds the cover centered")
local index_content = T.readFile(INDEX_PATH)
T.check(T.contains(index_content or "", COVER_REL), "the index row shows the cover")
T.check(T.contains(index_content or "", "width:120px;height:160px"),
    "the index cover is sized 120x160")
T.check((index_content or ""):match(
    "%*%*%d+ books?%*%* · %*%*%d+ highlights?%*%*") ~= nil,
    "the exported index carries the stats line")

-- extraction always forces colour rendering on, and puts the flags
-- back right after the call
T.check(BookInfo.cover_seen and BookInfo.cover_seen.color_screen == true,
    "colour forced on the screen flag while extracting: "
        .. tostring(BookInfo.cover_seen and BookInfo.cover_seen.color_screen))
T.check(BookInfo.cover_seen and BookInfo.cover_seen.canvas_color == true,
    "colour forced on the canvas flag while extracting: "
        .. tostring(BookInfo.cover_seen and BookInfo.cover_seen.canvas_color))
T.check(Device.hasColorScreen == saved_screen_flag,
    "the screen flag is restored once the cover is written")
T.check(CanvasContext.is_color_rendering_enabled == false,
    "the canvas flag is restored once the cover is written")

-- a failed extraction restores the flags too
BookInfo.cover_bb = nil
T.check(Cover.extract(nil, FILE, DIR .. "/covers/no-cover-here.jpg") == false,
    "extraction fails when the book has no cover image")
T.check(Device.hasColorScreen == saved_screen_flag,
    "the screen flag is restored after a failed extraction")
T.check(CanvasContext.is_color_rendering_enabled == false,
    "the canvas flag is restored after a failed extraction")
BookInfo.cover_bb = fakeBB(1600, 2400)

-- upload succeeds: the vault copy is the master one, the cover is
-- dropped from the device while the md files stay local
resetUpload()
cleanDir()
plugin:runExport({ FILE }, {})
UIManager:runPending()
T.check(#uploads == 3, "book, index and cover uploaded: " .. #uploads)
local cover_up, root_url = nil, true
for __, u in ipairs(uploads) do
    if u.path == COVER_PATH then
        cover_up = u
    elseif u.url ~= "/Bookshelf/Kindle" then
        root_url = false
    end
end
T.check(cover_up and cover_up.url == "/Bookshelf/Kindle/covers",
    "the cover joins the remote covers folder: "
        .. tostring(cover_up and cover_up.url))
T.check(root_url, "md and index stay in the remote root")
T.check(#created_folders == 1 and created_folders[1].url == "/Bookshelf/Kindle"
        and created_folders[1].name == "covers",
    "the remote covers folder is created once: " .. #created_folders)
T.check(not T.fileExists(COVER_PATH), "the uploaded cover is removed")
T.check(T.fileExists(MD_PATH), "the md files stay local")
T.check(next(store.tomedown.pending_uploads or {}) == nil, "nothing pending")

-- a server that refuses the folder creation does not block the upload
local realCreateFolder = provider.createFolder
provider.createFolder = function() error("MKCOL refused") end
resetUpload()
cleanDir()
plugin:runExport({ FILE }, {})
UIManager:runPending()
T.check(#uploads == 3, "upload proceeds when createFolder throws: " .. #uploads)
provider.createFolder = realCreateFolder

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

-- ------------------------------- 15. preserve manual edits (v1.0)

-- The book file names are needed again by the sections under this
-- block, while everything the block declares should not outlive it:
-- one script, one function, and Lua caps those at 200 variables,
-- which Lua 5.4 (what CI runs) enforces.
local MD_NAME, INDEX_NAME = BASE .. ".md", "00 - Index.md"
do
    store.tomedown.upload = false
    -- with preserve off (the default, and every export so far) the file
    -- on disk is plain markdown: no heading, no marker, nothing the next
    -- run could not replace wholesale
    T.check(not T.contains(special_md, "## My notes...")
            and not T.contains(special_md, "tomedown:begin"),
        "preserve off: no heading and no marker in the plain export")
    T.check(not T.contains(special_md, "Write your thoughts"),
        "preserve off: no invitation either")
    -- preserve is opt-in since 1.0: switch it on the way a reader would
    behaviour[2].callback()
    T.check(behaviour[2].checked_func() == true, "preserve switched on for this section")
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    local clean_md = T.readFile(MD_PATH)
    T.check(clean_md ~= nil and T.contains(clean_md, "<!-- tomedown:begin body"),
        "baseline export with the region markers before the edit: "
            .. tostring(clean_md ~= nil))
    T.check(clean_md ~= nil
            and T.contains(clean_md, "## My notes... <!-- tomedown:notes -->"),
        "baseline export opens the zone with the default heading")
    T.check(clean_md ~= nil
            and clean_md:find("## My notes... <!-- tomedown:notes -->\n\n\n"
                .. "<!-- tomedown:begin body", 1, true) ~= nil,
        "the zone opens with the heading and two blank lines of room")
    T.check(clean_md ~= nil
            and not T.contains(clean_md,
                "Write your thoughts, your emotions, your questions."),
        "preserve on seeds the room, never the invitation")

    -- the reader writes a line inside the generated body region
    local user_line = "Riga scritta a mano in Obsidian.\n"
    local edited_md = (clean_md or ""):gsub(
        "(<!%-%- tomedown:begin body[^\n]*%-%->\n)", "%1" .. user_line)
    local edit_file = io.open(MD_PATH, "wb")
    edit_file:write(edited_md)
    edit_file:close()

    -- a new annotation changes the render: the block is rebuilt and the
    -- previous file is kept whole, as .bak
    BookList.registry[FILE].annotations = modernAnnotations()
    table.insert(BookList.registry[FILE].annotations, {
        drawer = "underline", text = "Aggiunta in seguito.", pageno = 12,
        datetime = "2026-09-04 10:00:00",
    })
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    local rebuilt_md = T.readFile(MD_PATH)
    T.check(rebuilt_md ~= nil and not T.contains(rebuilt_md, user_line),
        "the rebuilt block drops the line written inside it")
    T.check(rebuilt_md ~= nil and T.contains(rebuilt_md, "Aggiunta in seguito."),
        "the rebuilt block takes the new annotation")
    T.check(rebuilt_md ~= nil
            and T.contains(rebuilt_md, "## My notes... <!-- tomedown:notes -->"),
        "the rebuild keeps the heading")
    T.check(T.contains(Notification.last_text or "", "1 files backed up (.bak)"),
        "the toast reports the backup: " .. tostring(Notification.last_text))
    local bak_md = T.readFile(MD_PATH .. ".bak.1")
    T.check(bak_md ~= nil and T.contains(bak_md, user_line),
        "the previous file is kept as the safety copy (.bak.1) with the hand-written line")
    T.check(not T.fileExists(MD_PATH .. ".bak"),
        "and .bak stays free for the parked zone: nothing was parked here")
    local kept_record = store.tomedown.exports[FILE]
    T.check(kept_record and kept_record.regions and kept_record.regions.body,
        "fingerprints stored for the next export")

    -- a clean export of the same file needs no second backup
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    T.check(not T.contains(Notification.last_text or "", ".bak"),
        "a clean file is not backed up again: " .. tostring(Notification.last_text))

    -- text in the write zone (above the marker) survives while preserving
    local zone_line = "Appunto nella zona note.\n"
    local zoned_md = (T.readFile(MD_PATH) or ""):gsub(
        "(<!%-%- tomedown:begin body)", zone_line .. "%1")
    local zone_file = io.open(MD_PATH, "wb")
    zone_file:write(zoned_md)
    zone_file:close()
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    T.check(T.readFile(MD_PATH) ~= nil
            and T.contains(T.readFile(MD_PATH), zone_line),
        "the zone above the marker survives the export")

    -- preservation off: the next export regenerates everything
    behaviour[2].callback()
    T.check(behaviour[2].checked_func() == false, "preservation toggled off")
    T.check(store.tomedown.exports[FILE].hash == nil,
        "switching modes invalidates the hashes")
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    local regen_md = T.readFile(MD_PATH)
    T.check(regen_md ~= nil and not T.contains(regen_md, zone_line),
        "overwrite mode drops the write zone too")
    behaviour[2].callback()
    T.check(behaviour[2].checked_func() == true, "preservation back on for the next runs")

    -- the status panel reports the backups of the last run
    store.tomedown.last_export = {
        at = os.time(), exported = 2, skipped = 1, errors = 0, backups = 3,
    }
    local status = table.concat(plugin:statusLines(), "\n")
    T.check(T.contains(status, "3 files backed up (.bak)"),
        "status shows the backups: " .. tostring(status))

    BookList.registry[FILE].annotations = modernAnnotations()

    -- --------------- 15b. preserve for one book (v1.1)
    -- The global switch stays the default, but one book may keep its own
    -- choice: tapping the row in the book menu stores it for that book
    -- alone, and it outlives any later flip of the global switch. The
    -- index follows its own switch (v1.1): no book turns it on behind
    -- the reader's back any more.
    do
    ui.document = { file = FILE }
    behaviour[2].callback() -- global preserve off, the tomedown 0.8 way
    T.check(store.tomedown.preserve == false, "15b: the global switch is off")
    sub = menu_items.tomedown.sub_item_table_func()
    local current_book = sub[5].sub_item_table_func()
    current_book[1].callback() -- the open book asks for its own zone
    T.check(store.tomedown.preserve_books
            and store.tomedown.preserve_books[FILE] == true,
        "15b: the choice is stored for this book")
    T.check(current_book[1].checked_func() == true,
        "15b: the row shows the book's own choice")
    T.check(store.tomedown.preserve == false,
        "15b: the global default is untouched")
    -- the Current book submenu is built on open: a book that keeps a
    -- zone gets its own heading row, right under the switch that keeps
    -- it, and the copies left by the sections above sit under that
    current_book = sub[5].sub_item_table_func()
    T.check(#current_book == 3,
        "15b: the heading and the copies join the submenu: "
            .. #current_book)
    T.check(current_book[2].text_func()
            == "Notes heading: My notes...",
        "15b: the heading row names this book's zone: "
            .. current_book[2].text_func())
    T.check(current_book[3].text == "\xEF\x83\x87  Backup copies…",
        "15b: the copies row follows the heading")
    plugin:runExport({ FILE, FILE2 }, {})
    UIManager:runPending()
    local per_book_md = T.readFile(MD_PATH)
    T.check(per_book_md ~= nil
            and T.contains(per_book_md, "## My notes... <!-- tomedown:notes -->"),
        "15b: with the global off the book exports its own zone")
    T.check(per_book_md ~= nil
            and T.contains(per_book_md, "<!-- tomedown:begin body"),
        "15b: and the markers with it")
    local other_path = DIR .. "/"
        .. (store.tomedown.exports[FILE2] or {}).base .. ".md"
    local other_md = T.readFile(other_path)
    T.check(other_md ~= nil
            and not T.contains(other_md, "tomedown:begin"),
        "15b: the other book never chose anything and stays plain")
    -- the export above brought its file back into the folder, and the
    -- sections from 19 on count the files of the upload: leave the
    -- folder the way this block found it
    os.remove(other_path)
    -- the index follows its own switch, not the books: with the global
    -- off and no choice of its own it exports plain, even while the
    -- book above keeps its zone
    local per_book_index = T.readFile(INDEX_PATH)
    T.check(per_book_index ~= nil
            and not T.contains(per_book_index, "tomedown:begin"),
        "15b: the index no longer rides along with the books")

    -- the global switch comes back on: while it is on it alone is in
    -- charge of every file, so the keep row goes off with the reason on
    -- the right and the heading leaves (the choice this book stored
    -- stays where it is, and comes back when the switch goes off again)
    behaviour[2].callback()
    T.check(store.tomedown.preserve == true, "15b: the global switch is on")
    current_book = sub[5].sub_item_table_func()
    T.check(current_book[1].enabled_func() == false,
        "15b: the keep row is off while the global switch covers every book")
    T.check(current_book[1].checked_func() == false,
        "15b: and it shows no book's choice")
    T.check(current_book[1].mandatory_func() == "On for all books",
        "15b: the reason sits on the right")
    T.check(current_book[2].text == "\xEF\x83\x87  Backup copies…",
        "15b: the heading leaves with the global switch, the copies stay")
    behaviour[2].callback()
    T.check(store.tomedown.preserve == false, "15b: and off again")
    current_book = sub[5].sub_item_table_func()
    T.check(#current_book == 3,
        "15b: the heading is back with the switch off: " .. #current_book)
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    T.check(T.readFile(MD_PATH) ~= nil
            and T.contains(T.readFile(MD_PATH), "## My notes..."),
        "15b: the book's own choice survives the flips of the global")

    -- --------------- 15c. the heading of one book (v1.1)
    -- A book that keeps a zone names it itself: the row under the
    -- switch opens the dialog, and the title is stored for that book
    -- alone. The index, when it has a zone, keeps the global heading.
    current_book = sub[5].sub_item_table_func()
    current_book[2].callback()
    T.check(InputDialog.last ~= nil
            and InputDialog.last.title == "Notes heading",
        "15c: the heading dialog opened")
    InputDialog.last.input_text = "  The Witch theory  "
    InputDialog.last:simulateSave()
    T.check(store.tomedown.notes_titles
            and store.tomedown.notes_titles[FILE] == "The Witch theory",
        "15c: the title is stored for this book, trimmed")
    T.check(store.tomedown.notes_title == nil,
        "15c: the global heading is left alone")
    T.check(store.tomedown.exports[FILE].hash == nil,
        "15c: the book's hash goes: its file has to be rewritten")
    T.check(current_book[2].text_func()
            == "Notes heading: The Witch theory",
        "15c: the row shows the new name: " .. current_book[2].text_func())
    -- a book that never named its zone, saved back with the global title
    -- still in the field, keeps following the global one: a copy of it
    -- would freeze the book on today's heading, and a later rename in
    -- Settings would leave it behind for good
    ui.document = { file = FILE2 }
    sub = menu_items.tomedown.sub_item_table_func()
    current_book = sub[5].sub_item_table_func()
    current_book[1].callback({ item_table = current_book })
    current_book = sub[5].sub_item_table_func()
    current_book[2].callback()
    T.check(InputDialog.last ~= nil
            and InputDialog.last.input_text == "My notes...",
        "15c: the field starts on the heading the book exports today: "
            .. tostring(InputDialog.last and InputDialog.last.input_text))
    InputDialog.last:simulateSave()
    T.check(store.tomedown.notes_titles == nil
            or store.tomedown.notes_titles[FILE2] == nil,
        "15c: saving it back untouched stores no choice of its own")
    ui.document = { file = FILE }
    sub = menu_items.tomedown.sub_item_table_func()
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    per_book_md = T.readFile(MD_PATH)
    T.check(per_book_md ~= nil
            and T.contains(per_book_md,
                "## The Witch theory <!-- tomedown:notes -->"),
        "15c: the book's zone carries its own heading")
    T.check(per_book_md ~= nil
            and not T.contains(per_book_md, "## My notes..."),
        "15c: and not the global one")
    -- another book keeps the global heading: the title belongs to the
    -- book that asked for it, and to no other file. FILE2 keeps a zone
    -- already (the toggle above that brought its heading row up)
    ui.document = { file = FILE2 }
    plugin:runExport({ FILE2 }, {})
    UIManager:runPending()
    other_path = DIR .. "/"
        .. (store.tomedown.exports[FILE2] or {}).base .. ".md"
    other_md = T.readFile(other_path)
    T.check(other_md ~= nil
            and T.contains(other_md, "## My notes... <!-- tomedown:notes -->"),
        "15c: the other book still names its zone the global way")
    os.remove(other_path)
    ui.document = { file = FILE }

    -- --------------- 15d. the index has its own switch (v1.1)
    -- It follows the global switch until the reader flips its own, and
    -- once switched off it stays off: no book turns it back on. When it
    -- goes from zoned to plain the file is kept whole as .bak, because
    -- the notes in it do not survive the rewrite.
    local index_row
    for __, row in ipairs(plugin:genSettingsMenu()[3].sub_item_table_func()) do
        if row.text == "Keep my notes: index" then
            index_row = row
            break
        end
    end
    T.check(index_row ~= nil, "15d: the index keep row exists")
    T.check(index_row.checked_func() == false,
        "15d: it follows the global switch, which is off")
    index_row.callback() -- the index asks for its own zone
    T.check(store.tomedown.preserve_index == true,
        "15d: the choice is stored for the index")
    T.check(index_row.checked_func() == true,
        "15d: the row shows the index's own choice")
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    per_book_index = T.readFile(INDEX_PATH)
    T.check(per_book_index ~= nil
            and T.contains(per_book_index, "<!-- tomedown:begin index"),
        "15d: the index keeps its zone with the global switch off")
    T.check(per_book_index ~= nil
            and T.contains(per_book_index,
                "## My notes... <!-- tomedown:notes -->"),
        "15d: and names it with the global heading, not the book's")
    -- The index, while it keeps a zone, names it itself: its own row
    -- sits right under its switch and stores the title for the index
    -- alone, and every export hash goes with it (the index is only
    -- rebuilt along with the books, so the new heading needs every
    -- file to be written again).
    live = plugin:genSettingsMenu()[3].sub_item_table_func()
    T.check(#live == 3
            and live[3].text_func() == "Index notes heading: My notes...",
        "15d: the index heading row sits under its switch: "
            .. tostring(live[3] and live[3].text_func
                and live[3].text_func()))
    live[3].callback()
    T.check(InputDialog.last ~= nil
            and InputDialog.last.title == "Notes heading",
        "15d: the index heading dialog opened")
    InputDialog.last.input_text = "  Appunti dell'indice  "
    InputDialog.last:simulateSave()
    T.check(store.tomedown.notes_titles
            and store.tomedown.notes_titles[INDEX_NAME]
                == "Appunti dell'indice",
        "15d: the title is stored for the index, trimmed")
    T.check(store.tomedown.notes_title == nil,
        "15d: the global heading is left alone")
    T.check(store.tomedown.exports[FILE] == nil
            or store.tomedown.exports[FILE].hash == nil,
        "15d: every export hash goes: the index rides along with the books")
    live = plugin:genSettingsMenu()[3].sub_item_table_func()
    T.check(live[#live].text_func() == "Index notes heading: Appunti dell'indice",
        "15d: the row shows the new name: "
            .. tostring(live[#live].text_func and live[#live].text_func()))
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    per_book_index = T.readFile(INDEX_PATH)
    T.check(per_book_index ~= nil
            and T.contains(per_book_index,
                "## Appunti dell'indice <!-- tomedown:notes -->"),
        "15d: the index carries its own heading")
    T.check(per_book_index ~= nil
            and not T.contains(per_book_index, "## My notes..."),
        "15d: and not the global one")
    -- a note written in the index survives the next export of a book
    index_file = io.open(INDEX_PATH, "wb")
    if index_file then
        index_file:write(per_book_index .. "\nA note of mine\n")
        index_file:close()
    end
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    T.check(T.contains(T.readFile(INDEX_PATH) or "", "A note of mine"),
        "15d: the note in the index survives an export")
    -- switched off again: the file goes back to plain, and the version
    -- that held the notes is kept whole as .bak
    index_row.callback()
    T.check(store.tomedown.preserve_index == false,
        "15d: an explicit off is stored for the index")
    -- with the index written plain there is no zone left to name: the
    -- row under its switch goes away with it
    live = plugin:genSettingsMenu()[3].sub_item_table_func()
    T.check(#live == 2 and live[2].text == "Keep my notes: index",
        "15d: the heading row leaves when the index is plain: " .. #live)
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    per_book_index = T.readFile(INDEX_PATH)
    T.check(per_book_index ~= nil
            and not T.contains(per_book_index, "tomedown:begin"),
        "15d: the index comes out plain again")
    other_md = T.readFile(INDEX_PATH .. ".bak")
    T.check(other_md ~= nil
            and T.contains(other_md, "A note of mine"),
        "15d: the zoned index is kept whole as .bak before it is rewritten")
    os.remove(INDEX_PATH .. ".bak")
    -- the book's own choice is off too, and everything goes the way the
    -- sections below expect it. Turning preserve off replaces a file
    -- the reader may have written in, so it is asked first (v1.1)
    UIManager:runPending() -- anything left queued by the sections above
    -- whatever earlier exports left behind goes: what follows has to
    -- find the copy the confirmation itself writes
    os.remove(MD_PATH .. ".bak")
    os.remove(MD_PATH .. ".bak.1")
    ConfirmBox.last = nil
    current_book = sub[5].sub_item_table_func()
    current_book[1].callback()
    UIManager:runPending()
    T.check(ConfirmBox.last ~= nil,
        "15b: turning preserve off asks for confirmation first")
    T.check(ConfirmBox.last ~= nil
            and T.contains(ConfirmBox.last.text or "", "Blackwater.epub"),
        "15b: the box names the book: "
            .. tostring(ConfirmBox.last and ConfirmBox.last.text))
    T.check(ConfirmBox.last ~= nil and ConfirmBox.last.ok_text == "Turn off",
        "15b: the ok button says what it will do")
    T.check(ConfirmBox.last ~= nil
            and ConfirmBox.last.cancel_text == "Keep it on",
        "15b: and the cancel button offers the other way")
    T.check(store.tomedown.preserve_books[FILE] == true,
        "15b: nothing changes until the reader confirms")
    -- cancelling leaves the book alone, and its file stays zoned
    ConfirmBox.last.cancel_callback()
    T.check(store.tomedown.preserve_books[FILE] == true,
        "15b: cancelling keeps the book preserved")
    T.check(T.readFile(MD_PATH) ~= nil
            and T.contains(T.readFile(MD_PATH), "tomedown:begin"),
        "15b: and leaves the file zoned")
    -- confirming stores the off, rewrites the file plain there and then,
    -- and keeps what it held as .bak
    ConfirmBox.last = nil
    current_book = sub[5].sub_item_table_func()
    current_book[1].callback()
    UIManager:runPending()
    T.check(ConfirmBox.last ~= nil, "15b: the box comes back")
    ConfirmBox.last.ok_callback()
    UIManager:runPending()
    T.check(store.tomedown.preserve_books[FILE] == false,
        "15b: an explicit off is stored for the book")
    per_book_md = T.readFile(MD_PATH)
    T.check(per_book_md ~= nil
            and not T.contains(per_book_md, "## The Witch theory")
            and not T.contains(per_book_md, "tomedown:begin"),
        "15b: the file comes out plain again, right away")
    other_md = T.readFile(MD_PATH .. ".bak")
    T.check(other_md ~= nil
            and T.contains(other_md, "## The Witch theory")
            and T.contains(other_md, "tomedown:begin"),
        "15b: the zoned file is kept whole as .bak: "
            .. tostring(other_md ~= nil))
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    per_book_md = T.readFile(MD_PATH)
    T.check(per_book_md ~= nil
            and not T.contains(per_book_md, "tomedown:begin"),
        "15b: the plain file survives the next export too")
    T.check(T.readFile(INDEX_PATH) ~= nil
            and not T.contains(T.readFile(INDEX_PATH), "tomedown:begin"),
        "15b: the index stays plain with every switch off")

    -- With the global switch on it alone decides, whatever a file
    -- stored: this book and the index both asked to go plain, and both
    -- get a zone back, named with the global heading while the book's
    -- own heading stays stored, dormant. Switching it off again sends
    -- every file back to the choice it made.
    behaviour[2].callback()
    T.check(store.tomedown.preserve == true,
        "15b: the global switch is on and decides for every file")
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    -- The file on disk is the plain export this very plugin wrote a
    -- moment ago: there is nothing in it worth copying, and above all
    -- the copy the confirmation wrote must stay where it is, since it
    -- is the one holding the reader's notes (the whole reason the box
    -- promises they will not be lost)
    other_md = T.readFile(MD_PATH .. ".bak")
    T.check(other_md ~= nil
            and T.contains(other_md, "## The Witch theory")
            and T.contains(other_md, "tomedown:begin"),
        "15b: our own plain file takes no copy of itself: "
            .. tostring(other_md ~= nil))
    T.check(not T.fileExists(MD_PATH .. ".bak.1"),
        "15b: and no second slot is opened for it")
    per_book_md = T.readFile(MD_PATH)
    T.check(per_book_md ~= nil
            and T.contains(per_book_md,
                "## My notes... <!-- tomedown:notes -->")
            and T.contains(per_book_md, "<!-- tomedown:begin body"),
        "15b: the book keeps a zone with the global switch on")
    T.check(per_book_md ~= nil
            and not T.contains(per_book_md, "## The Witch theory"),
        "15b: it is named with the global heading, not the book's own")
    T.check(store.tomedown.notes_titles
            and store.tomedown.notes_titles[FILE] == "The Witch theory",
        "15b: the book's own heading is still stored, dormant")
    T.check(T.readFile(INDEX_PATH) ~= nil
            and T.contains(T.readFile(INDEX_PATH), "tomedown:begin"),
        "15b: the index keeps its zone too, stored off as it is")

    -- A second backup that is worth taking rotates instead of
    -- replacing: the reader writes a line in the zone, the file is no
    -- longer our own output, so it is copied and the copy from the
    -- confirmation moves one slot back rather than into the bin. The
    -- locals of the zone test above are reused: the file has hit the
    -- 200 local limit of the interpreter that runs the tests
    zone_line = "Riga scritta a mano nella zona.\n"
    zoned_md = (T.readFile(MD_PATH) or ""):gsub(
        "(<!%-%- tomedown:begin body[^\n]*%-%->\n)", "%1" .. zone_line)
    zone_file = io.open(MD_PATH, "wb")
    zone_file:write(zoned_md)
    zone_file:close()
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    -- a block edited inside its comments is a different kind of copy:
    -- it goes to the safety slot and never takes the parked file's place
    other_md = T.readFile(MD_PATH .. ".bak")
    T.check(other_md ~= nil
            and T.contains(other_md, "## The Witch theory")
            and T.contains(other_md, "tomedown:begin"),
        "15b: the parked file survives a later backup: "
            .. tostring(other_md ~= nil))
    other_md = T.readFile(MD_PATH .. ".bak.1")
    T.check(other_md ~= nil
            and T.contains(other_md, zone_line)
            and not T.contains(other_md, "## The Witch theory"),
        "15b: and the copy of the edited block takes the safety slot: "
            .. tostring(other_md ~= nil))

    -- a filesystem that refuses the rename must not stop the export: the
    -- copy is written in place instead, the parked file is not touched
    -- and no temporary file is left behind
    zone_line = "Terza riga a mano, con il rename rifiutato.\n"
    zoned_md = (T.readFile(MD_PATH) or ""):gsub(
        "(<!%-%- tomedown:begin body[^\n]*%-%->\n)", "%1" .. zone_line)
    zone_file = io.open(MD_PATH, "wb")
    zone_file:write(zoned_md)
    zone_file:close()
    other_md = T.readFile(MD_PATH .. ".bak")
    _G.__td_rename = os.rename
    os.rename = function() return nil, "refused" end
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    os.rename = _G.__td_rename
    _G.__td_rename = nil
    T.check(T.contains(T.readFile(MD_PATH .. ".bak.1") or "", zone_line),
        "15b: a refused rename falls back to writing the copy in place")
    T.check(other_md ~= nil and T.readFile(MD_PATH .. ".bak") == other_md,
        "15b: and the parked file is exactly as it was")
    T.check(not T.fileExists(MD_PATH .. ".bak.tmp")
            and not T.fileExists(MD_PATH .. ".bak.1.tmp"),
        "15b: and no temporary file is left behind")

    -- the reader's note sits in the zone, above the marker, the way the
    -- guide tells them to write: this is the line that has to come back
    -- when preserve returns, so it is written before it goes off
    zone_line = "Appunto nella zona, quello che deve tornare.\n"
    zoned_md = (T.readFile(MD_PATH) or ""):gsub(
        "(<!%-%- tomedown:begin body)", zone_line .. "%1")
    zone_file = io.open(MD_PATH, "wb")
    zone_file:write(zoned_md)
    zone_file:close()

    behaviour[2].callback()
    T.check(store.tomedown.preserve == false,
        "15b: off again, and every file back to what it chose")
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    T.check(T.readFile(MD_PATH) ~= nil
            and not T.contains(T.readFile(MD_PATH), "tomedown:begin"),
        "15b: the book goes plain again, its own off waiting")
    T.check(T.readFile(INDEX_PATH) ~= nil
            and not T.contains(T.readFile(INDEX_PATH), "tomedown:begin"),
        "15b: the index goes plain again too")

    -- Preserve back on, the case from the first test on the device: the
    -- file on disk is the plain export this plugin wrote itself and the
    -- copy beside it is zoned, so what the reader had in it comes back
    -- into the file instead of waiting in the .bak
    behaviour[2].callback()
    T.check(store.tomedown.preserve == true,
        "15b: preserve back on, ready to bring the copy back")
    -- nothing may be written by what follows: the copy it reads is the
    -- one already there, so no rotation can happen and no second slot
    -- may show up (the case he reported while testing)
    os.remove(MD_PATH .. ".bak.1")
    os.remove(INDEX_PATH .. ".bak.1")
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    per_book_md = T.readFile(MD_PATH)
    T.check(per_book_md ~= nil and T.contains(per_book_md, zone_line),
        "15b: the note from the .bak is back in the file: "
            .. tostring(per_book_md ~= nil))
    T.check(per_book_md ~= nil
            and T.contains(per_book_md, "tomedown:begin"),
        "15b: and the file is zoned again")
    T.check(per_book_md ~= nil
            and T.contains(per_book_md,
                "## My notes... <!-- tomedown:notes -->"),
        "15b: under the heading the global switch names")
    other_md = T.readFile(MD_PATH .. ".bak")
    T.check(other_md ~= nil and T.contains(other_md, zone_line),
        "15b: the backup it came from is left where it was: "
            .. tostring(other_md ~= nil))
    T.check(not T.fileExists(MD_PATH .. ".bak.1")
            and not T.fileExists(INDEX_PATH .. ".bak.1"),
        "15b: and the restore writes no copy of its own")
    T.check(T.readFile(INDEX_PATH) ~= nil
            and T.contains(T.readFile(INDEX_PATH), "tomedown:begin"),
        "15b: the index comes back from its own copy too")
    behaviour[2].callback()
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    T.check(T.readFile(MD_PATH) ~= nil
            and not T.contains(T.readFile(MD_PATH), "tomedown:begin"),
        "15b: off again, the way the sections below want it")

    -- the settings rows speak about the global switch only: a book's
    -- own choice lives in the book's own menu, so a preserved book
    -- brings no heading row while the global toggle is off
    current_book = sub[5].sub_item_table_func()
    current_book[1].callback() -- the book keeps its zone again
    live = plugin:genSettingsMenu()[3].sub_item_table_func()
    T.check(#live == 2,
        "15b: a preserved book brings no heading row: "
            .. #live)
    behaviour[2].callback() -- the global switch on: the row appears
    live = plugin:genSettingsMenu()[3].sub_item_table_func()
    T.check(#live == 2,
        "15b: the heading row appears with preserve on: "
            .. #live)
    T.check(live[2].text_func() == "Notes heading: My notes...",
        "15b: and it renames the heading of the zone")
    T.check(live[3] == nil,
        "15b: the index rows are hidden while the switch is on")
    behaviour[2].callback() -- and off again, the way the sections below want it

    -- His sequence from the device: the global switch goes off with no
    -- export in between, the book's own switch is on again (it was set
    -- at the start of this section), and one export follows. The book
    -- keeps its zone and takes no new copy at all: the copy that shows
    -- up belongs to 00 - Index.md, which follows the global switch and
    -- goes plain here, so its previous version rotates one slot back.
    -- There is no "copy of the global switch" for a book: the pair
    -- beside a book's .md is always that book's own.
    behaviour[2].callback() -- global on: every file preserved again
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    os.remove(MD_PATH .. ".bak.1")
    os.remove(INDEX_PATH .. ".bak.1")
    behaviour[2].callback() -- global off, still no export, as he did it
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    per_book_md = T.readFile(MD_PATH)
    T.check(per_book_md ~= nil
            and T.contains(per_book_md, "tomedown:begin"),
        "15b: the book keeps its zone while its own switch is on")
    T.check(per_book_md ~= nil and T.contains(per_book_md, zone_line),
        "15b: and its note comes back with it")
    T.check(not T.fileExists(MD_PATH .. ".bak.1"),
        "15b: and no new copy is taken for the book")
    T.check(T.readFile(INDEX_PATH) ~= nil
            and not T.contains(T.readFile(INDEX_PATH), "tomedown:begin"),
        "15b: the index goes plain with the global switch off")
    -- the index copy about to be taken is byte for byte the one already
    -- sitting in .bak: it takes no second slot (these twins used to
    -- fill .bak and .bak.1 with the same file, leaving no room for an
    -- older copy)
    T.check(T.readFile(INDEX_PATH .. ".bak") ~= nil
            and T.contains(T.readFile(INDEX_PATH .. ".bak"), "tomedown:begin"),
        "15b: the index's zoned copy stays in .bak")
    T.check(not T.fileExists(INDEX_PATH .. ".bak.1"),
        "15b: an identical copy takes no second slot")

    -- everything back the way the sections below expect it
    store.tomedown.preserve_books = nil
    store.tomedown.preserve_index = nil
    store.tomedown.notes_titles = nil
    store.tomedown.preserve = nil
    ui.document = { file = nil }
    end

    -- --------------- 16. the open book reads the reader's live data (v1.0)
    -- While a book is open KOReader keeps its props in memory and writes the
    -- .sdr only on close/suspend/periodic autosave: an export made in
    -- between used to read the stale flush, lose the series (the index row
    -- fell into "My books") and count highlights the flush never saw.

    store.tomedown.upload = false
    local rec16 = BookList.registry[FILE]
    local disk_props16, disk_annotations16 = rec16.doc_props, rec16.annotations

    -- the .sdr on disk: the last flush, without the series
    rec16.doc_props = { title = "Blackwater", authors = "Michael McDowell" }

    -- the book is open: KOReader has already read the metadata from the epub
    ui.document = { file = FILE }
    ui.doc_props = {
        title = "Blackwater",
        authors = "Michael McDowell",
        series = "Wayward Pines",
        series_index = 1,
    }
    -- and two highlights that never reached the disk
    local live16 = {}
    for __, a in ipairs(disk_annotations16) do
        live16[#live16 + 1] = a
    end
    live16[#live16 + 1] = {
        drawer = "underline", text = "Appena evidenziata.", pageno = 12,
        datetime = "2026-10-13 09:00:00",
    }
    live16[#live16 + 1] = {
        drawer = "underline", text = "L'altra appena evidenziata.", pageno = 13,
        datetime = "2026-10-13 09:01:00",
    }
    ui.annotation = { annotations = live16 }

    -- the book file without the live annotations: the series still has to
    -- come from the live props (it is missing on disk)
    plugin.book_cache = nil
    local stale_book16 = plugin:buildBook(FILE)
    T.check(stale_book16 ~= nil and stale_book16.series == "Wayward Pines",
        "buildBook: series from the live props of the open book: "
            .. tostring(stale_book16 and stale_book16.series))
    local disk_count16 = stale_book16 and stale_book16.count or 0

    plugin.book_cache = nil
    local live_book16 = plugin:buildBook(FILE, live16)
    T.check(live_book16 ~= nil and live_book16.count == disk_count16 + 2,
        "buildBook with the live annotations: "
            .. tostring(live_book16 and live_book16.count)
            .. " highlights, " .. (disk_count16 + 2) .. " expected")

    -- the index entry is built from the same live data as the book file
    local entries16 = plugin:buildIndexEntries(DIR, store.tomedown.exports)
    local entry16
    for __, e in ipairs(entries16) do
        if e.link == BASE then
            entry16 = e
        end
    end
    T.check(entry16 ~= nil, "the open book is in the index entries")
    T.check(entry16 ~= nil and entry16.series == "Wayward Pines",
        "index entry: series from the live props: "
            .. tostring(entry16 and entry16.series))
    T.check(entry16 ~= nil and entry16.count == disk_count16 + 2,
        "index entry counts the highlights still in memory: "
            .. tostring(entry16 and entry16.count)
            .. ", " .. (disk_count16 + 2) .. " expected")

    -- the full export puts the row in the series table, not in "My books"
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    local md16 = T.readFile(MD_PATH) or ""
    T.check(T.contains(md16, 'series: "Wayward Pines"'),
        "book file: series from the live props")
    local index16 = T.readFile(INDEX_PATH) or ""
    T.check(T.contains(index16, "Wayward Pines #1"),
        "index: the row lands in the series table")

    -- a failed index write is reported instead of passing silently (a file
    -- held open by another app: Obsidian on Windows, an editor anywhere)
    local util16 = require("util")
    local real_write16 = util16.writeToFile
    util16.writeToFile = function(data, filepath, ...)
        if filepath == INDEX_PATH then
            return nil, "Simulated failure"
        end
        return real_write16(data, filepath, ...)
    end
    plugin:runExport({ FILE }, {})
    util16.writeToFile = real_write16
    T.check(store.tomedown.last_export ~= nil
            and store.tomedown.last_export.errors == 1,
        "the failed index write is counted as an error: "
            .. tostring(store.tomedown.last_export
                and store.tomedown.last_export.errors))
    T.check(T.contains(InfoMessage.last_text or "", "Errors:")
            and T.contains(InfoMessage.last_text or "", INDEX_PATH:match("[^/]+$")
                .. ": Simulated failure"),
        "the error names the index file: "
            .. tostring(InfoMessage.last_text))

    -- back to the state the other tests expect
    rec16.doc_props = disk_props16
    rec16.annotations = disk_annotations16
    ui.document = nil
    ui.doc_props = nil
    ui.annotation = nil
    plugin.book_cache = nil

    -- ------------- 17. the cloud copy edited elsewhere (v1.0)
    -- The reader edits an exported file in Obsidian, synced back through
    -- the same cloud folder: the next export has to fold that text in,
    -- instead of overwriting the cloud copy with a merge made against the
    -- older file on the device.

    uploadSetup() -- fresh store: server set, upload on
    store.tomedown.preserve = true
    store.tomedown.cloud_merge = true
    store.tomedown.covers = false
    NetworkMgr.connected = true
    remote_files, download_fails, downloads = {}, {}, {}
    BookList.registry[FILE].annotations = modernAnnotations()

    -- first export: the file reaches the cloud and its hash is remembered
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    local md1 = T.readFile(MD_PATH)
    T.check(md1 ~= nil and #uploads > 0, "first export uploaded the book file")
    local stored1 = plugin:cloudBase(SERVER)
    T.check(stored1 ~= nil and stored1[MD_NAME] == md5(md1),
        "the uploaded content is remembered: "
            .. tostring(stored1 and stored1[MD_NAME]))

    -- a thought typed in Obsidian has reached the cloud copy
    remote_files[MD_NAME] = md1 .. "\nA thought typed in Obsidian.\n"
    downloads = {}
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    local md2 = T.readFile(MD_PATH) or ""
    local fetched_book, fetched_index = false, false
    for __, url in ipairs(downloads) do
        if url:sub(-#MD_NAME) == MD_NAME then fetched_book = true end
        if url:sub(-#INDEX_NAME) == INDEX_NAME then fetched_index = true end
    end
    T.check(fetched_book and fetched_index,
        "book and index copies are both fetched before the merge: "
            .. table.concat(downloads, ", "))
    T.check(T.contains(md2, "A thought typed in Obsidian."),
        "the thought from Obsidian survives the export")
    T.check(T.contains(md2, "series:"), "the fresh render is in the file too")
    T.check(plugin:cloudBase(SERVER)[MD_NAME] == md5(md2),
        "the new upload is remembered")

    -- the same story for the index: the edit exists only in the cloud
    -- (typed in Obsidian on the desktop), never on the device
    local index_cloud = (T.readFile(INDEX_PATH) or "")
        .. "\nUna riga scritta nell'indice.\n"
    T.check(index_cloud ~= "", "the cloud index really differs")
    remote_files[INDEX_NAME] = index_cloud
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    T.check(T.contains(T.readFile(INDEX_PATH) or "", "Una riga scritta nell'indice."),
        "an index edited only in the cloud survives the export")

    -- an untouched cloud copy adds nothing: the file on the device stays
    -- the base and the export comes out byte-identical
    local md3 = T.readFile(MD_PATH)
    remote_files[MD_NAME] = md3
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    T.check(T.readFile(MD_PATH) == md3, "untouched cloud copy: stable export")

    -- a failed fetch falls back to the file on the device, quietly
    download_fails[MD_NAME] = true
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    T.check(store.tomedown.last_export and store.tomedown.last_export.errors == 0,
        "a failed fetch is not an export error: "
            .. tostring(store.tomedown.last_export
                and store.tomedown.last_export.errors))
    T.check(T.contains(T.readFile(MD_PATH) or "", "A thought typed in Obsidian."),
        "the note is still there, from the file on the device")
    download_fails[MD_NAME] = nil

    -- the reader can switch the whole thing off
    store.tomedown.cloud_merge = false
    remote_files[MD_NAME] = (T.readFile(MD_PATH) or "")
        .. "\nUn pensiero soltanto sul cloud.\n"
    downloads = {}
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    T.check(#downloads == 0, "cloud_merge off: nothing is fetched: " .. #downloads)
    T.check(not T.contains(T.readFile(MD_PATH) or "", "Un pensiero soltanto sul cloud."),
        "cloud_merge off: the file on the device stays the only base")
    store.tomedown.cloud_merge = true
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    T.check(T.contains(T.readFile(MD_PATH) or "", "Un pensiero soltanto sul cloud."),
        "cloud_merge back on: the cloud text is folded in")

    -- the hashes follow the destination: another server or folder starts
    -- from a clean slate instead of trusting the old ones
    T.check(plugin:cloudBase({ name = "Koofr", type = "webdav",
            url = "/Bookshelf/Kindle" }) == plugin:cloudBase(SERVER),
        "the same destination keeps the hashes")
    T.check(plugin:cloudBase({ name = "Other", type = "webdav",
            url = "/Other/Folder" }) == nil, "another folder starts clean")

    -- ------------- 18. pending uploads folded at the flush (v1.0)
    -- The reader exports with no connection: the new highlights land in the
    -- local file, the copy in the cloud still holds whatever was typed in
    -- Obsidian. When the connection comes back the flush must not push the
    -- device copy over the cloud one blindly — it fetches it, and when it
    -- moved on from the last upload it folds it in first.

    uploadSetup()
    store.tomedown.preserve = true
    store.tomedown.cloud_merge = true
    store.tomedown.covers = false
    NetworkMgr.connected = true
    remote_files, download_fails, downloads = {}, {}, {}
    BookList.registry[FILE].annotations = modernAnnotations()

    -- an export that reached the cloud: the hash is remembered
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    local base_md = T.readFile(MD_PATH)
    T.check(base_md ~= nil and plugin:cloudBase(SERVER)[MD_NAME] == md5(base_md),
        "18: seed export uploaded and remembered")

    -- meanwhile a thought is typed in Obsidian and synced to the cloud copy
    remote_files[MD_NAME] = base_md .. "\nA thought from Obsidian, offline.\n"

    -- the reader adds a highlight and exports with the network down: the
    -- file is written locally and queued, the cloud copy is never fetched
    NetworkMgr.connected = false
    BookList.registry[FILE].annotations = modernAnnotationsWithExtra()
    downloads = {}
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    T.check(#downloads == 0, "18: offline export fetches nothing: " .. #downloads)
    T.check(store.tomedown.pending_uploads
            and store.tomedown.pending_uploads[MD_PATH] == true,
        "18: the offline export is queued as pending")

    -- connection back: the flush folds the cloud copy before pushing
    NetworkMgr.connected = true
    remote_files[MD_NAME] = base_md .. "\nA thought from Obsidian, offline.\n"
    plugin:flushPendingUploads()
    UIManager:runPending()
    local folded = T.readFile(MD_PATH) or ""
    T.check(T.contains(folded, "A thought from Obsidian, offline."),
        "18: the note typed offline in Obsidian survives the flush")
    T.check(next(store.tomedown.pending_uploads or {}) == nil,
        "18: flush clears pending after the fold")

    -- the cloud copy that could not be fetched is never overwritten: the
    -- file stays pending, so nothing is lost
    uploadSetup()
    store.tomedown.preserve = true
    store.tomedown.cloud_merge = true
    NetworkMgr.connected = true
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    local md_before = T.readFile(MD_PATH)
    remote_files[MD_NAME] = md_before .. "\nUn pensiero non ancora visto.\n"
    NetworkMgr.connected = false
    BookList.registry[FILE].annotations = modernAnnotationsWithExtra()
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    NetworkMgr.connected = true
    download_fails[MD_NAME] = true
    uploads = {}
    plugin:flushPendingUploads()
    UIManager:runPending()
    local pushed_book = false
    for __, u in ipairs(uploads) do
        if u.path and u.path:sub(-#MD_NAME) == MD_NAME then pushed_book = true end
    end
    T.check(not pushed_book,
        "18: a failed fetch never pushes the book ("
            .. #uploads .. " other uploads are fine)")
    T.check(store.tomedown.pending_uploads
            and store.tomedown.pending_uploads[MD_PATH] == true,
        "18: the file is held back as pending when the copy cannot be fetched")
    download_fails[MD_NAME] = nil
    plugin:flushPendingUploads()
    UIManager:runPending()
    T.check(T.contains(T.readFile(MD_PATH) or "", "Un pensiero non ancora visto."),
        "18: once the fetch works the note is folded in")

    -- a server that cannot download keeps the old behaviour: the local copy
    -- is pushed as it is (nothing to compare against)
    uploadSetup()
    store.tomedown.preserve = true
    store.tomedown.cloud_merge = true
    NetworkMgr.connected = true
    local dl = provider.downloadFile
    provider.downloadFile = nil
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    NetworkMgr.connected = false
    BookList.registry[FILE].annotations = modernAnnotationsWithExtra()
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    NetworkMgr.connected = true
    uploads = {}
    plugin:flushPendingUploads()
    UIManager:runPending()
    local pushed_book = false
    for __, u in ipairs(uploads) do
        if u.path and u.path:sub(-#MD_NAME) == MD_NAME then pushed_book = true end
    end
    T.check(pushed_book,
        "18: no download support still pushes the book as it is: "
            .. #uploads .. " uploads")
    provider.downloadFile = dl

    -- with the merge option off the flush pushes blind, as before
    uploadSetup()
    store.tomedown.preserve = true
    store.tomedown.cloud_merge = false
    NetworkMgr.connected = true
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    local md_off = T.readFile(MD_PATH)
    remote_files[MD_NAME] = md_off .. "\nSolo sul cloud.\n"
    NetworkMgr.connected = false
    BookList.registry[FILE].annotations = modernAnnotationsWithExtra()
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    NetworkMgr.connected = true
    plugin:flushPendingUploads()
    UIManager:runPending()
    T.check(not T.contains(T.readFile(MD_PATH) or "", "Solo sul cloud."),
        "18: cloud_merge off: the flush does not fold, the local copy wins")

    -- the cloud still holds the very file this plugin uploaded last: no
    -- note of the reader's can sit in it, so folding it into the offline
    -- export takes no copy (it would only fill a slot of the two that
    -- exist for copies worth keeping)
    uploadSetup()
    store.tomedown.preserve = true
    store.tomedown.cloud_merge = true
    NetworkMgr.connected = true
    remote_files, download_fails, downloads = {}, {}, {}
    BookList.registry[FILE].annotations = modernAnnotations()
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    -- the cloud holds exactly the bytes just uploaded (the fake server
    -- keeps no content of its own)
    remote_files[MD_NAME] = T.readFile(MD_PATH)
    T.check(plugin:cloudBase(SERVER)[MD_NAME] == md5(remote_files[MD_NAME]),
        "18: the upload is remembered for the file the cloud holds")
    os.remove(MD_PATH .. ".bak")
    os.remove(MD_PATH .. ".bak.1")
    NetworkMgr.connected = false
    BookList.registry[FILE].annotations = modernAnnotationsWithExtra()
    plugin:runExport({ FILE }, {})
    UIManager:runPending()
    NetworkMgr.connected = true
    downloads = {}
    plugin:flushPendingUploads()
    UIManager:runPending()
    T.check(#downloads > 0,
        "18: the flush fetched the cloud copy it had to fold: " .. #downloads)
    T.check(not T.fileExists(MD_PATH .. ".bak"),
        "18: a cloud copy that is our own upload takes no .bak")

    -- ---------------------- 18b. the flush stays busy while it fetches
    --
    -- the reconcile costs one network GET per file: a reconnect or a resume
    -- landing in the middle of that stretch has to find _flushing already
    -- up. With the flag down, schedulePendingFlush sees a free slot, queues
    -- a second flush over the same paths and both push them at once
    uploadSetup()
    store.tomedown.preserve = true
    store.tomedown.cloud_merge = true
    store.tomedown.pending_uploads = { [MD_PATH] = true }
    NetworkMgr.connected = true
    remote_files, download_fails, downloads = {}, {}, {}

    local orig_reconcile = plugin.reconcilePending
    local reached, seen_busy, seen_rescheduled = false, nil, nil
    plugin.reconcilePending = function(self_plugin, server, paths, dir)
        reached = true
        seen_busy = self_plugin._flushing
        -- exactly what onResume or onNetworkConnected would do right here
        self_plugin._flush_scheduled = false
        self_plugin:schedulePendingFlush()
        seen_rescheduled = self_plugin._flush_scheduled
        return orig_reconcile(self_plugin, server, paths, dir)
    end
    plugin:flushPendingUploads()
    plugin.reconcilePending = nil
    plugin._flush_scheduled = false
    UIManager:runPending()

    T.check(reached, "18b: the flush reaches the reconcile")
    T.check(seen_busy == true,
        "18b: _flushing is up for the whole reconcile: " .. tostring(seen_busy))
    T.check(seen_rescheduled == false,
        "18b: a schedule during the reconcile finds the flush busy: "
            .. tostring(seen_rescheduled))
    T.check(next(store.tomedown.pending_uploads or {}) == nil,
        "18b: the flush still pushes what it reconciled")
end

-- --------------------------------- 19. "Upload everything" reconciles

-- a note typed in Obsidian and synced to the cloud: pressing the button
-- folds it into the push instead of overwriting it
uploadSetup()
store.tomedown.preserve = true
store.tomedown.cloud_merge = true
store.tomedown.covers = false
NetworkMgr.connected = true
remote_files, download_fails, downloads = {}, {}, {}
BookList.registry[FILE].annotations = modernAnnotations()
plugin:runExport({ FILE }, {})
UIManager:runPending()
local seed_md = T.readFile(MD_PATH)
T.check(seed_md ~= nil and plugin:cloudBase(SERVER)[MD_NAME] == md5(seed_md),
    "19: seed export uploaded and remembered")
remote_files[MD_NAME] = seed_md .. "\nA thought from Obsidian.\n"
resetUpload()
downloads = {}
plugin:reuploadAll(nil)
UIManager:runPending()
local pushed_book = false
for __, u in ipairs(uploads) do
    if u.path == MD_PATH then
        pushed_book = true
    end
end
T.check(pushed_book, "19: the book goes up after the fold")
T.check(T.contains(T.readFile(MD_PATH) or "", "A thought from Obsidian."),
    "19: the cloud copy is folded into the local file before the push")
T.check(T.fileExists(MD_PATH .. ".bak.1"),
    "19: the cloud copy is kept whole as the safety copy (.bak.1)")
T.check(#downloads == 2, "19: both markdown copies are fetched first: " .. #downloads)

-- a cloud copy that cannot be fetched: the file stays out of the push
-- and is queued for the automatic retry
remote_files[MD_NAME] = (T.readFile(MD_PATH) or "") .. "\nAppunto mai visto prima d'ora.\n"
download_fails[MD_NAME] = true
resetUpload()
plugin:reuploadAll(nil)
UIManager:runPending()
pushed_book = false
for __, u in ipairs(uploads) do
    if u.path == MD_PATH then
        pushed_book = true
    end
end
T.check(not pushed_book, "19: an unfetchable cloud copy is never pushed blind")
T.check(store.tomedown.pending_uploads
        and store.tomedown.pending_uploads[MD_PATH] == true,
    "19: the held file is queued for the automatic flush")
T.check(not T.contains(T.readFile(MD_PATH) or "", "Appunto mai visto prima d'ora."),
    "19: the local file is left alone while it is held back")

-- with every copy unreadable the button pushes nothing and says so
download_fails[INDEX_NAME] = true
resetUpload()
plugin:reuploadAll(nil)
UIManager:runPending()
T.check(#uploads == 0, "19: nothing goes up while every copy is unreadable")
T.check(InfoMessage.last_text
        and T.contains(InfoMessage.last_text, "files kept back"),
    "19: the kept-back message is shown: " .. tostring(InfoMessage.last_text))
T.check(store.tomedown.pending_uploads[MD_PATH] == true
        and store.tomedown.pending_uploads[INDEX_PATH] == true,
    "19: both held files are queued")

-- offline the button queues everything for the flush instead of
-- failing attempt by attempt
NetworkMgr.connected = false
resetUpload()
plugin:reuploadAll(nil)
UIManager:runPending()
T.check(#uploads == 0, "19: offline: nothing is attempted")
T.check(InfoMessage.last_text
        and T.contains(InfoMessage.last_text, "files kept back"),
    "19: offline: the button says the files are kept back")
NetworkMgr.connected = true

-- with the merge option off the button pushes as it is: the reader has
-- chosen the copy on the device to win
store.tomedown.cloud_merge = false
remote_files[MD_NAME] = (T.readFile(MD_PATH) or "") .. "\nA thought from Obsidian, again.\n"
download_fails = {}
resetUpload()
downloads = {}
plugin:reuploadAll(nil)
UIManager:runPending()
T.check(#downloads == 0, "19: merge off: no fetch happens")
pushed_book = false
for __, u in ipairs(uploads) do
    if u.path == MD_PATH then
        pushed_book = true
    end
end
T.check(pushed_book, "19: merge off: the device copy goes up untouched")
T.check(not T.contains(T.readFile(MD_PATH) or "", "Obsidian, again."),
    "19: merge off: the note in the cloud is not folded in")
T.check(next(store.tomedown.pending_uploads or {}) == nil,
    "19: everything that went up leaves the queue")
store.tomedown.cloud_merge = true

-- ------------------------------ 20. an export with an unreadable copy

-- the note reached the cloud but its download fails this time: the
-- export writes the highlight locally and keeps the book out of the
-- upload instead of pushing over the copy it could not read
uploadSetup()
store.tomedown.preserve = true
store.tomedown.cloud_merge = true
store.tomedown.covers = false
NetworkMgr.connected = true
remote_files, download_fails, downloads = {}, {}, {}
BookList.registry[FILE].annotations = modernAnnotations()
plugin:runExport({ FILE }, {})
UIManager:runPending()
local seed20 = T.readFile(MD_PATH)
T.check(seed20 ~= nil and plugin:cloudBase(SERVER)[MD_NAME] == md5(seed20),
    "20: seed export uploaded and remembered")
remote_files[MD_NAME] = seed20 .. "\nNota sincronizzata sul cloud adesso.\n"
download_fails[MD_NAME] = true
BookList.registry[FILE].annotations = modernAnnotationsWithExtra()
resetUpload()
plugin:runExport({ FILE }, {})
UIManager:runPending()
local book_pushed, index_pushed = false, false
for __, u in ipairs(uploads) do
    if u.path == MD_PATH then
        book_pushed = true
    end
    if u.path == INDEX_PATH then
        index_pushed = true
    end
end
T.check(not book_pushed, "20: the export does not push a cloud copy it could not read")
T.check(index_pushed, "20: the rest of the export still goes up")
T.check(store.tomedown.pending_uploads
        and store.tomedown.pending_uploads[MD_PATH] == true,
    "20: the book is queued for the flush")
T.check(not T.contains(T.readFile(MD_PATH) or "", "Nota sincronizzata sul cloud adesso."),
    "20: the local file comes from its own base, without the note")

-- the fetch works again: the flush folds the note in and pushes the book
download_fails = {}
resetUpload()
plugin:flushPendingUploads()
UIManager:runPending()
book_pushed = false
for __, u in ipairs(uploads) do
    if u.path == MD_PATH then
        book_pushed = true
    end
end
T.check(book_pushed, "20: the queued book reaches the cloud after the fold")
T.check(T.contains(T.readFile(MD_PATH) or "", "Nota sincronizzata sul cloud adesso."),
    "20: the flush folds the note into the queued file")
T.check(next(store.tomedown.pending_uploads or {}) == nil,
    "20: the queue is empty after the flush")

-- with every cloud copy unreadable the export pushes nothing at all
-- and says the files are kept back
download_fails[MD_NAME] = true
download_fails[INDEX_NAME] = true
resetUpload()
plugin:runExport({ FILE }, {})
UIManager:runPending()
T.check(#uploads == 0, "20: nothing goes up while every copy is unreadable")
T.check(InfoMessage.last_text
        and T.contains(InfoMessage.last_text, "files kept back"),
    "20: the export says the files are kept back: "
        .. tostring(InfoMessage.last_text))
T.check(store.tomedown.pending_uploads[MD_PATH] == true
        and store.tomedown.pending_uploads[INDEX_PATH] == true,
    "20: both held files are queued")

store.tomedown.preserve = false
store.tomedown.upload = false


-- ---------------------------- 21. preserve on / off / on / off / on
--
-- The promise behind the .bak: the file is the reader's, and switching
-- preserve any number of times never loses a note nor brings back one
-- that was deleted. While preserve is off the zoned file is parked in
-- .bak; when it is on again that one file is the base of the export, and
-- the next time it goes off the file as it stands then is parked over it
-- (everything the old copy held was folded back in when it returned).
do
    local function wr(path, data)
        local f = io.open(path, "wb"); f:write(data); f:close()
    end
    local function exportNow()
        plugin:runExport({ FILE }, {})
        UIManager:runPending()
    end
    local function addNote(txt)
        local md = T.readFile(MD_PATH) or ""
        wr(MD_PATH, (md:gsub("(<!%-%- tomedown:begin body)", txt .. "\n\n%1", 1)))
    end
    local function dropNote(txt)
        local md = T.readFile(MD_PATH) or ""
        local a, b = md:find(txt .. "\n\n", 1, true)
        wr(MD_PATH, md:sub(1, a - 1) .. md:sub(b + 1))
    end
    local function has(s, path)
        return T.contains(T.readFile(path or MD_PATH) or "", s)
    end
    for __, p in ipairs({ MD_PATH, MD_PATH .. ".bak", MD_PATH .. ".bak.1",
            INDEX_PATH, INDEX_PATH .. ".bak", INDEX_PATH .. ".bak.1" }) do
        os.remove(p)
    end
    store.tomedown.preserve_books = nil
    store.tomedown.preserve_index = nil
    store.tomedown.upload = false
    store.tomedown.exports = nil
    BookList.registry[FILE].annotations = modernAnnotations()

    store.tomedown.preserve = true;  exportNow()
    addNote("NOTE-A")
    store.tomedown.preserve = false; exportNow()
    T.check(not has("NOTE-A") and has("NOTE-A", MD_PATH .. ".bak"),
        "21: off: the file is plain and the note waits in the one .bak")
    store.tomedown.preserve = true;  exportNow()
    T.check(has("NOTE-A"), "21: on: the note is back in the file")

    addNote("NOTE-B"); dropNote("NOTE-A")
    store.tomedown.preserve = false; exportNow()
    T.check(has("NOTE-B", MD_PATH .. ".bak")
            and not has("NOTE-A", MD_PATH .. ".bak"),
        "21: off again: the .bak is the file as it stood, B in, deleted A out")
    store.tomedown.preserve = true;  exportNow()
    T.check(has("NOTE-B") and not has("NOTE-A"),
        "21: on again: B is back and the deleted A stays deleted")

    addNote("NOTE-C")
    store.tomedown.preserve = false; exportNow()
    store.tomedown.preserve = true;  exportNow()
    store.tomedown.preserve = false; exportNow()
    store.tomedown.preserve = true;  exportNow()
    T.check(has("NOTE-B") and has("NOTE-C") and not has("NOTE-A"),
        "21: off/on twice more with no edit in between: B and C, still no A")
    T.check(not T.fileExists(MD_PATH .. ".bak.1"),
        "21: and a single .bak is all that ever exists beside the file")

    -- the reader types into the PLAIN file while preserve is off (it is
    -- rewritten by the next export, so the text cannot join the zone by
    -- itself): the notes of the zone must come back all the same, and
    -- the typed text must be kept somewhere instead of vanishing
    store.tomedown.preserve = false; exportNow()
    wr(MD_PATH, (T.readFile(MD_PATH) or "") .. "\nNOTE-P typed while off\n")
    store.tomedown.preserve = true;  exportNow()
    T.check(has("NOTE-B") and has("NOTE-C") and not has("NOTE-A"),
        "21: a plain file edited while off does not stop the zone coming back")
    T.check(has("NOTE-P", MD_PATH .. ".bak.1"),
        "21: the text typed into the plain file is kept as the safety copy")
    T.check(has("NOTE-B", MD_PATH .. ".bak")
            and has("NOTE-C", MD_PATH .. ".bak"),
        "21: and the parked file is still the zoned one")

    -- one more full round after that, edits on both sides
    addNote("NOTE-D"); dropNote("NOTE-B")
    store.tomedown.preserve = false; exportNow()
    store.tomedown.preserve = true;  exportNow()
    T.check(has("NOTE-C") and has("NOTE-D")
            and not has("NOTE-B") and not has("NOTE-A"),
        "21: after the typed-while-off round: C and D, B and A stay deleted")
    -- the index is a file like the others: same road, same promise
    store.tomedown.preserve = true;  exportNow()
    wr(INDEX_PATH, ((T.readFile(INDEX_PATH) or ""):gsub(
        "(<!%-%- tomedown:begin)", "NOTE-IDX\n\n%1", 1)))
    store.tomedown.preserve = false; exportNow()
    T.check(not has("NOTE-IDX", INDEX_PATH) and has("NOTE-IDX", INDEX_PATH .. ".bak"),
        "21: the index is parked in its own .bak while preserve is off")
    store.tomedown.preserve = true;  exportNow()
    store.tomedown.preserve = false; exportNow()
    store.tomedown.preserve = true;  exportNow()
    T.check(has("NOTE-IDX", INDEX_PATH),
        "21: and its note is back after on / off / on")
    T.check(not T.fileExists(MD_PATH .. ".tmp")
            and not T.fileExists(INDEX_PATH .. ".tmp"),
        "21: no temporary file is left behind")
    -- the copy that keeps the notes cannot be written (a full card, a
    -- read-only folder: here, a directory sits where the .bak goes): the
    -- zoned file must not be replaced, and the export has to say so
    store.tomedown.preserve = true;  exportNow()
    addNote("NOTE-H")
    os.remove(MD_PATH .. ".bak")
    os.remove(MD_PATH .. ".bak.1")
    os.execute('mkdir "' .. MD_PATH .. '.bak"')
    store.tomedown.preserve = false; exportNow()
    T.check(has("NOTE-H") and has("tomedown:begin"),
        "21: when the .bak cannot be written the zoned file is left as it is")
    T.check((store.tomedown.last_export.errors or 0) >= 1,
        "21: and the export reports an error: "
            .. tostring(store.tomedown.last_export.errors))
    os.remove(MD_PATH .. ".bak") -- the directory goes away
    exportNow()
    T.check(not has("NOTE-H") and has("NOTE-H", MD_PATH .. ".bak"),
        "21: next export, with the obstacle gone, the file is parked and plain")
    store.tomedown.preserve = true;  exportNow()
    T.check(has("NOTE-H"), "21: and the note comes back")
    -- the other slot can fail as well: the text typed into the plain file
    -- is kept as .bak.1 before the parked file takes its place, so when
    -- that copy cannot be written the file must not be replaced either
    store.tomedown.preserve = false; exportNow()
    wr(MD_PATH, (T.readFile(MD_PATH) or "") .. "\nNOTE-Q typed while off\n")
    os.execute('mkdir "' .. MD_PATH .. '.bak.1"')
    store.tomedown.preserve = true;  exportNow()
    T.check(has("NOTE-Q") and not has("NOTE-H"),
        "21: when the safety copy cannot be written the plain file is left as it is")
    T.check(has("NOTE-H", MD_PATH .. ".bak"),
        "21: and the parked file still holds the notes")
    T.check((store.tomedown.last_export.errors or 0) >= 1,
        "21: and the export reports the error: "
            .. tostring(store.tomedown.last_export.errors))
    os.remove(MD_PATH .. ".bak.1") -- the directory goes away
    exportNow()
    T.check(has("NOTE-H") and not has("NOTE-Q"),
        "21: next export the parked notes come back")
    T.check(has("NOTE-Q", MD_PATH .. ".bak.1"),
        "21: and the typed text is kept as the safety copy")
    store.tomedown.preserve = false
end


-- ---------------------------- 22. a card that has run the beta.1
--
-- The beta.1 rotated .bak into .bak.1, so the file with the notes can sit
-- in .bak.1 behind a newer copy with no zone: the slots trade places once,
-- the notes come back and a later park does not destroy them.
do
    local function wr(path, data)
        local f = io.open(path, "wb"); f:write(data); f:close()
    end
    local function exportNow()
        plugin:runExport({ FILE }, {})
        UIManager:runPending()
    end
    local function has(s, path)
        return T.contains(T.readFile(path or MD_PATH) or "", s)
    end
    for __, p in ipairs({ MD_PATH, MD_PATH .. ".bak", MD_PATH .. ".bak.1" }) do
        os.remove(p)
    end
    store.tomedown.preserve_books = nil
    store.tomedown.upload = false
    store.tomedown.exports = nil
    BookList.registry[FILE].annotations = modernAnnotations()
    store.tomedown.preserve = true;  exportNow()
    local zoned = (T.readFile(MD_PATH) or ""):gsub(
        "(<!%-%- tomedown:begin body)", "NOTE-L\n\n%1", 1)
    store.tomedown.preserve = false; exportNow()
    os.remove(MD_PATH .. ".bak")
    os.remove(MD_PATH .. ".bak.1")
    wr(MD_PATH .. ".bak", "PLAIN-LEGACY copy\n")
    wr(MD_PATH .. ".bak.1", zoned)
    store.tomedown.preserve = true;  exportNow()
    T.check(has("NOTE-L"),
        "22: the note kept in .bak.1 by the beta.1 comes back into the file")
    T.check(has("NOTE-L", MD_PATH .. ".bak"),
        "22: and the slots traded places: the zoned copy is the .bak")
    T.check(has("PLAIN-LEGACY", MD_PATH .. ".bak.1"),
        "22: while the newer copy without a zone is kept as .bak.1")
    store.tomedown.preserve = false; exportNow()
    T.check(has("NOTE-L", MD_PATH .. ".bak")
            and has("PLAIN-LEGACY", MD_PATH .. ".bak.1"),
        "22: parking afterwards loses neither of the two")
    T.check(not T.fileExists(MD_PATH .. ".bak.swap"),
        "22: no temporary file is left behind")
    -- a swap cut short between its renames leaves the parked copy in
    -- .bak.swap with no .bak beside it: the next export puts it back
    -- before reading the slots
    os.rename(MD_PATH .. ".bak", MD_PATH .. ".bak.swap")
    store.tomedown.preserve = true;  exportNow()
    T.check(has("NOTE-L"), "22: a copy left in .bak.swap comes back")
    T.check(not T.fileExists(MD_PATH .. ".bak.swap"),
        "22: and the temporary name is gone")
    store.tomedown.preserve = false
end

-- ------------------ 23. the cloud moved on while the notes were parked
--
-- Two devices on one cloud folder, the case that used to lose notes:
-- this device holds a parked .bak with notes the cloud copy never got
-- (a second Tomedown with cloud merge off, a conflict from the sync
-- app). The cloud copy is the base of the export, and taking it alone
-- would leave the parked notes behind. They are folded in instead, and
-- the cloud copy is kept whole as the safety copy.
do
    local INDEX_NAME = "00 - Index.md"
    local function put(path, text)
        local f = io.open(path, "wb"); f:write(text); f:close()
    end
    local function addNote(path, txt)
        local text = T.readFile(path) or ""
        put(path, (text:gsub("(<!%-%- tomedown:begin)", txt .. "\n\n%1", 1)))
    end
    local function exportNow()
        plugin:runExport({ FILE }, {})
        UIManager:runPending()
    end
    local function has(s, path)
        return T.contains(T.readFile(path or MD_PATH) or "", s)
    end
    local function times(text, needle)
        local n, pos = 0, 1
        while true do
            local s = text:find(needle, pos, true)
            if not s then
                return n
            end
            n, pos = n + 1, s + #needle
        end
    end
    uploadSetup()
    store.tomedown.preserve = true
    store.tomedown.cloud_merge = true
    store.tomedown.covers = false
    NetworkMgr.connected = true
    remote_files, download_fails, downloads = {}, {}, {}
    BookList.registry[FILE].annotations = modernAnnotations()
    store.tomedown.exports = nil
    for __, p in ipairs({ MD_PATH, MD_PATH .. ".bak", MD_PATH .. ".bak.1",
            INDEX_PATH, INDEX_PATH .. ".bak", INDEX_PATH .. ".bak.1" }) do
        os.remove(p)
    end

    -- seed: both files export with their zone and reach the cloud
    exportNow()
    local seed, seed_idx = T.readFile(MD_PATH), T.readFile(INDEX_PATH)
    T.check(seed ~= nil and seed_idx ~= nil
            and T.contains(seed, "tomedown:begin")
            and T.contains(seed_idx, "tomedown:begin"),
        "23: the seed export wrote both files with their zones")
    remote_files[MD_NAME], remote_files[INDEX_NAME] = seed, seed_idx

    -- a note the cloud had, now on this device alone
    addNote(MD_PATH, "NOTA-KINDLE")
    addNote(INDEX_PATH, "NOTA-INDICE-KINDLE")

    -- preserve off: the zoned files are parked and the files on disk are
    -- plain. The upload of the plain copies does not reach the cloud in
    -- this story: the two zoned copies stay there.
    store.tomedown.preserve = false
    exportNow()
    T.check(not has("tomedown:begin") and not has("tomedown:begin", INDEX_PATH),
        "23: with preserve off both files are plain")
    T.check(has("NOTA-KINDLE", MD_PATH .. ".bak")
            and has("NOTA-INDICE-KINDLE", INDEX_PATH .. ".bak"),
        "23: and the zoned copies wait in their .bak")

    -- meanwhile the cloud copies are replaced by divergent ones: a note
    -- added on the other device, the parked notes never uploaded
    remote_files[MD_NAME] = seed:gsub(
        "(<!%-%- tomedown:begin body)", "NOTA-CLOUD\n\n%1", 1)
    remote_files[INDEX_NAME] = seed_idx:gsub(
        "(<!%-%- tomedown:begin)", "NOTA-INDICE-CLOUD\n\n%1", 1)

    -- preserve on, online: the cloud is the base, the parked notes ride
    -- along and the cloud copy is kept whole
    store.tomedown.preserve = true
    exportNow()
    T.check(has("NOTA-CLOUD") and has("NOTA-KINDLE"),
        "23: the book holds the cloud note and the parked one")
    T.check(times(T.readFile(MD_PATH), "NOTA-KINDLE") == 1
            and times(T.readFile(MD_PATH), "NOTA-CLOUD") == 1,
        "23: each note is written once")
    T.check(has("NOTA-CLOUD", MD_PATH .. ".bak.1"),
        "23: the cloud copy is kept whole as the safety copy")
    T.check(has("NOTA-KINDLE", MD_PATH .. ".bak"),
        "23: the parked copy is still there")
    T.check(has("NOTA-INDICE-CLOUD", INDEX_PATH)
            and has("NOTA-INDICE-KINDLE", INDEX_PATH),
        "23: the index keeps both notes too")
    T.check(has("NOTA-INDICE-CLOUD", INDEX_PATH .. ".bak.1"),
        "23: and its cloud copy is the safety copy")
    T.check((store.tomedown.last_export.errors or 0) == 0,
        "23: the export reports no error")

    -- the upload lands: the next export sees its own copy in the cloud
    -- and adds nothing
    remote_files[MD_NAME] = T.readFile(MD_PATH)
    remote_files[INDEX_NAME] = T.readFile(INDEX_PATH)
    exportNow()
    T.check(times(T.readFile(MD_PATH), "NOTA-KINDLE") == 1
            and times(T.readFile(MD_PATH), "NOTA-CLOUD") == 1,
        "23: a second export against the uploaded file adds nothing")
    store.tomedown.preserve = false
end

-- ------------ 24. the flush folds the notes before it fills the slot
--
-- The queued upload can run before any export. It repairs the beta.1
-- layout first (the notes in .bak.1, a plain copy in .bak), then folds
-- the parked notes into the divergent cloud copy: keepSafety writes
-- .bak.1, and without the repair it would overwrite the only copy with
-- the notes.
do
    local function put(path, text)
        local f = io.open(path, "wb"); f:write(text); f:close()
    end
    local function addNote(path, txt)
        local text = T.readFile(path) or ""
        put(path, (text:gsub("(<!%-%- tomedown:begin)", txt .. "\n\n%1", 1)))
    end
    local function exportNow()
        plugin:runExport({ FILE }, {})
        UIManager:runPending()
    end
    local function has(s, path)
        return T.contains(T.readFile(path or MD_PATH) or "", s)
    end
    local function times(text, needle)
        local n, pos = 0, 1
        while true do
            local s = text:find(needle, pos, true)
            if not s then
                return n
            end
            n, pos = n + 1, s + #needle
        end
    end
    uploadSetup()
    store.tomedown.preserve = true
    store.tomedown.cloud_merge = true
    store.tomedown.covers = false
    NetworkMgr.connected = true
    remote_files, download_fails, downloads = {}, {}, {}
    BookList.registry[FILE].annotations = modernAnnotations()
    store.tomedown.exports = nil
    for __, p in ipairs({ MD_PATH, MD_PATH .. ".bak", MD_PATH .. ".bak.1" }) do
        os.remove(p)
    end
    exportNow()
    local seed = T.readFile(MD_PATH)
    remote_files[MD_NAME] = seed
    addNote(MD_PATH, "NOTA-KINDLE-24")

    -- offline: the zoned file is parked, the plain one goes in the queue
    NetworkMgr.connected = false
    store.tomedown.preserve = false
    exportNow()
    T.check(store.tomedown.pending_uploads
            and store.tomedown.pending_uploads[MD_PATH] == true,
        "24: the plain export waits in the upload queue")

    -- the beta.1 layout: the notes sit in .bak.1 behind a plain .bak
    local zoned = T.readFile(MD_PATH .. ".bak")
    os.remove(MD_PATH .. ".bak")
    put(MD_PATH .. ".bak", "PLAIN-LEGACY-24\n")
    put(MD_PATH .. ".bak.1", zoned)

    -- the cloud moved on and this device is back online: the flush runs
    -- before any export
    remote_files[MD_NAME] = seed:gsub(
        "(<!%-%- tomedown:begin body)", "NOTA-CLOUD-24\n\n%1", 1)
    NetworkMgr.connected = true
    store.tomedown.preserve = true
    resetUpload()
    plugin:reuploadAll(nil)
    UIManager:runPending()
    T.check(has("NOTA-CLOUD-24") and has("NOTA-KINDLE-24"),
        "24: the flush keeps the cloud note and the parked one")
    T.check(times(T.readFile(MD_PATH), "NOTA-KINDLE-24") == 1
            and times(T.readFile(MD_PATH), "NOTA-CLOUD-24") == 1,
        "24: each note is written once")
    T.check(has("NOTA-CLOUD-24", MD_PATH .. ".bak.1"),
        "24: the cloud copy is the safety copy")
    T.check(has("NOTA-KINDLE-24", MD_PATH .. ".bak"),
        "24: the notes found in .bak.1 came back into .bak")
    local pushed = false
    for __, u in ipairs(uploads) do
        if u.path == MD_PATH then
            pushed = true
        end
    end
    T.check(pushed, "24: the folded file goes up")
    store.tomedown.preserve = false
end


-- ---------------------------- 25. the copies kept beside a book, in its menu
--
-- A book that has copies beside its file gets a row that lists them, one
-- by one, and deletes one only after a question that says what it holds.
do
    local function wr(path, data)
        local f = io.open(path, "wb"); f:write(data); f:close()
    end
    local function exportNow()
        plugin:runExport({ FILE }, {})
        UIManager:runPending()
    end
    local function backupRow()
        for __, group in ipairs(menu_items.tomedown.sub_item_table_func()) do
            if group.text and group.text:find("Current book", 1, true) then
                for __, row in ipairs(group.sub_item_table_func()) do
                    if row.text and row.text:find("Backup copies", 1, true) then
                        return row
                    end
                end
            end
        end
    end
    local function tap(item)
        item.callback(nil)
        UIManager:runPending()
        return ConfirmBox.last
    end
    for __, p in ipairs({ MD_PATH, MD_PATH .. ".bak", MD_PATH .. ".bak.1" }) do
        os.remove(p)
    end
    store.tomedown.preserve_books = nil
    store.tomedown.upload = false
    store.tomedown.exports = nil
    BookList.registry[FILE].annotations = modernAnnotations()

    store.tomedown.preserve = true;  exportNow()
    ui.document = { file = FILE }
    T.check(backupRow() == nil, "25: a book with no copy has no row for them")
    local md = T.readFile(MD_PATH) or ""
    wr(MD_PATH, (md:gsub("(<!%-%- tomedown:begin body)", "NOTE-Z\n\n%1", 1)))
    store.tomedown.preserve = false; exportNow()   -- parked in .bak, file plain
    wr(MD_PATH .. ".bak.1", "SAFETY-TEXT\n")

    local row = backupRow()
    T.check(row ~= nil, "25: the row is there once the book has copies")
    ui.document = nil
    store.lastfile = FILE
    T.check(backupRow() == nil,
        "25: and it needs an open book: not on the dashboard")
    store.lastfile = nil
    ui.document = { file = FILE }
    local items = row.sub_item_table_func()
    T.check(#items == 2 and items[1].text == "Notes set aside"
            and items[2].text == "Safety copy",
        "25: the notes set aside come first, the safety copy after it")
    T.check(type(items[1].mandatory) == "string"
            and items[1].mandatory:match("^%d%d%d%d%-%d%d%-%d%d$"),
        "25: each copy shows the day it was saved")

    -- the parked file is where the notes are while the book has no zone
    local box = tap(items[1])
    T.check(box and T.contains(box.text, "Notes set aside")
            and T.contains(box.text, "when you turned Keep my notes off")
            and T.contains(box.text, "deletes those notes for good"),
        "25: the question names the copy and warns that the notes are in it")
    box.cancel_callback()
    T.check(T.fileExists(MD_PATH .. ".bak"),
        "25: keeping it leaves the copy where it is")

    -- the safety copy: other words, no warning, and nothing else goes
    box = tap(items[2])
    T.check(box and T.contains(box.text, "Safety copy")
            and not T.contains(box.text, "deletes those notes for good"),
        "25: the safety copy has its own question and no warning")
    local plain_before = T.readFile(MD_PATH)
    box.ok_callback()
    T.check(not T.fileExists(MD_PATH .. ".bak.1"),
        "25: deleting removes the copy")
    T.check(T.fileExists(MD_PATH .. ".bak")
            and T.readFile(MD_PATH) == plain_before,
        "25: and nothing else: the parked file and the book's file stay")

    -- with the zone back in the book, the parked file is no longer the
    -- only place the notes are: no warning
    store.tomedown.preserve = true;  exportNow()
    items = backupRow().sub_item_table_func()
    box = tap(items[1])
    T.check(box and not T.contains(box.text, "deletes those notes for good"),
        "25: with the notes back in the file the warning is not shown")
    box.ok_callback()
    T.check(not T.fileExists(MD_PATH .. ".bak"), "25: the last copy goes")
    T.check(T.contains(T.readFile(MD_PATH) or "", "NOTE-Z"),
        "25: and the notes in the book's file are untouched")
    T.check(backupRow() == nil,
        "25: with no copy left the row is gone")
    -- a plain .bak, left by a version before the markers, is an older
    -- copy: it says so and carries no warning about the notes
    wr(MD_PATH .. ".bak", "OLD-TEXT\n")
    local older = backupRow()
    T.check(older ~= nil, "25: a plain .bak brings the row back")
    items = older.sub_item_table_func()
    T.check(#items == 1 and items[1].text == "Older copy",
        "25: a plain .bak is listed as an older copy")
    box = tap(items[1])
    T.check(box and T.contains(box.text, "A copy kept by an earlier version")
            and not T.contains(box.text, "deletes those notes for good"),
        "25: the older copy says what it is and carries no warning")
    box.ok_callback()
    T.check(not T.fileExists(MD_PATH .. ".bak") and backupRow() == nil,
        "25: deleting the older copy leaves no row")
    ui.document = nil
    store.tomedown.preserve = false
end

T.finish("test_main")
