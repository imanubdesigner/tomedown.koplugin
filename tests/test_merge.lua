-- tests for tomedown_merge.lua (pure module: render markers + md5)
local HERE = arg[0]:match("^(.*)/") or "."
package.path = HERE .. "/?.lua;" .. package.path
local T = require("common")
local render = require("tomedown_render")
local merge = require("tomedown_merge")

local function renderBook(annotations, opts)
    return render.buildBookMd({
        title = "Blackwater",
        author = "Michael McDowell",
        exported = "2026-09-26",
        count = #annotations,
        annotations = annotations,
    }, opts)
end

-- markers are literal text: escape Lua's magic characters to use them
-- as patterns (plain string.find would also do, but gsub needs it)
local function pat(s)
    return (s:gsub("([%%%^%$%(%)%.%[%]%*%+%-%?])", "%%%1"))
end

-- the begin marker as it sits on disk: with its hash and hint text
local BODY_BEGIN = "<!%-%- tomedown:begin body[^\n]*%-%->"

local annA = { { text = "Prima frase.", chapter = "Capitolo I", page = "10",
    date = "02/09/2026" } }
local annB = { { text = "Nuova frase.", chapter = "Capitolo I", page = "12",
    date = "03/09/2026" } }

-- ------------------------------------------------------------ split / join
local fresh = renderBook(annA)
local doc = merge.split(fresh)
T.check(doc ~= nil, "a fresh render splits")
T.check(merge.join(doc) == fresh, "join(split(x)) reproduces x byte for byte")

local idx = render.buildIndexMd({
    { link = "A - B", title = "B", author = "A", count = 1, date = "01/01/2026" },
}, { exported = "2026-10-04" })
local idoc = merge.split(idx)
T.check(idoc ~= nil, "the index splits")
T.check(merge.join(idoc) == idx, "index roundtrip")

T.check(merge.split("---\ntitle: \"x\"\n---\n\nno markers here\n") == nil,
    "a legacy file (no markers) does not split")
T.check(merge.split("no frontmatter at all") == nil, "no frontmatter: no split")
T.check(merge.split("---\ntitle: \"x\"\n---\n\n<!-- tomedown:begin a -->\ntext\n") == nil,
    "an unterminated region does not split")
T.check(merge.split("---\ntitle: \"x\"\n---\n\nonly zones\n") == nil,
    "frontmatter alone is not a marked document")

-- files written by older builds (short markers, no hint text) keep
-- parsing; join() rewrites them in the current format
local oldStyle = "---\ntomedown: \"1.0\"\ntitle: \"x\"\n---\n\n"
    .. "<!-- tomedown:begin preamble -->\nold body\n<!-- tomedown:end -->\n"
local odoc = merge.split(oldStyle)
T.check(odoc ~= nil and #odoc.blocks == 3 and odoc.blocks[2].name == "preamble"
    and odoc.blocks[2].text == "old body\n",
    "the older short markers still split")
T.check(merge.join(odoc):find(render.beginMarker("preamble"), 1, true) ~= nil
    and merge.join(odoc):find("<!-- tomedown:end -->", 1, true) == nil,
    "join() upgrades the markers to the current format")

