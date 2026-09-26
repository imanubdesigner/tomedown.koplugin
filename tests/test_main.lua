--[[--
Test di main.lua con un ambiente KOReader finto.

Copre: hash md5, esportazione, indice, formato .sdr vecchi, menu, dialoghi,
server fallback, upload su Koofr e soprattutto la patch di backoff
(UPLOAD_MAX_ATTEMPTS = 3, delay 2s/4s, solo per errori transitori).
--]]
local HERE = arg[0]:match("^(.*)/") or "."
package.path = HERE .. "/?.lua;" .. package.path
local T = require("common")

-- --------------------------------------------------------------- ambiente

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
local readhistory = require("readhistory")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local InputDialog = require("ui/widget/inputdialog")
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
    -- KOReader: verifica la connessione, poi esegue il passaggio
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
        -- segnalibro di pagina (nessun drawer): escluso
        { text = "Segnalibro di pagina", pageno = 5, datetime = "2026-09-01 09:00:00" },
        -- evidenziato cancellato: escluso
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

-- ------------------------------------------------------------- aiuti

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

-- ------------------------------------------------- 1. md5 dello stub

T.check(md5("") == "d41d8cd98f00b204e9800998ecf8427e", "md5 della stringa vuota")
T.check(md5("abc") == "900150983cd24fb0d6963f7d28e17f72", "md5 di 'abc'")
T.check(md5("The quick brown fox jumps over the lazy dog")
    == "9e107d9d372bb6826bd81d3542a419d6", "md5 di una frase")
T.check(md5(string.rep("1234567890", 10))
    == "49cb3608e2b33fad6b65df8cb8f49668", "md5 su più blocchi")
