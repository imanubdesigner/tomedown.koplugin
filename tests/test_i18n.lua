--[[--
Tests for tomedown_i18n.lua: .po loading based on the active language,
fallback to msgid, hot language switching and render integration.
--]]
local HERE = arg[0]:match("^(.*)/") or "."
package.path = HERE .. "/?.lua;" .. package.path
local T = require("common")

local GetText = require("gettext")
local i18n = require("tomedown_i18n")

local function setLang(lang)
    GetText.current_lang = lang
end

-- 1. no language: English msgid
setLang(nil)
T.check(i18n("Book index") == "Book index", "no language -> msgid")
T.check(i18n("No chapter") == "No chapter", "no language, second string")
T.check(i18n("stringa non presente") == "stringa non presente", "unknown msgid unchanged")

-- 2. explicit English: nothing loaded
setLang("en")
T.check(i18n("Book index") == "Book index", "language en -> msgid")

-- 3. Italian: translations come through
setLang("it")
T.check(i18n("Book index") == "Indice dei libri", "it: Book index")
T.check(i18n("No chapter") == "Senza capitolo", "it: No chapter")
T.check(i18n("Export in progress…") == "Esportazione in corso…", "it: progress message")
T.check(i18n("%1 files exported locally") == "%1 file esportati localmente",
    "it: notification with placeholder")
T.check(i18n("Check for updates (v%1)") == "Controlla aggiornamenti (v%1)",
    "it: check for updates row")
T.check(i18n("Update available!") == "Aggiornamento disponibile!", "it: update dialog title")
T.check(i18n("stringa non presente") == "stringa non presente", "it: falls back to msgid")

-- 4. explicit getter
T.check(i18n.gettext("Book index") == "Indice dei libri", "gettext() same as __call")

-- 5. regional variant it_IT -> falls back to it.po
setLang("it_IT")
T.check(i18n("Book index") == "Indice dei libri", "it_IT -> it.po")
setLang("it-IT")
T.check(i18n("Book index") == "Indice dei libri", "it-IT -> it.po")

-- 6. language without a translation file: msgid
setLang("fr")
T.check(i18n("Book index") == "Book index", "fr without po -> msgid")
setLang("de")
T.check(i18n("No chapter") == "No chapter", "de without po -> msgid")

-- 7. the index table is translated cell by cell now (the header gained
-- the cover/series/status columns in v0.8.0)
setLang("it")
T.check(i18n("Book") == "Libro", "it: cell Book")
T.check(i18n("Author") == "Autore", "it: cell Author")
T.check(i18n("Series") == "Serie", "it: cell Series")
T.check(i18n("Status") == "Stato", "it: cell Status")
T.check(i18n("Highlights") == "Evidenziati", "it: cell Highlights")
T.check(i18n("Last export") == "Ultimo export", "it: cell Last export")
T.check(i18n("Cover") == "Copertina", "it: cell Cover")

-- 8. the language changes even after loading (reload)
setLang(nil)
T.check(i18n("Book index") == "Book index", "back to no language")
setLang("it")
T.check(i18n("Book index") == "Indice dei libri", "back in Italian")

-- 9. language read from G_reader_settings when GetText does not know it
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
T.check(i18n("Book index") == "Indice dei libri", "language from G_reader_settings")
saved_setting = nil

-- 10. render uses the translations at runtime
setLang("it")
local render = require("tomedown_render")
local md = render.buildBookMd({
    title = "Libro",
    count = 1,
    annotations = { { text = "X" } },
})
T.check(T.contains(md, "evidenziati"), "render translates the highlights tag")
T.check(T.contains(md, "# **EVIDENZIATI: 1**"), "render translates the count")

local mixed = render.buildBookMd({
    title = "Libro",
    count = 2,
    annotations = { { text = "X", chapter = "Capitolo I" }, { text = "Y" } },
}, { no_chapter_label = i18n("No chapter") })
T.check(T.contains(mixed, "\n# Senza capitolo"), "chapter label translated")

local index = render.buildIndexMd({
    { link = "B", title = "B", author = "A", count = 1, date = "01/01/2026" },
}, { title = i18n("Book index") })
T.check(T.contains(index, 'title: "Indice dei libri"'), "index title translated")
T.check(T.contains(index, "| Libro | Autore | Serie | Stato | Evidenziati | Ultimo export |"),
    "index header translated cell by cell")

setLang("en")
T.check(T.contains(render.buildIndexMd({}, {}), 'title: "Book index"'), "back to English")

-- 11. the same render instance sees the language change (no caching)
setLang("it")
T.check(T.contains(render.buildBookMd({
    title = "L", count = 1, annotations = { { text = "X" } },
}), "evidenziati"), "no catalog caching in render")

T.finish("test_i18n")
