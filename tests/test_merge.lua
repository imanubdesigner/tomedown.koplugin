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

-- the export behind preserve off carries no handles: overwrite never
-- parses, so a plain render still writes as it is
local bare = (rendered:gsub("<!%-%- tomedown:begin body[^\n]*%-%->\n", ""))
bare = (bare:gsub("<!%-%- tomedown:end body[^\n]*%-%->\n?", ""))
T.check(not T.contains(bare, "tomedown:begin")
        and not T.contains(bare, "tomedown:end"),
    "the plain render has no handles")
out, info = merge.apply(fresh, bare, fps, { mode = "overwrite" })
T.check(out == bare and info.reason == "overwrite",
    "overwrite never parses: a handleless render still writes")

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
T.check(info.backup == true, "the rebuild is flagged for a .bak")

-- the rebuild keeps a key only the user knows about
local legacyRated = legacy08:gsub("exported: 2026%-01%-01",
    "exported: 2026-01-01\nrating: 5")
out, info = merge.apply(legacyRated, rendered, fps, { mode = "preserve" })
T.check(info.reason == "legacy" and T.contains(out, "rating: 5"),
    "a rebuild keeps the user's front matter")

-- our own front matter without usable markers: rebuilt too
local mangled = '---\ntomedown: "1.0"\ntitle: "x"\n---\nmarkers deleted\n'
out, info = merge.apply(mangled, rendered, fps, { mode = "preserve" })
T.check(out == rendered and info.reason == "legacy",
    "mangled markers are rebuilt")

-- a file written with preserve off — no markers, no tag on the
-- heading: switching preserve on folds the reader's zone in on top of
-- the fresh render and keeps the plain file whole as .bak
local headed = renderBook(annB, { notes_title = "My notes..." })
local plain = (headed:gsub("<!%-%- tomedown:begin body[^\n]*%-%->\n", ""))
plain = (plain:gsub("<!%-%- tomedown:end body[^\n]*%-%->\n?", ""))
plain = (plain:gsub(" <!%-%- tomedown:notes %-%->", ""))
-- what the reader wrote after the last plain export
plain = plain:gsub("(## My notes%.%.%.\n\n\n)",
    "%1una nota scritta a mano.\n\n", 1)
T.check(not T.contains(plain, "tomedown:begin")
        and T.contains(plain, "## My notes...\n"),
    "the plain file carries no handles and a bare heading")
out, info = merge.apply(plain, headed, fps,
    { mode = "preserve", notes_title = "My notes..." })
T.check(info.reason == "merged",
    "the plain file folds in once preserve is on: " .. tostring(info.reason))
T.check(info.backup == true, "the plain file is kept as .bak")
T.check(select(2, out:gsub("una nota scritta a mano%.", "")) == 1,
    "the reader's note survives the transition")
T.check(select(2, out:gsub("## My notes%.%.%.", "")) == 1,
    "a single heading: the bare one is replaced by the tagged one")
T.check(select(2, out:gsub("# %*%*%d+ highlight", "")) == 1,
    "the old region is not duplicated")

-- the book moved on since the plain export: the zone still comes
-- across, up to the first region line the old export left behind
local moved = plain:gsub("Nuova frase%.", "Nuova frase e via.")
out, info = merge.apply(moved, headed, fps,
    { mode = "preserve", notes_title = "My notes..." })
T.check(info.reason == "merged" and info.backup == true,
    "the moved-on file merges with a .bak: " .. tostring(info.reason))
T.check(select(2, out:gsub("una nota scritta a mano%.", "")) == 1,
    "the reader's note survives even when the region changed")
T.check(select(2, out:gsub("Nuova frase%.", "")) == 1
        and not T.contains(out, "Nuova frase e via."),
    "the fresh region replaces the stale one")

local wrongStamp = rendered:gsub('tomedown: "1%.0"', 'tomedown: "0.9"')
out, info = merge.apply(wrongStamp, rendered, fps, { mode = "preserve" })
T.check(out == rendered and info.reason == "format",
    "a file stamped with another format version is regenerated")