T.check(#md5("x") == 32, "md5 esadecimale su 32 caratteri")

-- ------------------------------------------- 2. esportazione corrente

cleanDir()
resetUpload()
store = {}
store.tomedown = {}

plugin:runExport({ FILE }, {})
UIManager:runPending()

local md = T.readFile(MD_PATH)
T.check(md ~= nil, "md del libro scritto in " .. MD_PATH)
if md then
    T.check(T.contains(md, 'title: "Blackwater"'), "frontmatter title")
    T.check(T.contains(md, 'author: "Michael McDowell"'), "frontmatter author")
    T.check(T.contains(md, "highlights: 2"), "solo gli evidenziati validi")
    T.check(T.contains(md, "  - kindle"), "tag kindle")
    T.check(T.contains(md, "# Blackwater"), "h1")
    T.check(T.contains(md, "**2 highlights**"), "conteggio")
    T.check(T.contains(md, "## Capitolo I"), "capitolo 1")
    T.check(T.contains(md, "## Capitolo II"), "capitolo 2")
    T.check(T.contains(md, "> Prima frase."), "citazione")
    T.check(T.contains(md, "- **p. 10** · 02/09/2026 · note: nota utente"), "meta con nota")
    T.check(T.contains(md, "nota utente"), "nota presente")
    T.check(not T.contains(md, "Segnalibro"), "segnalibro di pagina escluso")
    T.check(not T.contains(md, "Cancellato"), "evidenziato cancellato escluso")
    T.check(not T.contains(md, "cover"), "nessuna copertina")
    T.check(not T.contains(md, "![]("), "nessuna immagine")
end

T.check(Notification.last_text == "1 files exported",
    "notifica di esportazione: " .. tostring(Notification.last_text))
T.check(lfs.attributes(DIR .. "/covers", "mode") ~= "directory",
    "cartella covers non creata")

local index = T.readFile(INDEX_PATH)
T.check(index ~= nil, "indice scritto")
if index then
    T.check(T.contains(index, "[[Michael McDowell - Blackwater|Blackwater]]"),
        "wikilink nell'indice")
    T.check(T.contains(index, "| 2 |"), "colonne indice (conteggio)")
    T.check(T.contains(index, os.date("%d/%m/%Y")), "data di oggi nell'indice")
end

-- indice più voci dopo l'esportazione di tutti i libri
plugin:runExport(plugin:listBookFiles(), {})
UIManager:runPending()
T.check(#plugin:listBookFiles() == 3, "tre libri elencati (dim escluso)")
T.check(Notification.last_text == "3 files exported",
    "esportazione multipla: " .. tostring(Notification.last_text))

index = T.readFile(INDEX_PATH)
if index then
    T.check(T.contains(index, "[[N_A - LibroVecchio|LibroVecchio]]"),
        "libro in formato .sdr vecchio nell'indice")
    T.check(T.contains(index, "[[Autore X - Senza Meta|Senza Meta]]"),
        "titolo dal nome file quando manca il title")
end

local legacy_md = T.readFile(DIR .. "/N_A - LibroVecchio.md")
T.check(legacy_md ~= nil, "export del libro con .sdr vecchio")
if legacy_md then
    T.check(T.contains(legacy_md, "> Vecchio evidenziato"), "evidenziato da highlight legacy")
    T.check(T.contains(legacy_md, "note: nota vecchia"), "nota da bookmarks legacy")
    T.check(T.contains(legacy_md, "**p. 3**"), "pagina legacy")
end

local no_props_md = T.readFile(DIR .. "/Autore X - Senza Meta.md")
T.check(no_props_md ~= nil, "export senza doc_props.title")
if no_props_md then
    T.check(T.contains(no_props_md, "title: \"Senza Meta\""),
        "display_title ricavato dal nome file")
end

-- ------------------------------------------------ 3. only_updated/hash

resetUpload()
T.check(store.tomedown.exports ~= nil and store.tomedown.exports[FILE] ~= nil,
    "record di export salvato")
local saved_hash = store.tomedown.exports and store.tomedown.exports[FILE]
    and store.tomedown.exports[FILE].hash
T.check(saved_hash and #saved_hash == 32, "hash del libro (32 hex)")

plugin:runExport({ FILE }, { only_updated = true })
UIManager:runPending()
T.check(T.contains(Notification.last_text or "", "1 files unchanged, skipped"),
    "nessuna modifica: " .. tostring(Notification.last_text))

local annotations = modernAnnotations()
annotations[1].text = "Prima frase modificata."
BookList.registry[FILE].annotations = annotations

plugin:runExport({ FILE }, { only_updated = true })
UIManager:runPending()
local updated = T.readFile(MD_PATH)
T.check(updated ~= nil and T.contains(updated, "Prima frase modificata."),
    "contenuto riesportato dopo la modifica")
T.check(T.contains(Notification.last_text or "", "1 files exported"),
    "riesportazione: " .. tostring(Notification.last_text))
local new_hash = store.tomedown.exports[FILE].hash
T.check(new_hash ~= saved_hash, "hash cambia con le nuove annotazioni")

BookList.registry[FILE].annotations = modernAnnotations()
plugin:runExport({ FILE }, { only_updated = true })
UIManager:runPending()
T.check(T.contains(Notification.last_text or "", "1 files exported"),
    "riesportata la versione ripristinata")

-- ------------------------------------------------------- 4. md5 su file

T.check(store.tomedown.exports[FILE].hash == saved_hash,
    "hash tornato identico al precedente")

-- ------------------------------------------------------------ 5. menu

local menu_items = {}
plugin:addToMainMenu(menu_items)
T.check(menu_items.tomedown ~= nil, "voce di menu registrata")
local sub = menu_items.tomedown.sub_item_table
T.check(#sub == 6, "voci del menu principale: " .. #sub)
T.check(sub[1].text == "Export current book", "voce 1")
T.check(sub[2].text == "Only updated", "voce 2")
T.check(sub[3].text == "Choose books…", "voce 3")
T.check(sub[4].text == "All books with highlights", "voce 4")
T.check(sub[5].text == "Reload everything to Koofr", "voce 5")
T.check(sub[6].text == "Settings", "voce 6")

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
T.check(not cover_entry, "nessuna voce di menu sulle copertine")

ui.document = { file = FILE }
T.check(sub[1].enabled_func() == true, "esporta corrente abilitato col libro aperto")
ui.document = nil
store.lastfile = FILE
T.check(sub[1].enabled_func() == true, "esporta corrente abilitato con lastfile")
store.lastfile = nil
T.check(sub[1].enabled_func() == false, "esporta corrente disabilitato senza file")
ui.document = { file = nil }
T.check(sub[4].enabled_func() == true, "tutti i libri abilitato")

local settings = plugin:genSettingsMenu()
T.check(#settings == 5, "voci di impostazioni: " .. #settings)
T.check(settings[1].text == "Upload to Koofr", "voce upload")
T.check(settings[2].text_func() == "Server and folder: not set", "server non impostato")
T.check(T.contains(settings[3].text_func(), "Remote folder: not set"), "cartella remota non impostata")
T.check(T.contains(settings[4].text_func(), "clipboard/tomedown"), "cartella locale di default")
T.check(T.contains(settings[5].text, "00 - Index.md"), "voce indice col nome del file")

settings[1].callback()
T.check(store.tomedown.upload == false, "upload disattivato")
settings[1].callback()
T.check(store.tomedown.upload == true, "upload riattivato")
settings[5].callback()
T.check(store.tomedown.with_index == false, "indice disattivato")
settings[5].callback()
T.check(store.tomedown.with_index == true, "indice riattivato")

-- scelta del server dalla lista di Cloud storage
plugin:chooseCloudFolder(nil)
T.check(cloud_list_callback ~= nil, "lista cloud aperta")
cloud_list_callback({ name = "Koofr", type = "webdav", url = "/Bookshelf/Kindle" })
T.check(store.tomedown.server and store.tomedown.server.name == "Koofr", "server salvato")
T.check(settings[2].text_func() == "Server and folder: Koofr (webdav) → /Bookshelf/Kindle",
    "testo server aggiornato: " .. settings[2].text_func())
T.check(plugin:hasServer() == true, "hasServer vero con server e cloud")

-- dialogo cartella remota
plugin:editRemoteFolder(nil)
local dialog = InputDialog.last
T.check(dialog ~= nil and dialog.title == "Remote folder on Koofr", "dialogo remoto aperto")
dialog.input_text = "  /Cartella mia  "
dialog:simulateSave()
T.check(store.tomedown.remote_folder == "/Cartella mia", "cartella remota salvata e ripulita")
T.check(T.contains(settings[3].text_func(), "/Cartella mia"), "voce menu aggiornata")
plugin:editRemoteFolder(nil)
InputDialog.last.input_text = ""
InputDialog.last:simulateSave()
T.check(store.tomedown.remote_folder == "", "cartella remota azzerata")

-- dialogo cartella locale
plugin:editLocalDir(nil)
local local_dialog = InputDialog.last
T.check(T.contains(local_dialog.input, "clipboard/tomedown"), "path di default nel dialogo")
local_dialog.input_text = DATA .. "/out-customi"
local_dialog:simulateSave()
T.check(plugin:getLocalDir() == DATA .. "/out-customi", "cartella locale cambiata")
store.tomedown.local_dir = nil
T.check(plugin:getLocalDir() == DIR, "cartella locale tornata al default")

-- menu di scelta dei libri
local picker = plugin:genPickerMenu()
T.check(#picker == 5, "picker: 2 comandi + 3 libri (" .. #picker .. ")")
T.check(T.contains(picker[1].text_func(), "Export selected (0)"), "nessun libro selezionato")
T.check(picker[1].enabled_func() == false, "esporta selezionati disabilitato")
for i = 3, #picker do
    local text = picker[i].text_func()
    T.check(text:match("%(%d+%)$") ~= nil, "riga libro con conteggio: " .. text)
    local checked = picker[i].checked_func()
    T.check(checked == nil or checked == true, "stato selezione: " .. tostring(checked))
end

store.tomedown.selected = { [FILE] = true }
store.tomedown.upload = false
picker = plugin:genPickerMenu()
T.check(T.contains(picker[1].text_func(), "Export selected (1)"), "un libro selezionato")
T.check(picker[1].enabled_func() == true, "esporta selezionati abilitato")
picker[1].callback(nil)
UIManager:runPending()
T.check(Notification.last_text == "1 files exported",
    "esportazione dei selezionati: " .. tostring(Notification.last_text))

picker = plugin:genPickerMenu()
picker[2].callback(nil)
T.check(store.tomedown.selected[FILE] == nil, "deselezione totale")

store = {}
store.tomedown = {}
T.check(plugin:genPickerMenu()[1].text_func() == "Export selected (0)",
    "nessuna selezione dopo il reset")

-- ------------------------------------------------- 6. server in fallback

local srv = plugin:getServer()
T.check(srv == nil, "nessun server configurato")

store.cloud_server_object = json.encode({
    name = "Legacy",
    type = "webdav",
    address = "https://legacy.example/dav",
})
srv = plugin:getServer()
T.check(srv ~= nil and srv.name == "Legacy" and srv.type == "webdav",
    "server da cloud_server_object (JSON)")

store.cloud_server_object = "{ non è json"
T.check(plugin:getServer() == nil, "JSON rotto non fa esplodere getServer")

store.cloud_server_object = nil
store.annotation_sync = { sync_server = { name = "Sync", type = "webdav", address = "https://sync.example/dav" } }
srv = plugin:getServer()
T.check(srv ~= nil and srv.name == "Sync", "server da annotation_sync.sync_server")

store.annotation_sync_plugin = { sync_server = { name = "Plugin", type = "webdav", address = "https://p.example" } }
T.check(plugin:getServer().name == "Plugin", "priorità a annotation_sync_plugin")

-- --------------------------------------------------------- 7. upload

uploadSetup()
plugin:runExport({ FILE }, {})
T.check(#uploads == 1, "primo upload avviato subito: " .. #uploads)
T.check(uploads[1].path == MD_PATH, "primo file = md del libro")
T.check(InfoMessage.last_text == "Uploading 2 files to Koofr…",
    "finestra di progresso: " .. tostring(InfoMessage.last_text))
T.check(#UIManager.shown == 1 and UIManager.shown[1].text == InfoMessage.last_text,
    "progresso ancora aperto durante la fase di upload")
UIManager:runPending()
T.check(#uploads == 2, "caricati md e indice: " .. #uploads)
T.check(uploads[2].path == INDEX_PATH, "secondo file = indice")
T.check(uploads[1].url == "/Bookshelf/Kindle" and uploads[2].url == "/Bookshelf/Kindle",
    "url della cartella Koofr")
T.check(attempt_count[MD_PATH] == 1 and attempt_count[INDEX_PATH] == 1,
    "un tentativo per file in condizioni normali")
T.check(T.contains(Notification.last_text or "", "Koofr: 2 files uploaded"),
    "notifica upload: " .. tostring(Notification.last_text))
local widget = onlyWidget()
T.check(widget and widget.__widget == "Notification",
    "solo la notifica finale rimane aperta")

-- upload disattivato
uploadSetup()
store.tomedown.upload = false
plugin:runExport({ FILE }, {})
UIManager:runPending()
T.check(#uploads == 0, "nessun upload con upload=false")
T.check(Notification.last_text == "1 files exported",
    "notifica solo esportazione: " .. tostring(Notification.last_text))

-- cartella remota esplicita
uploadSetup()
store.tomedown.remote_folder = "/Cartella mia"
plugin:runExport({ FILE }, {})
UIManager:runPending()
T.check(#uploads == 2 and uploads[1].url == "/Cartella mia",
    "upload nella cartella scelta: " .. tostring(uploads[1] and uploads[1].url))

-- server senza "url" ma con "address" (come quelli di AnnotationSync)
store = {}
store.tomedown = { upload = true }
store.annotation_sync = {
    sync_server = { name = "Sync", type = "webdav", address = "https://webdav.koofr.net/dav/Bookshelf" },
}
resetUpload()
plugin:runExport({ FILE }, {})
UIManager:runPending()
T.check(#uploads == 2, "upload col server ad address: " .. #uploads)
T.check(uploads[1] and uploads[1].url == "https://webdav.koofr.net/dav/Bookshelf",
    "usato address quando manca url: " .. tostring(uploads[1] and uploads[1].url))

-- ------------------------------------------------------- 8. backoff

-- errore transitorio (500) sul primo tentativo, poi ok
uploadSetup()
upload_script[MD_PATH] = { 500, 200 }
plugin:runExport({ FILE }, {})
T.check(#uploads == 1, "primo tentativo fallito registrato: " .. #uploads)
T.check(sameList(positives(), { 2 }),
    "ritardo di retry programmato a 2s: " .. listStr(positives()))
T.check(UIManager:pendingCount() == 1, "un retry in coda")
UIManager:runPending()
T.check(attempt_count[MD_PATH] == 2, "md ritentato una volta: " .. attempt_count[MD_PATH])
T.check(attempt_count[INDEX_PATH] == 1, "indice non toccato dal guasto del md")
T.check(sameList(positives(), { 2 }), "backoff iniziale 2s, ottenuto " .. listStr(positives()))
T.check(T.contains(Notification.last_text or "", "Koofr: 2 files uploaded"),
    "recupero completo: " .. tostring(Notification.last_text))
T.check(T.contains(table.concat(logger.history, "\n"), "retrying in"),
    "retry tracciato nel log")

-- guasto permanente: 3 tentativi e poi si arrende
uploadSetup()
upload_script[MD_PATH] = { 500, 500, 500, 500 }
upload_script[INDEX_PATH] = { 500, 500, 500, 500 }
plugin:runExport({ FILE }, {})
UIManager:runPending()
T.check(#uploads == 6, "3 tentativi per ciascuno dei 2 file: " .. #uploads)
T.check(attempt_count[MD_PATH] == 3 and attempt_count[INDEX_PATH] == 3,
    "massimo 3 tentativi per file")
T.check(sameList(positives(), { 2, 4, 2, 4 }),
    "backoff 2s/4s per ogni file, ottenuto " .. listStr(positives()))
T.check(Notification.last_text == nil, "nessuna notifica di successo")
local err_widget = onlyWidget()
T.check(err_widget and err_widget.__widget == "InfoMessage", "finestra errori mostrata")
T.check(err_widget and T.contains(err_widget.text, "Koofr: 0 uploaded, 2 errors"),
    "esito con errori: " .. tostring(err_widget and err_widget.text))
T.check(err_widget and T.contains(err_widget.text, "1 files exported"),
    "l'esito include anche l'esportazione: " .. tostring(err_widget and err_widget.text))

-- 4xx (cartella inesistente): nessun ritentativo
uploadSetup()
upload_script[MD_PATH] = { 404 }
upload_script[INDEX_PATH] = { 404 }
plugin:runExport({ FILE }, {})
UIManager:runPending()
T.check(#uploads == 2, "404: un solo tentativo per file: " .. #uploads)
T.check(#positives() == 0, "nessun ritardo sugli errori 4xx: " .. listStr(positives()))
err_widget = onlyWidget()
T.check(err_widget and T.contains(err_widget.text, "Koofr: 0 uploaded, 2 errors"),
    "404 segnalato come errore definitivo")

-- errore di rete non numerico: ritentato
uploadSetup()
upload_script[MD_PATH] = function(n)
    if n < 3 then
        return "connection reset"
    end
    return 200
end
plugin:runExport({ FILE }, {})
UIManager:runPending()
T.check(attempt_count[MD_PATH] == 3, "errore di rete ritentato: " .. tostring(attempt_count[MD_PATH]))
T.check(sameList(positives(), { 2, 4 }),
    "backoff anche senza codice numerico: " .. listStr(positives()))
T.check(T.contains(Notification.last_text or "", "Koofr: 2 files uploaded"),
    "recupero dopo gli errori di rete: " .. tostring(Notification.last_text))

-- 429 (troppe richieste): transitorio
uploadSetup()
upload_script[MD_PATH] = { 429, 200 }
plugin:runExport({ FILE }, {})
UIManager:runPending()
T.check(attempt_count[MD_PATH] == 2, "429 ritentato: " .. tostring(attempt_count[MD_PATH]))
T.check(sameList(positives(), { 2 }), "backoff sul 429: " .. listStr(positives()))

-- codice di successo non nel range 2xx
uploadSetup()
upload_script[INDEX_PATH] = { 301, 301, 301, 301 }
plugin:runExport({ FILE }, {})
UIManager:runPending()
T.check(attempt_count[INDEX_PATH] == 1, "301 non è un successo ma non è nemmeno transitorio: "
    .. tostring(attempt_count[INDEX_PATH]))
T.check(#positives() == 0, "nessun ritardo sul 301: " .. listStr(positives()))

-- ------------------------------------------------- 9. Reload everything

uploadSetup()
store.tomedown.upload = false
cleanDir()
plugin:runExport({ FILE }, {})
T.check(#uploads == 0, "prima fase: solo export")
T.check(T.fileExists(MD_PATH) and T.fileExists(INDEX_PATH), "file locali presenti")

-- una cartella di copertine residua non deve finire nell'upload
os.execute('mkdir -p "' .. DIR .. '/covers" && printf x > "' .. DIR .. '/covers/copertina.jpg"')

resetUpload()
store.tomedown.upload = true
plugin:reuploadAll(nil)
UIManager:runPending()
T.check(#uploads == 2, "ricaricati solo i .md: " .. #uploads)
T.check(uploads[1].path == INDEX_PATH, "ordinato: indice per primo")
T.check(uploads[2].path == MD_PATH, "ordinato: md del libro per secondo")
T.check(Notification.last_text == "Koofr: 2 files uploaded",
    "notifica reload: " .. tostring(Notification.last_text))
T.rmrf(DIR .. "/covers")

store = {}
resetUpload()
plugin:reuploadAll(nil)
T.check(T.contains(InfoMessage.last_text or "", "Choose a Koofr server"),
    "senza server: " .. tostring(InfoMessage.last_text))

-- cartella locale vuota
store = {}
store.tomedown = { server = SERVER, upload = true }
resetUpload()
cleanDir()
plugin:reuploadAll(nil)
UIManager:runPending()
T.check(#uploads == 0, "nessun file da ricaricare")
T.check(Notification.last_text == "Nothing to upload, export something first.",
    "notifica cartella vuota: " .. tostring(Notification.last_text))

-- ------------------------------------------- 10. nessuna copertina ovunque

local sources = { "main.lua", "tomedown_render.lua", "README.md" }
for __, name in ipairs(sources) do
    local src = T.readFile(T.plugin .. "/" .. name)
    if src then
        local lower = src:lower()
        T.check(not lower:find("buildcover") and not lower:find("cover_path")
            and not lower:find("covers/", 1, true),
            name .. " non contiene più riferimenti alle copertine")
    end
end

T.finish("test_main")
