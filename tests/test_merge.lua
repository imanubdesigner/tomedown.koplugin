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

-- ------------------------------------------------------------- apply basics
local rendered = renderBook(annB)
local out, info = merge.apply(fresh, rendered, fps, { mode = "overwrite" })
T.check(out == rendered and info.reason == "overwrite",
    "overwrite mode writes what was generated")

out, info = merge.apply("old file without markers\n", rendered, fps,
    { mode = "preserve", policy = "keep" })
T.check(out == rendered and info.reason == "legacy",
    "a legacy file is regenerated once, with its markers")

local wrongStamp = rendered:gsub('tomedown: "1%.0"', 'tomedown: "0.9"')
out, info = merge.apply(wrongStamp, rendered, fps, { mode = "preserve" })
T.check(out == rendered and info.reason == "format",
    "a file stamped with another format version is regenerated")

local stamped = rendered:gsub('\ttomedown: "1%.0"\n', ""):gsub('tomedown: "1%.0"\n', "")
out, info = merge.apply(stamped, rendered, fps, { mode = "preserve" })
T.check(info.reason == "merged", "a missing stamp is not a blocker")

local renamed = rendered:gsub(pat(render.beginMarker("body")),
    render.beginMarker("stale"))
out, info = merge.apply(renamed, rendered, fps, { mode = "preserve" })
T.check(out == rendered and info.reason == "shape",
    "another region name is a format change: regenerate")

-- --------------------------------------------------------- zones are kept
local diskIntro = fresh:gsub("(" .. pat(render.beginMarker("body")) .. ")",
    "La mia introduzione scritta in Obsidian.\n\n%1")
out, info = merge.apply(diskIntro, rendered, merge.fingerprints(
    merge.split(fresh)), { mode = "preserve", policy = "keep" })
T.check(info.reason == "merged" and #info.edited == 0,
    "text outside the regions is not an edit")
T.check(T.contains(out, "La mia introduzione scritta in Obsidian."),
    "the user's zone survives")
T.check(T.contains(out, "Nuova frase.") and not T.contains(out, "Prima frase."),
    "the untouched region takes the new annotations")

-- --------------------------------------------------- a region the user wrote in
local diskEdited = fresh:gsub(
    "(" .. pat(render.beginMarker("body")) .. "\n)",
    "%1Pensiero mio personale.\n")
local stored = merge.fingerprints(merge.split(fresh))

out, info = merge.apply(diskEdited, rendered, stored,
    { mode = "preserve", policy = "keep" })
T.check(info.reason == "merged" and info.edited[1] == "body"
    and info.kept[1] == "body", "the hand edit is detected and kept")
T.check(T.contains(out, "Pensiero mio personale."), "the user's line survives")
T.check(T.contains(out, "Prima frase.") and not T.contains(out, "Nuova frase."),
    "a kept region does not take the new annotations")

local skipped
skipped, info = merge.apply(diskEdited, rendered, stored,
    { mode = "preserve", policy = "skip" })
T.check(skipped == nil and info.reason == "skip" and info.edited[1] == "body",
    "skip policy: the file is not written, the caller warns")

-- the kept region stays the user's on the next export too
local kept_fps = merge.fingerprints(merge.split(rendered))
local out2, info2 = merge.apply(out, rendered, kept_fps,
    { mode = "preserve", policy = "keep" })
T.check(info2.edited[1] == "body" and T.contains(out2, "Pensiero mio personale."),
    "the kept region stays the user's until they restore it")

-- the user puts the generated content back by hand: under control again
local disk3 = rendered:gsub(
    "(" .. pat(render.beginMarker("body")) .. "\n)", "%1Pensiero\n")
local out3, info3 = merge.apply(disk3, rendered, kept_fps,
    { mode = "preserve", policy = "keep" })
T.check(info3.edited[1] == "body", "first export keeps the new line")
local restored = out3:gsub("Pensiero\n", "")
T.check(restored == rendered, "deleting the line restores the generated note")
local out4, info4 = merge.apply(restored, rendered, kept_fps,
    { mode = "preserve", policy = "keep" })
T.check(info4.reason == "merged" and #info4.edited == 0,
    "content equal to the render: not an edit anymore")
T.check(T.contains(out4, "Nuova frase."), "the restored region updates again")

-- no stored fingerprints (settings wiped): the region counts as ours,
-- otherwise a wipe would freeze every file forever
local wiped, winfo = merge.apply(diskEdited, rendered, nil,
    { mode = "preserve", policy = "keep" })
T.check(winfo.reason == "merged" and #winfo.edited == 0,
    "without fingerprints nothing is reported as edited")
T.check(wiped == rendered, "the generated note wins when we cannot prove an edit")

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

T.finish("test_merge")
