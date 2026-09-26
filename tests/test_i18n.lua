--[[--
Test di tomedown_i18n.lua: caricamento del .po secondo la lingua attiva,
fallback su msgid, cambio di lingua a caldo e integrazione con render.
--]]
local HERE = arg[0]:match("^(.*)/") or "."
package.path = HERE .. "/?.lua;" .. package.path
local T = require("common")

local GetText = require("gettext")
local i18n = require("tomedown_i18n")

local function setLang(lang)
    GetText.current_lang = lang
end

-- 1. nessuna lingua: msgid inglese
setLang(nil)
T.check(i18n("Book index") == "Book index", "nessuna lingua -> msgid")
T.check(i18n("No chapter") == "No chapter", "nessuna lingua, seconda stringa")
T.check(i18n("stringa non presente") == "stringa non presente", "msgid sconosciuto invariato")

-- 2. inglese esplicito: nessun caricamento
setLang("en")
T.check(i18n("Book index") == "Book index", "lingua en -> msgid")

-- 3. italiano: vengono le traduzioni
setLang("it")
T.check(i18n("Book index") == "Indice dei libri", "it: Book index")
T.check(i18n("No chapter") == "Senza capitolo", "it: No chapter")
T.check(i18n("Export in progress…") == "Esportazione in corso…", "it: messaggio progresso")
T.check(i18n("%1 files exported") == "%1 file esportati", "it: notifica con segnaposto")
T.check(i18n("stringa non presente") == "stringa non presente", "it: fallback su msgid")

-- 4. getter esplicito
T.check(i18n.gettext("Book index") == "Indice dei libri", "gettext() come __call")

-- 5. variante regionale it_IT -> cade su it.po
setLang("it_IT")
T.check(i18n("Book index") == "Indice dei libri", "it_IT -> it.po")
setLang("it-IT")
T.check(i18n("Book index") == "Indice dei libri", "it-IT -> it.po")

-- 6. lingua senza file di traduzione: msgid
setLang("fr")
T.check(i18n("Book index") == "Book index", "fr senza po -> msgid")
setLang("de")
T.check(i18n("No chapter") == "No chapter", "de senza po -> msgid")

-- 7. stringa multiriga dell'indice
setLang("it")
T.check(i18n("| Book | Author | Highlights | Last export |")
    == "| Libro | Autore | Evidenziati | Ultimo export |", "it: header tabella")

-- 8. la lingua cambia anche dopo il caricamento (reload)
setLang(nil)
T.check(i18n("Book index") == "Book index", "tornato a nessuna lingua")
setLang("it")
T.check(i18n("Book index") == "Indice dei libri", "rientrato in italiano")

-- 9. lingua letta da G_reader_settings quando GetText non la sa
setLang(nil)
local saved_setting = nil
G_reader_settings = G_reader_settings or {
    readSetting = function(_, key)
        if key == "language" then
            return saved_setting
        end
    end,
    saveSetting = function() end,
}
saved_setting = "it"
T.check(i18n("Book index") == "Indice dei libri", "lingua da G_reader_settings")
saved_setting = nil

-- 10. render usa le traduzioni a runtime
setLang("it")
local render = require("tomedown_render")
local md = render.buildBookMd({
    title = "Libro",
    count = 1,
    annotations = { { text = "X" } },
})
T.check(T.contains(md, "evidenziati"), "render traduce il tag highlights")
T.check(T.contains(md, "**1 evidenziati**"), "render traduce il conteggio")

local mixed = render.buildBookMd({
    title = "Libro",
    count = 2,
    annotations = { { text = "X", chapter = "Capitolo I" }, { text = "Y" } },
}, { no_chapter_label = i18n("No chapter") })
T.check(T.contains(mixed, "## Senza capitolo"), "etichetta capitolo tradotta")

local index = render.buildIndexMd({
    { link = "B", title = "B", author = "A", count = 1, date = "01/01/2026" },
}, { title = i18n("Book index") })
T.check(T.contains(index, "# Indice dei libri"), "titolo indice tradotto")
T.check(T.contains(index, "| Libro | Autore | Evidenziati | Ultimo export |"),
    "header indice tradotto")

setLang("en")
T.check(T.contains(render.buildIndexMd({}, {}), "# Book index"), "torna all'inglese")

-- 11. la stessa istanza di render vede il cambio di lingua (nessun caching)
setLang("it")
T.check(T.contains(render.buildBookMd({
    title = "L", count = 1, annotations = { { text = "X" } },
}), "evidenziati"), "nessun caching del catalogo in render")

T.finish("test_i18n")