-- ----------------------------------------------------------- fingerprints
local fps = merge.fingerprints(doc)
T.check(fps.body and not fps.index, "the book file has a single body fingerprint")
T.check(fps.body:match("^%x+$") and #fps.body == 32, "md5 hex digests")
local fpsB = merge.fingerprints(merge.split(renderBook(annB)))
T.check(fpsB.body ~= fps.body, "a new annotation changes the fingerprint")
T.check(next(merge.fingerprints(nil)) == nil, "no document: no fingerprints")

-- the marker's hash is the digest of the block it wraps
local marker_hash = fresh:match("<!%-%- tomedown:begin body hash=(%w+)")
T.check(marker_hash ~= nil, "the begin marker carries a hash")
T.check(marker_hash == render.digest(doc.blocks[2].text),
    "the hash is the digest of the block it wraps")
T.check(render.endMarker("body") == "<!-- tomedown:end body -->",
    "the end marker is plain")

-- ------------------------------------------------------------- apply basics
local rendered = renderBook(annB)
local out, info = merge.apply(fresh, rendered, fps, { mode = "overwrite" })
T.check(out == rendered and info.reason == "overwrite",
    "overwrite mode writes what was generated")

-- a file with no markers at all: its text becomes the zone above the
-- block, nothing of it is lost
out, info = merge.apply("Appunto scritto a mano.\n", rendered, fps,
    { mode = "preserve" })
T.check(info.reason == "adopt", "a note without markers is adopted")
T.check(T.contains(out, "Appunto scritto a mano."), "the note's text survives")
T.check(T.contains(out, "Nuova frase."), "the generated block joins in")
local zone_pos = out:find("Appunto scritto a mano.", 1, true)
local mark_pos = out:find("<!-- tomedown:begin body", 1, true)
T.check(zone_pos and mark_pos and zone_pos < mark_pos,
    "the note sits above the block")
out, info = merge.apply(out, rendered, fps, { mode = "preserve" })
T.check(info.reason == "merged" and #info.edited == 0,
    "the adopted file merges normally afterwards")

-- a v0.8 export: our front matter, no markers — rebuilt once
local legacy08 = table.concat({
    "---",
    'title: "Blackwater"',
    "exported: 2026-01-01",
    "highlights: 1",
    "tags:",
    "  - ebook",
    "  - highlights",
    "---",
    "",
    "> vecchio contenuto generato",
}, "\n")
out, info = merge.apply(legacy08, rendered, fps, { mode = "preserve" })
T.check(out == rendered and info.reason == "legacy",
    "a v0.8 export is rebuilt once, with markers")

-- our own front matter without usable markers: rebuilt too
local mangled = '---\ntomedown: "1.0"\ntitle: "x"\n---\nmarkers deleted\n'
out, info = merge.apply(mangled, rendered, fps, { mode = "preserve" })
T.check(out == rendered and info.reason == "legacy",
    "mangled markers are rebuilt")

local wrongStamp = rendered:gsub('tomedown: "1%.0"', 'tomedown: "0.9"')
out, info = merge.apply(wrongStamp, rendered, fps, { mode = "preserve" })
T.check(out == rendered and info.reason == "format",
    "a file stamped with another format version is regenerated")

local stamped = rendered:gsub('\ttomedown: "1%.0"\n', ""):gsub('tomedown: "1%.0"\n', "")
out, info = merge.apply(stamped, rendered, fps, { mode = "preserve" })
T.check(info.reason == "merged", "a missing stamp is not a blocker")

local renamed = rendered:gsub("tomedown:begin body", "tomedown:begin stale")
out, info = merge.apply(renamed, rendered, fps, { mode = "preserve" })
T.check(out == rendered and info.reason == "shape",
    "another region name is a format change: regenerate")

-- --------------------------------------------------------- zones are kept
local diskIntro = fresh:gsub("(" .. BODY_BEGIN .. ")",
    "La mia introduzione scritta in Obsidian.\n\n%1")
out, info = merge.apply(diskIntro, rendered, merge.fingerprints(
    merge.split(fresh)), { mode = "preserve" })
T.check(info.reason == "merged" and #info.edited == 0,
    "text outside the block is not an edit")
T.check(T.contains(out, "La mia introduzione scritta in Obsidian."),
    "the reader's zone survives")
T.check(T.contains(out, "Nuova frase.") and not T.contains(out, "Prima frase."),
    "the block takes the new annotations")

-- ------------------------------------------ a block the reader wrote inside
local diskEdited = fresh:gsub(
    "(" .. BODY_BEGIN .. "\n)", "%1Pensiero mio personale.\n")
local stored = merge.fingerprints(merge.split(fresh))

out, info = merge.apply(diskEdited, rendered, stored, { mode = "preserve" })
T.check(info.reason == "merged" and info.edited[1] == "body",
    "the line inside the block is detected as an edit")
T.check(info.backup == true, "the file is flagged for a .bak")
T.check(not T.contains(out, "Pensiero mio personale."),
    "the block is rebuilt: the line lives on only in the .bak")
T.check(T.contains(out, "Nuova frase."),
    "the rebuilt block takes the new annotations")

-- the rebuilt file is clean again on the next export
local kept_fps = merge.fingerprints(merge.split(rendered))
out, info = merge.apply(out, rendered, kept_fps, { mode = "preserve" })
T.check(info.reason == "merged" and #info.edited == 0 and not info.backup,
    "a rebuilt file needs no backup the next time")
T.check(T.contains(out, "Nuova frase."), "it updates normally")

-- markers written by older builds carry no hash: the stored
-- fingerprint decides, and without one nothing can be proven
local hashless = fresh:gsub(" hash=%w+", "")
T.check(hashless:find("tomedown:begin body", 1, true)
        and not hashless:find("hash=", 1, true),
    "the hashes are stripped from the markers")

out, info = merge.apply(hashless, rendered, stored, { mode = "preserve" })
T.check(info.reason == "merged" and #info.edited == 0,
    "an untouched hashless block stays ours")

local hlEdited = hashless:gsub("(" .. pat(render.beginMarker("body")) .. "\n)",
    "%1Pensiero\n")
T.check(hlEdited ~= hashless, "the hashless marker accepts a line too")
out, info = merge.apply(hlEdited, rendered, stored, { mode = "preserve" })
T.check(info.edited[1] == "body" and info.backup,
    "without a hash the stored fingerprint still catches the edit")
out, info = merge.apply(hlEdited, rendered, nil, { mode = "preserve" })
T.check(info.reason == "merged" and #info.edited == 0,
    "no hash and no fingerprint: the edit cannot be proven")
T.check(T.contains(out, "Nuova frase."),
    "the block is rebuilt either way")

-- ----------------------------------------- migrating the old layout
local old3 = table.concat({
    "---",
    'tomedown: "1.0"',
    'title: "Blackwater"',
    'author: "Michael McDowell"',
    "exported: 2026-09-26",
    "tags:",
    "  - ebook",
    "  - highlights",
    "---",
    "",
    "Introduzione scritta in Obsidian.",
    "",
    "<!-- tomedown:begin preamble -->",
    "",
    "---",
    "",
    "# **HIGHLIGHTS: 1**",
    "",
    "<!-- tomedown:end preamble -->",
    "",
    "<!-- tomedown:begin highlights -->",
    "",
    "> Prima frase.",
    "",
    "- **p. 10** · 02/09/2026",
    "",
    "<!-- tomedown:end highlights -->",
    "",
    "Appunto sotto gli highlight.",
    "",
    "<!-- tomedown:begin bookmarks -->",
    "<!-- tomedown:end bookmarks -->",
    "",
    "Nota in fondo al file.",
}, "\n")

local ofps = merge.fingerprints(merge.split(old3))
out, info = merge.apply(old3, rendered, ofps, { mode = "preserve" })
T.check(info.reason == "restructured", "the old three-region layout is migrated")
T.check(T.contains(out, "Introduzione scritta in Obsidian."),
    "the zone above the preamble stays above")
T.check(T.contains(out, "Appunto sotto gli highlight.")
        and T.contains(out, "Nota in fondo al file."),
    "the inner and tail zones are kept below")
T.check(T.contains(out, "Nuova frase.") and not T.contains(out, "Prima frase."),
    "the old generated content is replaced by the render")
T.check(not T.contains(out, "tomedown:begin preamble"),
    "the old markers are gone")
local inner_pos = out:find("Appunto sotto gli highlight.", 1, true)
local end_pos = out:find("<!-- tomedown:end body", 1, true)
T.check(inner_pos and end_pos and inner_pos > end_pos,
    "the old inner zones sit below the end marker")

-- an old region the reader had edited: only the .bak saves it
local old3Edited = old3:gsub(
    "(" .. pat("<!-- tomedown:begin highlights -->") .. "\n)",
    "%1Riga scritta a mano.\n")
out, info = merge.apply(old3Edited, rendered, ofps, { mode = "preserve" })
T.check(info.reason == "restructured" and info.backup
        and info.edited[1] == "highlights",
    "an edited old region is flagged for the .bak")

-- ------------------------------------------------------------ frontmatter
local diskFm = table.concat({
    'tomedown: "1.0"',
    'title: "Blackwater"',
    'status: "abandoned"',
    "exported: 2020-01-01",
    'language: "it"',
    "tags:",
    "  - ebook",
    "  - highlights",
    "  - my-tag",
    "rating: 5",
}, "\n")
local renderedFm = table.concat({
    'tomedown: "1.0"',
    'title: "Blackwater"',
    'status: "reading"',
    "exported: 2026-09-26",
    "tags:",
    "  - ebook",
    "  - highlights",
    "  - horror",
}, "\n")
local mfm = merge.mergeFrontmatter(diskFm, renderedFm)
T.check(T.contains(mfm, 'status: "reading"'), "the exporter owns status")
T.check(T.contains(mfm, "exported: 2026-09-26"), "the exporter owns exported")
T.check(T.contains(mfm, "  - my-tag"), "the user's tag is kept")
T.check(T.contains(mfm, "  - horror"), "the new keyword joins the tags")
T.check(T.contains(mfm, "rating: 5"), "a key only the user knows survives")
T.check(not T.contains(mfm, "language:"), "a key the exporter dropped is dropped")
local ipos, rpos = mfm:find("rating: 5"), mfm:find("exported: 2026")
T.check(ipos and rpos and rpos < ipos, "user keys come after the exporter's")
T.check(merge.mergeFrontmatter('broken\nline\nwithout key', renderedFm) == renderedFm,
    "malformed disk frontmatter: the rendered one wins")

-- ------------------------------------------- the notes heading (v1.0)
local rendered_h = renderBook(annB, { notes_title = "Le mie note" })
T.check(T.contains(rendered_h, "## Le mie note <!-- tomedown:notes -->"),
    "the render opens the zone with the heading")

-- a file from before the heading gains it above the marker
local out_h, info_h = merge.apply(fresh, rendered_h, fps,
    { mode = "preserve", notes_title = "Le mie note" })
T.check(info_h.reason == "merged" and #info_h.edited == 0, "plain merge")
T.check(out_h:find('---\n## Le mie note <!-- tomedown:notes -->\n\n'
        .. "<!-- tomedown:begin body", 1, true) ~= nil,
    "the heading joins above the marker")
T.check(T.contains(out_h, "Nuova frase."), "the block still rebuilds")

-- a renamed title lands at once, and only one heading ever stays
out_h = merge.apply(out_h, rendered_h,
    merge.fingerprints(merge.split(rendered_h)),
    { mode = "preserve", notes_title = "Appunti miei" })
local heads = select(2, out_h:gsub("tomedown:notes", ""))
T.check(heads == 1 and T.contains(out_h, "## Appunti miei <!-- tomedown:notes -->")
        and not T.contains(out_h, "Le mie note"),
    "the old heading is replaced, never doubled: " .. heads)

-- the reader's text in the zone keeps its place, right under the heading
local zoned_h = out_h:gsub("(" .. BODY_BEGIN .. ")",
    "Scritto sotto il titolo.\n%1")
local zone_out = merge.apply(zoned_h, rendered_h,
    merge.fingerprints(merge.split(rendered_h)),
    { mode = "preserve", notes_title = "Appunti miei" })
T.check(zone_out:find('## Appunti miei <!-- tomedown:notes -->\n\n'
        .. "Scritto sotto il titolo.\n\n<!-- tomedown:begin body", 1, true)
        ~= nil,
    "heading first, the reader's line below it")

-- a title of "" strips the heading, nil leaves the zone untouched
local no_title = merge.apply(out_h, rendered_h, fps,
    { mode = "preserve", notes_title = "" })
T.check(not T.contains(no_title, "tomedown:notes"),
    "an empty title exports the zone without heading")
local keep_title = merge.apply(fresh, rendered_h, fps, { mode = "preserve" })
T.check(not T.contains(keep_title, "tomedown:notes"),
    "without the option the zone keeps no heading")

-- adopted and migrated files get the heading too
local adopt_h = merge.apply("Appunto senza marcatori.\n", rendered_h, nil,
    { mode = "preserve", notes_title = "Le mie note" })
T.check(T.contains(adopt_h, "## Le mie note <!-- tomedown:notes -->"),
    "an adopted file gets the heading")
local apos, amark = adopt_h:find("Appunto senza marcatori.", 1, true),
    adopt_h:find("<!-- tomedown:begin body", 1, true)
T.check(apos and amark and apos < amark,
    "the adopted note sits under the heading")
local mig_h, mig_info_h = merge.apply(old3, rendered_h, ofps,
    { mode = "preserve", notes_title = "Le mie note" })
T.check(mig_info_h.reason == "restructured"
        and T.contains(mig_h, "## Le mie note <!-- tomedown:notes -->"),
    "the migrated file gets the heading")

T.finish("test_merge")