-- the format rewrite keeps what the reader wrote around the block
local oldStamped = wrongStamp:gsub("highlights: 1",
    "highlights: 1\nrating: 5", 1)
    :gsub("(" .. BODY_BEGIN .. ")", "Appunto sotto l'heading.\n\n%1")
out, info = merge.apply(oldStamped, rendered, fps, { mode = "preserve" })
T.check(info.reason == "format", "the stale stamp still regenerates")
T.check(T.contains(out, "Appunto sotto l'heading."),
    "the format rewrite keeps the zone")
T.check(T.contains(out, "rating: 5") and T.contains(out, 'tomedown: "1.0"'),
    "the user's key and the new stamp join")

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

-- -------------------------------------- markers damaged while writing
-- the render's own text locates the region again: the zone, the front
-- matter and the heading all come across
local damaged = diskIntro:gsub("<!%-%- tomedown:begin body",
    "<! tomedown:begin body", 1)
out, info = merge.apply(damaged, rendered, fps, { mode = "preserve" })
T.check(info.reason == "merged", "a mangled begin marker still merges")
T.check(T.contains(out, "La mia introduzione scritta in Obsidian."),
    "the zone survives the mangled marker")
T.check(T.contains(out, "<!-- tomedown:begin body hash="),
    "the damaged marker line is repaired")

local removed = diskIntro:gsub("<!%-%- tomedown:begin body[^\n]*\n", "", 1)
out, info = merge.apply(removed, rendered, fps, { mode = "preserve" })
T.check(info.reason == "merged" and info.backup,
    "a deleted begin marker: the zone is recovered, the file is kept as .bak")
T.check(T.contains(out, "La mia introduzione scritta in Obsidian."),
    "the zone survives the deleted marker")

-- when no boundary can be found the rebuild keeps a .bak instead
local scrambled = diskIntro:gsub("# Capitolo I\n", "", 1)
    :gsub("<!%-%- tomedown:begin body[^\n]*\n", "", 1)
out, info = merge.apply(scrambled, rendered, fps, { mode = "preserve" })
T.check(info.reason == "legacy" and info.backup == true,
    "unlocatable content: rebuild with a .bak")

-- the tail cannot be told from a truncated end marker: rebuild too
local noEnd = diskIntro:gsub("<!%-%- tomedown:end body %-%->", "")
out, info = merge.apply(noEnd, rendered, fps, { mode = "preserve" })
T.check(info.reason == "legacy" and info.backup == true,
    "a missing end marker: rebuild with a .bak")

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
local oddFm = merge.mergeFrontmatter('broken\nline\nwithout key', renderedFm)
T.check(oddFm == renderedFm .. "\nbroken\nline\nwithout key",
    "an unplaceable line is kept verbatim instead of dropping the rest")

-- one odd line in the file's front matter: kept, not dropped
local oddDisk = rendered:gsub("highlights: 1",
    "highlights: 1\nrating : 5", 1)
out, info = merge.apply(oddDisk, rendered, fps, { mode = "preserve" })
T.check(info.reason == "merged" and T.contains(out, "rating : 5"),
    "an odd front matter line survives the merge")

-- ------------------------------------------- the notes heading (v1.0)
local rendered_h = renderBook(annB, { notes_title = "Le mie note" })
T.check(T.contains(rendered_h, "## Le mie note <!-- tomedown:notes -->"),
    "the render opens the zone with the heading")

-- a file from before the heading gains it above the marker
local out_h, info_h = merge.apply(fresh, rendered_h, fps,
    { mode = "preserve", notes_title = "Le mie note" })
