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
T.check(i18n("Tags for this book") == "Tag per questo libro",
    "it: book tags dialog title")
T.check(i18n("Tags: %1") == "Tag: %1", "it: book tags row")
T.check(i18n("none") == "nessuno", "it: empty book tags")
T.check(i18n("Index order: %1") == "Ordine dell'indice: %1",
    "it: index order row")
T.check(i18n("Title") == "Titolo", "it: title order")

-- 4. explicit getter
T.check(i18n.gettext("Book index") == "Indice dei libri", "gettext() same as __call")

-- 5. regional variant it_IT -> falls back to it.po
setLang("it_IT")
T.check(i18n("Book index") == "Indice dei libri", "it_IT -> it.po")
setLang("it-IT")
T.check(i18n("Book index") == "Indice dei libri", "it-IT -> it.po")

-- 6. the four new catalogs
setLang("de")
T.check(i18n("Book index") == "Buchindex", "de: Book index")
T.check(i18n("No chapter") == "Kein Kapitel", "de: No chapter")
T.check(i18n("%1 files exported locally") == "%1 Dateien lokal exportiert",
    "de: notification with placeholder")
T.check(i18n("Check for updates (v%1)") == "Nach Updates suchen (v%1)",
    "de: check for updates row")

setLang("fr")
T.check(i18n("Book index") == "Index des livres", "fr: Book index")
T.check(i18n("No chapter") == "Sans chapitre", "fr: No chapter")
T.check(i18n("%1 files exported locally") == "%1 fichiers exportés localement",
    "fr: notification with placeholder")

setLang("es")
T.check(i18n("Book index") == "Índice de libros", "es: Book index")
T.check(i18n("No chapter") == "Sin capítulo", "es: No chapter")
T.check(i18n("%1 files exported locally") == "%1 archivos exportados localmente",
    "es: notification with placeholder")

setLang("pt_BR")
T.check(i18n("Book index") == "Índice de livros", "pt_BR: Book index")
T.check(i18n("No chapter") == "Sem capítulo", "pt_BR: No chapter")
T.check(i18n("%1 files exported locally") == "%1 arquivos exportados localmente",
    "pt_BR: notification with placeholder")

-- 7. regional variants fall back to the two-letter language
setLang("de_AT")
T.check(i18n("Book index") == "Buchindex", "de_AT -> de.po")
setLang("fr_CA")
T.check(i18n("No chapter") == "Sans chapitre", "fr_CA -> fr.po")
setLang("es_MX")
T.check(i18n("Book index") == "Índice de libros", "es_MX -> es.po")
setLang("pt_BR")
T.check(i18n("No chapter") == "Sem capítulo", "pt_BR -> pt_BR.po")

-- 8. a language without a translation file: msgid
setLang("nl")
T.check(i18n("Book index") == "Book index", "nl without po -> msgid")

-- 9. the index table is translated cell by cell now (v1.0.0: adaptive
-- columns, status word merged with the reading bar)
setLang("it")
T.check(i18n("Book") == "Libro", "it: cell Book")
T.check(i18n("Author") == "Autore", "it: cell Author")
T.check(i18n("Series") == "Serie", "it: cell Series")
T.check(i18n("Status") == "Stato", "it: cell Status")
T.check(i18n("Highlights") == "Evidenziati", "it: cell Highlights")
T.check(i18n("%1 special") == "%1 special", "it: special count")
T.check(i18n("Series books") == "Libri in serie", "it: heading series")
T.check(i18n("My books") == "I miei libri", "it: heading plain")
T.check(i18n("Cover") == "Copertina", "it: cell Cover")

-- 10. the language changes even after loading (reload)
setLang(nil)
T.check(i18n("Book index") == "Book index", "back to no language")
setLang("it")
T.check(i18n("Book index") == "Indice dei libri", "back in Italian")

-- 11. language read from G_reader_settings when GetText does not know it
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

-- 12. render uses the translations at runtime
setLang("it")
local render = require("tomedown_render")
local md = render.buildBookMd({
    title = "Libro",
    count = 1,
    annotations = { { text = "X" } },
})
T.check(T.contains(md, "evidenziati"), "render translates the highlights tag")
T.check(T.contains(md, "# **1 evidenziazione**"), "render translates the count")

local mixed = render.buildBookMd({
    title = "Libro",
    count = 2,
    annotations = { { text = "X", chapter = "Capitolo I" }, { text = "Y" } },
}, { no_chapter_label = i18n("No chapter") })
T.check(T.contains(mixed, "\n# Senza capitolo"), "chapter label translated")

local index = render.buildIndexMd({
    {
        link = "B", title = "B", author = "A", series = "S", status = "reading",
        count = 1, progress = "1%", last_read = "2026-01-01",
    },
}, { title = i18n("Book index") })
T.check(T.contains(index, 'title: "Indice dei libri"'), "index title translated")
T.check(T.contains(index,
    "| Libro | Autore | Serie | Stato | Ultima lettura | Evidenziati |"),
    "index header translated cell by cell")

setLang("en")
T.check(T.contains(render.buildIndexMd({}, {}), 'title: "Book index"'), "back to English")

-- 13. the same render instance sees the language change (no caching)
setLang("it")
T.check(T.contains(render.buildBookMd({
    title = "L", count = 1, annotations = { { text = "X" } },
}), "evidenziati"), "no catalog caching in render")

-- 14. the new catalogs reach the render too
setLang("de")
T.check(T.contains(render.buildBookMd({
    title = "B", count = 1, annotations = { { text = "X" } },
}), "# **1 Markierung**"), "de: render translates the count")
setLang("fr")
T.check(T.contains(render.buildBookMd({
    title = "L",
    count = 2,
    annotations = { { text = "X", chapter = "Chapitre I" }, { text = "Y" } },
}, { no_chapter_label = i18n("No chapter") }), "\n# Sans chapitre"),
    "fr: chapter label translated")
setLang("es")
T.check(T.contains(render.buildBookMd({
    title = "L", count = 1, annotations = { { text = "X" } },
}), "# **1 subrayado**"), "es: render translates the count")
setLang("pt_BR")
T.check(T.contains(render.buildBookMd({
    title = "L", count = 2, annotations = { { text = "X" }, { text = "Y" } },
}), "# **2 destaques**"), "pt_BR: render translates the count")

T.finish("test_i18n")
