-- test di tomedown_render.lua (modulo quasi puro: solo tomedown_i18n)
local HERE = arg[0]:match("^(.*)/") or "."
package.path = HERE .. "/?.lua;" .. package.path
local T = require("common")
local render = require("tomedown_render")

local book = {
    title = "Blackwater",
    author = "Michael McDowell",
    exported = "2026-09-26",
    count = 2,
    annotations = {
        {
            text = "Prima frase.",
            note = "nota utente",
            chapter = "Capitolo I",
            page = "10",
            date = "02/09/2026",
        },
        {
            text = "Seconda riga.",
            chapter = "Capitolo II",
            page = "38",
            date = "03/09/2026",
        },
    },
}

local md = render.buildBookMd(book)
T.check(md:sub(1, 4) == "---\n", "frontmatter si apre con ---")
T.check(T.contains(md, 'title: "Blackwater"'), "frontmatter title")
T.check(T.contains(md, 'author: "Michael McDowell"'), "frontmatter author")
T.check(T.contains(md, "exported: 2026-09-26"), "frontmatter exported")
T.check(T.contains(md, "highlights: 2"), "frontmatter highlights")
T.check(T.contains(md, "  - kindle"), "tag kindle")
T.check(T.contains(md, "  - highlights"), "tag highlights")
T.check(T.contains(md, "# Blackwater"), "h1 con il titolo")
T.check(T.contains(md, "*Michael McDowell*"), "autore in corsivo")
T.check(T.contains(md, "**2 highlights**"), "conteggio evidenziati")
T.check(T.contains(md, "## Capitolo I"), "primo capitolo")
T.check(T.contains(md, "## Capitolo II"), "secondo capitolo")
T.check(T.contains(md, "> Prima frase."), "citazione 1")
T.check(T.contains(md, "> Seconda riga."), "citazione 2")
T.check(T.contains(md, "- **p. 10** · 02/09/2026 · note: nota utente"),
    "riga meta con pagina, data e nota")
T.check(T.contains(md, "- **p. 38** · 03/09/2026"), "riga meta senza nota")
local i10 = md:find("- **p. 10**", 1, true)
local i38 = md:find("- **p. 38**", 1, true)
T.check(i10 < i38, "gli evidenziati restano in ordine di pagina")
T.check(md:sub(-1) == "\n", "termina con a capo")
T.check(not T.contains(md, "cover"), "nessuna copertina nel markdown")
T.check(not T.contains(md, "![]("), "nessuna immagine nel markdown")

-- nessun capitolo: niente sezioni ##
local noChapters = render.buildBookMd({
    title = "Senza capitoli",
    count = 1,
    annotations = { { text = "Solo testo", page = "1" } },
})
T.check(not T.contains(noChapters, "\n## "), "senza capitoli non compaiono heading")

-- capitoli misti: le annotazioni senza capitolo usano l'etichetta passata
local mixed = render.buildBookMd({
    title = "Misto",
    count = 2,
    annotations = {
        { text = "A", chapter = "Capitolo I" },
        { text = "B" },
    },
}, { no_chapter_label = "Senza capitolo" })
T.check(T.contains(mixed, "## Capitolo I"), "capitolo presente")
T.check(T.contains(mixed, "## Senza capitolo"), "etichetta di fallback")
T.check(not T.contains(mixed, "\n## No chapter"), "nessun msgid inglese residuo")

-- nota multilinea appiattita su una riga
local multi = render.buildBookMd({
    title = "Note",
    count = 1,
    annotations = { { text = "X", note = "riga1\nriga2" } },
})
T.check(T.contains(multi, "note: riga1 riga2"), "nota multilinea su una riga")
T.check(not T.contains(multi, "note: riga1\n"), "la nota non spezza la riga meta")

-- nessuna pagina/data/nota: ellissi
local bare = render.buildBookMd({
    title = "Nudo",
    count = 1,
    annotations = { { text = "Y" } },
})
T.check(T.contains(bare, "- …"), "meta vuota con ellissi")

-- escaping YAML
local escaped = render.buildBookMd({
    title = 'Dice "ciao"\nalla fine',
    author = "A\\B",
    count = 0,
    annotations = {},
})
T.check(T.contains(escaped, 'title: "Dice \\"ciao\\" alla fine"'), "virgolette e a capo nel titolo")
T.check(T.contains(escaped, 'author: "A\\\\B"'), "backslash nell'autore")

-- ---------------------------------------------------------------- indice
local index = render.buildIndexMd({}, {})
T.check(T.contains(index, "# Book index"), "titolo di default dell'indice")
T.check(T.contains(index, "_No exported books with highlights._"), "indice vuoto")
T.check(T.contains(index, "  - index"), "tag index")
T.check(T.contains(index, "---\n"), "frontmatter indice")

local rows = render.buildIndexMd({
    {
        link = "Michael McDowell - Blackwater",
        title = "Blackwater",
        author = "Michael McDowell",
        count = 2,
        date = "26/09/2026",
    },
    {
        link = "Altro Autore - Altro",
        title = "Altro",
        author = "A | B",
        count = 0,
        date = "",
    },
}, { title = "Indice dei libri", exported = "2026-09-26" })

T.check(T.contains(rows, "# Indice dei libri"), "titolo dell'indice")
T.check(T.contains(rows, 'title: "Indice dei libri"'), "frontmatter indice")
T.check(T.contains(rows, "| Book | Author | Highlights | Last export |"), "header tabella")
T.check(T.contains(rows, "|:---|:---|---:|:---|"), "separatori tabella")
T.check(T.contains(rows, "[[Michael McDowell - Blackwater|Blackwater]]"), "wikilink con alias")
T.check(T.contains(rows, "| 2 | 26/09/2026 |"), "conteggio e data in riga")
T.check(T.contains(rows, "| A \\| B | 0 | — |"), "pipe escapate e data vuota")
local order = rows:find("[[Michael McDowell - Blackwater|Blackwater]]", 1, true)
local order2 = rows:find("[[Altro Autore - Altro|Altro]]", 1, true)
T.check(order < order2, "l'indice mantiene l'ordine dei libri ricevuti")

-- alias: niente caratteri che rompono il wikilink
local clean = render.alias("Titolo [x] #y | z ^w")
T.check(not clean:find("[", 1, true) and not clean:find("|", 1, true),
    "alias senza parentesi quadre o pipe")
T.check(not clean:find("%s%s"), "alias senza spazi doppi")
T.check(render.alias("") == "", "alias vuoto")
T.check(render.alias(nil) == "", "alias nil")

-- titolo con pipe: l'alias dell'indice resta valido
local pipeIndex = render.buildIndexMd({
    { link = "Base", title = "A | B", author = "Aut", count = 1, date = "01/01/2026" },
})
local line = pipeIndex:match("| %[[^\n]+")
T.check(line and T.contains(line, "[[Base|A B]]"),
    "titolo con pipe: l'alias resta un solo wikilink valido")
T.check(line and line:gsub("[^|]", "") == "||||||",
    "la riga ha il numero giusto di colonne")

-- fmtDate
T.check(render.fmtDate("2026-09-02 10:00:00") == "02/09/2026", "data ISO in formato italiano")
T.check(render.fmtDate("2026-12-31") == "31/12/2026", "data senza ora")
T.check(render.fmtDate("01/02/2026") == "01/02/2026", "data già formattata passa invariata")
T.check(render.fmtDate(nil) == "", "data nil vuota")
T.check(render.fmtDate(42) == "", "data non stringa vuota")

T.finish("test_render")