T.check(info_h.reason == "merged" and #info_h.edited == 0, "plain merge")
T.check(out_h:find('---\n## Le mie note <!-- tomedown:notes -->\n\n\n'
        .. "<!-- tomedown:begin body", 1, true) ~= nil,
    "the heading joins above the marker, two blank lines under it")
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
T.check(zone_out:find('## Appunti miei <!-- tomedown:notes -->\n\n\n'
        .. "Scritto sotto il titolo.\n\n\n<!-- tomedown:begin body", 1, true)
        ~= nil,
    "heading first, two blank lines, the reader's line, two more")

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

-- ------------------------------------ the write zone (v1.0, no invite)
local INVITE = render.notesInvite()
local rendered_i = renderBook(annB, { notes_title = "Le mie note" })
local fps_zone = merge.fingerprints(merge.split(fresh))

-- an empty zone opens with the room alone: heading, then the blank
-- lines to write in — the invitation of older builds is never seeded
local roomy = merge.apply(fresh, rendered_i, fps_zone,
    { mode = "preserve", notes_title = "Le mie note" })
T.check(roomy:find('## Le mie note <!-- tomedown:notes -->\n\n\n'
        .. "<!-- tomedown:begin body", 1, true) ~= nil,
    "an empty zone opens with the room to write")
T.check(not T.contains(roomy, INVITE), "no invitation is seeded anymore")

-- a second merge of the same file changes nothing
local roomy2 = merge.apply(roomy, rendered_i, fps_zone,
    { mode = "preserve", notes_title = "Le mie note" })
T.check(roomy2 == roomy, "the room is idempotent")

-- the invitation an older build left behind drops at the merge, the
-- zone around it stays whole
local legacy = (roomy:gsub("(<!%-%- tomedown:begin body)",
    INVITE .. "\n\n%1", 1))
T.check(T.contains(legacy, INVITE), "the file on disk still carries it")
local cleaned = merge.apply(legacy, rendered_i, fps_zone,
    { mode = "preserve", notes_title = "Le mie note" })
T.check(not T.contains(cleaned, INVITE),
    "the invitation of older builds is dropped at the merge")
T.check(cleaned == roomy, "and the zone is back to the plain room")

-- what the reader wrote sits in the room and survives the merge, the
-- old invitation beside it notwithstanding
local written = roomy:gsub("(<!%-%- tomedown:begin body)",
    "Le mia prima riga.\n\n%1", 1)
local written_out = merge.apply(written, rendered_i, fps_zone,
    { mode = "preserve", notes_title = "Le mie note" })
T.check(written_out:find('## Le mie note <!-- tomedown:notes -->\n\n\n'
            .. "Le mia prima riga.\n\n\n<!-- tomedown:begin body", 1, true)
            ~= nil,
    "heading, room, the reader's line, room again")
local legacy_written = (written_out:gsub("(<!%-%- tomedown:begin body)",
    INVITE .. "\n\n%1", 1))
local kept = merge.apply(legacy_written, rendered_i, fps_zone,
    { mode = "preserve", notes_title = "Le mie note" })
T.check(not T.contains(kept, INVITE)
        and T.contains(kept, "Le mia prima riga."),
    "the invitation leaves, the reader's line stays")
local written_again = merge.apply(written_out, rendered_i, fps_zone,
    { mode = "preserve", notes_title = "Le mie note" })
T.check(written_again == written_out,
    "a written zone stays as it is")

-- overwrite mode writes the render as it is
local ow = merge.apply(roomy, rendered_i, fps_zone,
    { mode = "overwrite", notes_title = "Le mie note" })
T.check(ow == rendered_i, "overwrite ignores the file on disk")

-- adopted files open with the room, never with the invitation
local adopt_i = merge.apply("", rendered_i, nil,
    { mode = "preserve", notes_title = "Le mie note" })
T.check(T.contains(adopt_i, "## Le mie note <!-- tomedown:notes -->")
        and not T.contains(adopt_i, INVITE),
    "an empty adopted file opens with the room, without invitation")
local adopt_written = merge.apply("Solo appunti, senza marcatori.\n",
    rendered_i, nil,
    { mode = "preserve", notes_title = "Le mie note" })
T.check(T.contains(adopt_written, "Solo appunti, senza marcatori.")
        and not T.contains(adopt_written, INVITE),
    "an adopted file with writing keeps it")

-- a title of "" drops the heading and never writes the invitation
local nohead = merge.apply(fresh, rendered_i, fps_zone,
    { mode = "preserve", notes_title = "" })
T.check(not T.contains(nohead, "tomedown:notes")
        and not T.contains(nohead, INVITE),
    "no heading and no invitation: the room alone opens the zone")

T.finish("test_merge")
