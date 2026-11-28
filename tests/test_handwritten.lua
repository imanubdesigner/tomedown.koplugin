--[[--
Tests for tomedown_handwritten: vector stroke-to-SVG serialization,
sidecar `.sdr` scanning (`pencil.koplugin` and `stylus-annotations`),
drawing extraction, folder migration, cloud cleanup, and Markdown/Digest/TXT
rendering of freehand annotations.
--]]
local HERE = arg[0]:match("^(.*)/") or "."
package.path = HERE .. "/?.lua;" .. package.path
local T = require("common")

local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local Handwritten = require("tomedown_handwritten")
local render = require("tomedown_render")
local merge = require("tomedown_merge")
local shared = require("tomedown_shared")
local Export = require("tomedown_export")

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
    flush = function() end,
}

local WORK = DataStorage:getSettingsDir() .. "/test_handwritten_work"
local BOOKS_DIR = WORK .. "/books"
local VAULT_DIR = WORK .. "/vault"

local function writeBytes(path, bytes)
    local dir = path:match("^(.*)/[^/]+$")
    if dir then
        util.makePath(dir)
    end
    local f = assert(io.open(path, "wb"))
    f:write(bytes)
    f:close()
end

-- ---------------------------------------------------------------------------
-- 1. Pure Lua vector stroke-to-SVG serializer
-- ---------------------------------------------------------------------------
do
    T.check(Handwritten.renderStrokesToSvg(nil) == nil, "nil strokes -> nil")
    T.check(Handwritten.renderStrokesToSvg({}) == nil, "empty strokes -> nil")

    -- Multi-stroke with {x,y} tables, array pairs, custom width and color, and single-point dot
    local strokes = {
        {
            points = { { x = 100, y = 200 }, { x = 150, y = 220 }, { x = 180, y = 260 } },
            width = 3,
            color = "#112233",
        },
        {
            { 120, 210 }, { 140, 250 },
        },
        {
            points = { { x = 130, y = 230 } },
            width = 4,
            color = "#cc0000",
        },
    }
    local svg = Handwritten.renderStrokesToSvg(strokes)
    T.check(type(svg) == "string" and T.contains(svg, "<svg "), "SVG header generated")
    T.check(T.contains(svg, 'M 100 200 L 150 220 L 180 260'), "first path serialized")
    T.check(T.contains(svg, 'stroke="#112233"') and T.contains(svg, 'stroke-width="3"'),
        "custom color and stroke width preserved")
    T.check(T.contains(svg, 'M 120 210 L 140 250'), "array-pair stroke serialized")
    T.check(T.contains(svg, '<circle cx="130" cy="230" r="2" fill="#cc0000"/>'),
        "single-point stroke serialized as circle")
    T.check(T.contains(svg, "</svg>"), "SVG closed cleanly")

    -- Explicit canvas dimensions
    local fixed_svg = Handwritten.renderStrokesToSvg(strokes, 800, 1200)
    T.check(T.contains(fixed_svg, 'viewBox="0 0 800 1200" width="800" height="1200"'),
        "explicit canvas dimensions respected")
end

-- ---------------------------------------------------------------------------
-- 2. Sidecar `.sdr` detection (`pencil.koplugin` PNGs + bookmarks + stylus strokes)
-- ---------------------------------------------------------------------------
do
    util.makePath(BOOKS_DIR)
    util.makePath(VAULT_DIR)
    local book_path = BOOKS_DIR .. "/LibraColour.epub"
    local sdr_dir = book_path .. ".sdr"
    util.makePath(sdr_dir .. "/pencil")

    local fake_png_1 = "\137PNG\r\n\26\npencil_page_12"
    local fake_png_2 = "\137PNG\r\n\26\npencil_page_45"
    writeBytes(sdr_dir .. "/pencil_p12.png", fake_png_1)
    writeBytes(sdr_dir .. "/pencil/note_page_45.png", fake_png_2)

    T.check(Handwritten.getSidecarDir(book_path) == sdr_dir,
        "getSidecarDir locates book.epub.sdr")
    T.check(Handwritten.isPencilBookmarkNote("Pencil annotation on page 12") == true,
        "isPencilBookmarkNote recognizes pencil.koplugin bookmark note")
    T.check(Handwritten.isPencilBookmarkNote("Normal user bookmark") == false,
        "isPencilBookmarkNote ignores normal bookmark note")

    local raw_annotations = {
        -- Standard text highlight on page 10
        {
            drawer = "lighten",
            text = "A standard highlighted passage.",
            chapter = "Chapter I",
            pageno = 10,
            pageref = "10",
            datetime = "2026-11-16 09:00:00",
        },
        -- pencil.koplugin bookmark on page 12 matching pencil_p12.png
        {
            page = "/body/DocFragment[2]/body/p[4]",
            pageno = 12,
            pageref = "12",
            chapter = "Chapter I",
            note = "Pencil annotation on page 12",
            datetime = "2026-11-16 09:15:00",
        },
        -- Normal page bookmark on page 20
        {
            page = "/body/DocFragment[3]/body/p[1]",
            pageno = 20,
            pageref = "20",
            note = "Remember this character",
            datetime = "2026-11-16 09:20:00",
        },
    }

    local mock_ds = {
        readSetting = function(_, key)
            if key == "stylus_annotations" then
                return {
                    {
                        pageno = 30,
                        chapter = "Chapter II",
                        datetime = "2026-11-16 09:30:00",
                        note = "Margin arrow & star",
                        strokes = {
                            { { 10, 10 }, { 50, 50 }, { 90, 10 } },
                        },
                    },
                }
            end
            return nil
        end,
    }

    local collected = Handwritten.collect(book_path, mock_ds, raw_annotations)
    T.check(#collected == 3, "collected 3 handwritten items (1 matched bm PNG + 1 vector stroke + 1 unmatched pencil subfolder PNG): got " .. #collected)

    local cleaned_hl = Export:cleanAnnotations(raw_annotations)
    T.check(#cleaned_hl == 1 and cleaned_hl[1].text == "A standard highlighted passage.",
        "cleanAnnotations keeps only the text highlight")

    local cleaned_hw = Export:cleanHandwritten(book_path, mock_ds, raw_annotations)
    T.check(#cleaned_hw == 3, "cleanHandwritten produces 3 normalized handwritten items")
    T.check(cleaned_hw[1].handwritten == true and cleaned_hw[1].page == "12"
            and cleaned_hw[1].drawing_ext == "png",
        "first handwritten item is page 12 PNG")
    T.check(cleaned_hw[2].handwritten == true and cleaned_hw[2].page == "30"
            and cleaned_hw[2].drawing_ext == "svg"
            and cleaned_hw[2].note == "Margin arrow & star",
        "second handwritten item is page 30 vector SVG with user note")
    T.check(cleaned_hw[3].handwritten == true and cleaned_hw[3].page == "45"
            and cleaned_hw[3].drawing_ext == "png",
        "third handwritten item is page 45 PNG from pencil/ subfolder")

    -- cleanBookmarks skips the pencil bookmark when skip_pencil_notes is true, keeping normal bookmarks
    local bms = Export:cleanBookmarks(raw_annotations, true)
    T.check(#bms == 1 and bms[1].text == "Remember this character",
        "cleanBookmarks drops the auto-generated pencil bookmark and keeps user page bookmarks")

    -- Combine highlights + handwritten and extract drawings into vault
    local all_anns = { cleaned_hl[1], cleaned_hw[1], cleaned_hw[2], cleaned_hw[3] }
    local mock_book = {
        title = "The Colour Notebook",
        author = "Kobo Writer",
        base = "Kobo Writer - The Colour Notebook",
        exported = "2026-11-16",
        count = #all_anns,
        annotations = all_anns,
        bookmarks = bms,
    }
    local written_files = Handwritten.ensureDrawings(mock_book, VAULT_DIR, "drawings")
    T.check(#written_files == 3, "ensureDrawings writes 3 files into vault/drawings")
    for __, wf in ipairs(written_files) do
        T.check(lfs.attributes(wf, "mode") == "file", "drawing file exists on disk: " .. wf)
    end
    T.check(all_anns[2].drawing == "drawings/Kobo Writer - The Colour Notebook - p12-1.png",
        "relative drawing path set on page 12 item")
    T.check(all_anns[3].drawing == "drawings/Kobo Writer - The Colour Notebook - p30-1.svg",
        "relative SVG drawing path set on page 30 item")

    -- Subfolder layout (e.g. author/Book.md) prefixes "../" to book-local drawing link while keeping vault_rel
    local subdir_book = {
        base = "Kobo Writer/Kobo Writer - The Colour Notebook",
        annotations = {
            {
                handwritten = true,
                drawing_id = "p12-1",
                drawing_ext = "png",
                drawing_source = sdr_dir .. "/pencil_p12.png",
            },
        },
    }
    Handwritten.ensureDrawings(subdir_book, VAULT_DIR, "drawings")
    T.check(subdir_book.annotations[1].drawing == "../drawings/Kobo Writer - The Colour Notebook - p12-1.png"
            and subdir_book.annotations[1].drawing_vault_rel == "drawings/Kobo Writer - The Colour Notebook - p12-1.png",
        "subfolder layout uses ../drawings/ for book note and drawings/ for root digest")

    -- Render Book Markdown (Standard Markdown image embed + block IDs + Keep my notes merge)
    local md = render.buildBookMd(mock_book, {
        markers = true,
        block_ids = true,
        notes_title = "My notes...",
    })
    T.check(T.contains(md, "![Handwritten note · p. 12](drawings/Kobo%20Writer%20-%20The%20Colour%20Notebook%20-%20p12-1.png) ^hl-"),
        "Book Markdown embeds standard Markdown image with URL-encoded path and block ID")
    T.check(T.contains(md, "![Handwritten note · p. 30](drawings/Kobo%20Writer%20-%20The%20Colour%20Notebook%20-%20p30-1.svg) ^hl-"),
        "Book Markdown embeds SVG stroke drawing")
    T.check(T.contains(md, "- **p. 12** · 16 Nov 2026 | 09:15 · ✍️ Handwritten note"),
        "Book Markdown metadata line includes stylus marker")
    T.check(T.contains(md, "**Note** — *Margin arrow & star*"),
        "Book Markdown includes user note attached to stylus drawing")

    -- Keep my notes preservation across re-exports
    local edited = md:gsub("# My notes%.%.%. <!%-%- tomedown:notes %-%->\n\n",
        "# My notes... <!-- tomedown:notes -->\nMy personal reflection on the sketch.\n\n", 1)
    local merged = merge.apply(edited, md, merge.fingerprints(merge.split(md)), {
        mode = "preserve",
        notes_title = "My notes...",
    })
    T.check(T.contains(merged, "My personal reflection on the sketch.")
            and T.contains(merged, "![Handwritten note · p. 12]"),
        "Keep my notes preserves user notes alongside handwritten embeds")

    -- Render Reading Digest Markdown
    local digest_md = render.buildDigestMd({
        {
            link = mock_book.base,
            title = mock_book.title,
            author = mock_book.author,
            annotations = mock_book.annotations,
        },
    }, {
        title = "Reading digest",
        exported = "2026-11-16",
    })
    T.check(T.contains(digest_md, "![Handwritten note · p. 12](drawings/Kobo%20Writer%20-%20The%20Colour%20Notebook%20-%20p12-1.png)")
            and T.contains(digest_md, "✍️ Handwritten note"),
        "Reading Digest embeds handwritten drawing and stylus badge")

    -- Render Plain Text (.txt)
    local txt = render.buildBookTxt(mock_book, {})
    T.check(T.contains(txt, "✍️ Handwritten note")
            and T.contains(txt, "NOTE: Margin arrow & star"),
        "Plain text export includes stylus marker and note")

    -- Folder migration (drawings -> attachments)
    local migrated = Handwritten.migrateFolder(VAULT_DIR, "drawings", "attachments")
    T.check(migrated == true
            and lfs.attributes(VAULT_DIR .. "/attachments", "mode") == "directory"
            and lfs.attributes(VAULT_DIR .. "/drawings", "mode") == nil,
        "migrateFolder moves drawings to attachments and removes old folder")

    -- Cloud upload cleanup
    local attach_files = {
        VAULT_DIR .. "/attachments/Kobo Writer - The Colour Notebook - p12-1.png",
        VAULT_DIR .. "/attachments/Kobo Writer - The Colour Notebook - p30-1.svg",
        VAULT_DIR .. "/attachments/Kobo Writer - The Colour Notebook - p45-1.png",
    }
    local deleted_count = Handwritten.deleteUploaded(attach_files, VAULT_DIR, "attachments")
    T.check(deleted_count == 3
            and lfs.attributes(attach_files[1], "mode") == nil,
        "deleteUploaded removes transferred drawing files from local buffer")
end

-- ---------------------------------------------------------------------------
-- 3. Settings helpers (getDrawingsFolder, setDrawingsFolder, getIncludeHandwritten)
-- ---------------------------------------------------------------------------
do
    store = {}
    T.check(shared.getDrawingsFolder() == "drawings", "default drawings folder is 'drawings'")
    shared.setDrawingsFolder("  /my_sketches/ ")
    T.check(shared.getDrawingsFolder() == "my_sketches", "custom drawings folder sanitized and saved")
    shared.setDrawingsFolder("  \\assets\\drawings/ ")
    T.check(shared.getDrawingsFolder() == "assets/drawings", "nested drawings folder with backslashes normalized to POSIX")
    shared.setDrawingsFolder("a/b/c/d/e")
    T.check(shared.getDrawingsFolder() == "a/b/c", "nested drawings folder capped at 3 levels")
    shared.setDrawingsFolder("../../assets/drawings")
    T.check(shared.getDrawingsFolder() == "assets/drawings", "parent traversal segments stripped safely")
    shared.setDrawingsFolder("drawings")
    T.check(store.tomedown.drawings_folder == nil, "setting default folder clears key to nil")

    -- Nested drawings migration edge cases: flat -> nested, parent -> child, child -> parent, nested -> flat (prunes empty parent)
    local function putFile(p, c)
        local fh = assert(io.open(p, "wb"))
        fh:write(c)
        fh:close()
    end
    local MIG_DIR = VAULT_DIR .. "_mig"
    T.rmrf(MIG_DIR)
    os.execute('mkdir -p "' .. MIG_DIR .. '/drawings"')
    putFile(MIG_DIR .. "/drawings/s1.svg", "<svg/>")
    putFile(MIG_DIR .. "/drawings/s2.jpeg", "JPEGDATA")
    T.check(Handwritten.migrateFolder(MIG_DIR, "drawings", "assets/drawings") == true
            and T.fileExists(MIG_DIR .. "/assets/drawings/s1.svg")
            and T.fileExists(MIG_DIR .. "/assets/drawings/s2.jpeg")
            and lfs.attributes(MIG_DIR .. "/drawings", "mode") == nil,
        "handwritten migrateFolder moves .svg and .jpeg from drawings -> assets/drawings")
    T.check(Handwritten.migrateFolder(MIG_DIR, "assets/drawings", "assets") == true
            and T.fileExists(MIG_DIR .. "/assets/s1.svg")
            and lfs.attributes(MIG_DIR .. "/assets/drawings", "mode") == nil,
        "handwritten migrateFolder moves child -> parent (assets/drawings -> assets) without deleting assets/")
    T.check(Handwritten.migrateFolder(MIG_DIR, "assets", "assets/drawings") == true
            and T.fileExists(MIG_DIR .. "/assets/drawings/s1.svg")
            and not T.fileExists(MIG_DIR .. "/assets/s1.svg"),
        "handwritten migrateFolder moves parent -> child (assets -> assets/drawings) and returns true")
    T.check(Handwritten.migrateFolder(MIG_DIR, "assets/drawings", "drawings") == true
            and T.fileExists(MIG_DIR .. "/drawings/s1.svg")
            and lfs.attributes(MIG_DIR .. "/assets", "mode") == nil,
        "handwritten migrateFolder nested -> flat prunes empty parent assets/")
    T.rmrf(MIG_DIR)

    T.check(shared.getIncludeHandwritten() == true, "include_handwritten is enabled by default")
    shared.setBookStyleOverride("/book.epub", "include_handwritten", false)
    T.check(shared.getIncludeHandwritten("/book.epub") == false
            and shared.getIncludeHandwritten("/other.epub") == true,
        "per-book include_handwritten override works independently")
    shared.clearBookStyleOverrides("/book.epub")
end

-- ---------------------------------------------------------------------------
-- 4. InkAway (`ink-away.koplugin`) support: PDF paging, shapes, alpha/RGB,
--    text ops, mutation digest, `.old` fallback, sandbox, EPUB rolling & notebooks
-- ---------------------------------------------------------------------------
do
    local INK_WORK = WORK .. "/inkaway"
    T.rmrf(INK_WORK)
    util.makePath(INK_WORK .. "/books")
    util.makePath(INK_WORK .. "/vault")

    -- 4a. PDF (`paging`) with ONLY InkAway annotations (no KOReader text highlights)
    local pdf_path = INK_WORK .. "/books/LinearAlgebra.pdf"
    local pdf_sdr = pdf_path .. ".sdr"
    util.makePath(pdf_sdr)

    local inkaway_pdf_v1 = [[return {
        ["version"]=1,
        ["items"]={
            {
                ["op"]={["kind"]="ink",["width"]=3,["alpha"]=255,["color"]={210,45,30,},["pts"]={0,0,40,12,85,5,},},
                ["a"]={["page"]=7,["x"]=120,["y"]=240,},
            },
            {
                ["op"]={["kind"]="ink",["width"]=14,["alpha"]=90,["color"]={255,220,0,},["pts"]={0,0,110,0,},},
                ["a"]={["page"]=7,["x"]=115,["y"]=255,},
            },
            {
                ["op"]={["kind"]="shape",["shape"]="rect",["fill"]=false,["width"]=2,["alpha"]=255,["color"]={30,90,200,},["pts"]={0,0,90,40,},},
                ["a"]={["page"]=7,["x"]=110,["y"]=230,},
            },
            {
                ["op"]={["kind"]="shape",["shape"]="line",["arrow"]="end",["width"]=2,["pts"]={0,0,50,30,},},
                ["a"]={["page"]=7,["x"]=210,["y"]=250,},
            },
            {
                ["op"]={["kind"]="erase",["width"]=20,["pts"]={0,0,30,30,},},
                ["a"]={["page"]=7,["x"]=600,["y"]=600,},
            },
            {
                ["op"]={["kind"]="ink",["hidden"]=true,["width"]=4,["pts"]={0,0,70,70,},},
                ["a"]={["page"]=7,["x"]=700,["y"]=700,},
            },
            {
                ["op"]={["kind"]="text",["x"]=0,["y"]=0,["paras"]={{["spans"]={{["t"]="Key theorem",},},},},},
                ["a"]={["page"]=7,["x"]=120,["y"]=280,},
            },
            {
                ["op"]={["kind"]="shape",["shape"]="ellipse",["fill"]=true,["width"]=2,["color"]={40,160,80,},["pts"]={0,0,24,24,},},
                ["a"]={["page"]=19,["x"]=60,["y"]=300,},
            },
        },
    }]]
    writeBytes(pdf_sdr .. "/inkaway.lua", inkaway_pdf_v1)

    local pdf_hw = Export:cleanHandwritten(pdf_path, nil, nil)
    T.check(#pdf_hw == 2,
        "4a: InkAway PDF collects 2 page annotations (p. 7 and p. 19): got " .. tostring(#pdf_hw))
    T.check(pdf_hw[1] and pdf_hw[1].page == "7" and pdf_hw[1].drawing_ext == "svg"
            and pdf_hw[1].note == "Key theorem",
        "4a: page 7 InkAway item has page '7', svg ext, and extracted text-box note")
    T.check(pdf_hw[2] and pdf_hw[2].page == "19" and pdf_hw[2].drawing_ext == "svg",
        "4a: page 19 InkAway item has page '19' and svg ext")

    local pdf_book = {
        title = "Linear Algebra",
        author = "Gilbert Strang",
        base = "Gilbert Strang - Linear Algebra",
        exported = "2026-11-26",
        count = #pdf_hw,
        annotations = pdf_hw,
        bookmarks = {},
    }
    local pdf_written = Handwritten.ensureDrawings(pdf_book, INK_WORK .. "/vault", "drawings")
    T.check(#pdf_written == 2, "4a: ensureDrawings writes 2 InkAway SVG files")

    local p7_svg = T.readFile(pdf_written[1] or "") or ""
    T.check(T.contains(p7_svg, "M 120 240 L 160 252 L 205 245"),
        "4a: page 7 freehand stroke translated by anchor (a.x, a.y)")
    T.check(T.contains(p7_svg, 'stroke="#d22d1e"'),
        "4a: InkAway {r,g,b} color converted to hex #d22d1e")
    T.check(T.contains(p7_svg, 'opacity="0.35"'),
        "4a: InkAway alpha=90 marker stroke rendered with SVG opacity")
    T.check(T.contains(p7_svg, "M 110 230 L 200 230 L 200 270 L 110 270 Z"),
        "4a: InkAway rect shape rendered as closed SVG path")
    T.check(not T.contains(p7_svg, "600") and not T.contains(p7_svg, "700"),
        "4a: erase and hidden ops excluded from SVG")

    local p19_svg = T.readFile(pdf_written[2] or "") or ""
    T.check(T.contains(p19_svg, 'fill="#28a050"') and T.contains(p19_svg, " Z\""),
        "4a: InkAway filled ellipse rendered as closed filled SVG path")

    -- 4b. Adding a new stroke on page 7 updates drawing_digest and overwrites SVG while keeping drawing_id stable
    local old_id = pdf_hw[1].drawing_id
    local old_digest = pdf_hw[1].drawing_digest
    local inkaway_pdf_v2 = inkaway_pdf_v1:gsub(
        '%["items"%]=%{',
        '["items"]={{["op"]={["kind"]="ink",["width"]=2,["pts"]={0,0,25,25,},},["a"]={["page"]=7,["x"]=140,["y"]=260,},},',
        1)
    writeBytes(pdf_sdr .. "/inkaway.lua", inkaway_pdf_v2)
    local pdf_hw_v2 = Export:cleanHandwritten(pdf_path, nil, nil)
    T.check(pdf_hw_v2[1].drawing_id == old_id
            and pdf_hw_v2[1].drawing_digest ~= nil
            and pdf_hw_v2[1].drawing_digest ~= old_digest,
        "4b: adding stroke on same PDF page preserves drawing_id (block ID stability) while changing drawing_digest")
    pdf_book.annotations = pdf_hw_v2
    Handwritten.ensureDrawings(pdf_book, INK_WORK .. "/vault", "drawings")
    local p7_svg_v2 = T.readFile(pdf_written[1] or "") or ""
    T.check(T.contains(p7_svg_v2, "M 140 260 L 165 285"),
        "4b: ensureDrawings updates existing SVG file on disk when strokes change")

    -- 4c. Sandbox safety, split-function (>65k constants) chunk format, and `.old` backup fallback
    local sec_book = INK_WORK .. "/books/Sandbox.pdf"
    local sec_sdr = sec_book .. ".sdr"
    util.makePath(sec_sdr)
    writeBytes(sec_sdr .. "/inkaway.lua", 'os.execute("touch ' .. INK_WORK .. '/pwned"); return { items = {} }')
    writeBytes(sec_sdr .. "/inkaway.lua.old",
        'return (function() local t={}; (function() t["version"]=1; t["items"]={{["op"]={["kind"]="ink",["width"]=2,["pts"]={0,0,10,10}},["a"]={["page"]=3,["x"]=5,["y"]=5}}}; end)(); return t end)()')
    local sec_hw = Export:cleanHandwritten(sec_book, nil, nil)
    T.check(lfs.attributes(INK_WORK .. "/pwned", "mode") == nil,
        "4c: sandbox blocks global access in tampered inkaway.lua")
    T.check(#sec_hw == 1 and sec_hw[1].page == "3",
        "4c: falls back to inkaway.lua.old and decodes InkAway split-function format")

    -- 4d. EPUB rolling anchors (xp0 + pinned pg) + linked `.inkaway` notebook (highlight note + chapter note)
    local epub_path = INK_WORK .. "/books/ReflowBook.epub"
    local epub_sdr = epub_path .. ".sdr"
    local nb_path = INK_WORK .. "/Book notes/ReflowBook.inkaway"
    util.makePath(epub_sdr)
    writeBytes(nb_path, [[return {
        ["v"]=2,["w"]=600,["h"]=800,
        ["pages"]={
            {
                ["title"]="Chapter I",
                ["book"]={["toc"]=1,},
                ["ops"]={
                    {["kind"]="ink",["width"]=2.5,["pts"]={10,20,60,40,},},
                },
            },
            {
                ["title"]="“Important quote”",
                ["book"]={["toc"]=1,["hl"]={["dt"]="2026-11-20 14:00:00",["pos0"]="/body/DocFragment[2]/body/p[3]/text().0",},},
                ["ops"]={
                    {["kind"]="ink",["width"]=3,["color"]={180,20,90,},["pts"]={15,15,45,35,80,15,},},
                },
            },
        },
    }]])
    writeBytes(epub_sdr .. "/inkaway.lua", string.format([[return {
        ["version"]=1,
        ["notes"]=%q,
        ["hl_notes"]={["2026-11-20 14:00:00"]="(Handwritten note)",},
        ["items"]={
            {
                ["op"]={["kind"]="ink",["width"]=2,["pts"]={0,0,30,10,},},
                ["a"]={["xp0"]="/body/DocFragment[2]/body/p[1]/text().0",["xp1"]="/body/DocFragment[2]/body/p[1]/text().5",["dx"]=12,["dy"]=-4,},
            },
            {
                ["op"]={["kind"]="ink",["width"]=2,["pts"]={0,0,20,8,},},
                ["a"]={["xp0"]="/body/DocFragment[2]/body/p[1]/text().0",["xp1"]="/body/DocFragment[2]/body/p[1]/text().5",["dx"]=50,["dy"]=-4,},
            },
            {
                ["op"]={["kind"]="ink",["width"]=2,["pts"]={0,0,40,40,},},
                ["a"]={["pg"]=22,["fx"]=0.25,["fy"]=0.5,},
            },
        },
    }]], nb_path))

    local epub_raw = {
        {
            drawer = "lighten",
            text = "Important quote",
            note = "(Handwritten note)",
            chapter = "Chapter I",
            page = "/body/DocFragment[2]/body/p[3]/text().0",
            pos0 = "/body/DocFragment[2]/body/p[3]/text().0",
            pos1 = "/body/DocFragment[2]/body/p[3]/text().15",
            pageno = 11,
            pageref = "11",
            datetime = "2026-11-20 14:00:00",
        },
    }
    local mock_doc = {
        getPageFromXPointer = function(_, xp)
            if xp:find("p%[1%]") then return 9 end
            if xp:find("p%[3%]") then return 11 end
            return nil
        end,
    }
    local epub_hw = Export:cleanHandwritten(epub_path, nil, epub_raw, mock_doc)
    T.check(#epub_hw == 4,
        "4d: EPUB collects 4 InkAway items (grouped xp0 margin note, pinned pg=22, chapter notebook page, highlight notebook page): got " .. tostring(#epub_hw))
    local by_page = {}
    local saw_chap_nb = false
    for __, h in ipairs(epub_hw) do
        if h.page then
            by_page[h.page] = h
        elseif h.chapter == "Chapter I" then
            saw_chap_nb = true
        end
    end
    T.check(saw_chap_nb, "4d: chapter notebook page extracted with Chapter I heading")
    T.check(by_page["9"] and #by_page["9"].drawing_strokes == 2,
        "4d: two strokes on same xp0 grouped into 1 SVG resolved via document:getPageFromXPointer to page 9")
    T.check(by_page["11"] and by_page["11"].chapter == "Chapter I",
        "4d: highlight handwritten note page matched to highlight p. 11 and Chapter I")
    T.check(by_page["22"] ~= nil,
        "4d: pinned reflowable page pg=22 extracted")

    -- 4e. Chapter resolution from Document TOC (PDF without text highlights),
    --     EPUB xpointer (sort_pos) precedence over shifted pageno, and
    --     Book notes chapter page sorting into its own chapter
    local mock_pdf_doc = {
        getToc = function()
            return {
                { page = 1,  depth = 1, title = "Preface" },
                { page = 5,  depth = 1, title = "1. Vector Spaces\13" },
                { page = 15, depth = 1, title = "2. Orthogonality" },
            }
        end,
    }
    local pdf_hw_toc = Export:cleanHandwritten(pdf_path, nil, nil, mock_pdf_doc)
    T.check(pdf_hw_toc[1] and pdf_hw_toc[1].chapter == "1. Vector Spaces"
            and pdf_hw_toc[2] and pdf_hw_toc[2].chapter == "2. Orthogonality",
        "4e: PDF without text highlights resolves chapter titles from document:getToc()")

    -- Test Confessions of Zeno scenario:
    -- Highlight in DocFragment[6] ("The Last Cigarette", p. 19),
    -- InkAway drawing in DocFragment[6]/p[145] (reflowed p. 21),
    -- Highlight in DocFragment[7] ("The Death of My Father", p. 21),
    -- plus Book notes chapter page for "The Death of My Father" (no pageno).
    local zeno_book = INK_WORK .. "/books/Zeno.epub"
    local zeno_sdr = zeno_book .. ".sdr"
    local zeno_nb = INK_WORK .. "/Book notes/Zeno.inkaway"
    util.makePath(zeno_sdr)
    writeBytes(zeno_nb, [[return {
        ["v"]=2,["w"]=1261,["h"]=688,
        ["pages"]={
            {
                ["id"]=1,
                ["title"]="The Death of My Father",
                ["book"]={["toc"]=7,},
                ["ops"]={
                    {["kind"]="ink",["width"]=4,["pts"]={10,10,50,50,},},
                    {["kind"]="text",["paras"]={{["spans"]={{["t"]="rtgfr",},},},},},
                },
            },
        },
    }]])
    writeBytes(zeno_sdr .. "/inkaway.lua", string.format([[return {
        ["version"]=1,
        ["notes"]=%q,
        ["items"]={
            {
                ["op"]={["kind"]="ink",["width"]=4,["pts"]={0,0,40,20,},},
                ["a"]={["xp0"]="/body/DocFragment[6]/body/section/p[145]/text().113",["xp1"]="/body/DocFragment[6]/body/section/p[145]/text().118",["dx"]=56,["dy"]=1,},
            },
        },
    }]], zeno_nb))
    local zeno_raw = {
        {
            drawer = "lighten",
            text = "I came back discouraged to the table.",
            chapter = "The Last Cigarette",
            page = "/body/DocFragment[6]/body/section/p[5]/text().0",
            pos0 = "/body/DocFragment[6]/body/section/p[5]/text().0",
            pos1 = "/body/DocFragment[6]/body/section/p[5]/text().37",
            pageno = 8,
            pageref = "8",
            datetime = "2026-11-26 00:08:47",
        },
        {
            drawer = "lighten",
            text = "For whoever it may interest let me explain.",
            chapter = "The Death of My Father",
            page = "/body/DocFragment[7]/body/section/p[2]/text()[1].0",
            pos0 = "/body/DocFragment[7]/body/section/p[2]/text()[1].0",
            pos1 = "/body/DocFragment[7]/body/section/p[2]/text()[2].200",
            pageno = 21,
            pageref = "21",
            datetime = "2026-11-26 00:09:18",
        },
    }
    local zeno_doc = {
        getPageFromXPointer = function(_, xp)
            if xp:find("DocFragment%[6%]") then return 21 end
            return nil
        end,
    }
    local zeno_anns = Export:cleanAnnotations(zeno_raw)
    local zeno_hw = Export:cleanHandwritten(zeno_book, nil, zeno_raw, zeno_doc)
    Export:assignHandwrittenChapters(zeno_hw, zeno_anns)
    T.check(zeno_hw[1].chapter == "The Last Cigarette"
            and zeno_hw[2].chapter == "The Death of My Father",
        "4e: DocFragment[6] drawing gets 'The Last Cigarette' via sort_pos despite pageno=21 tie with DocFragment[7]")
    for __, h in ipairs(zeno_hw) do
        zeno_anns[#zeno_anns + 1] = h
    end
    Export:sortAnnotations(zeno_anns)
    T.check(zeno_anns[1].chapter == "The Last Cigarette"
            and zeno_anns[2].chapter == "The Last Cigarette"
            and zeno_anns[3].chapter == "The Death of My Father"
            and zeno_anns[4].chapter == "The Death of My Father",
        "4e: Book notes chapter page sorts inside 'The Death of My Father' after 'The Last Cigarette' (no split chapters)")

    -- 4f. Regression: closed EPUB (unrendered CreDocument in DocumentRegistry)
    --     must NEVER call C++ getToc()/getPageFromXPointer() (SIGSEGV in libkoreader-cre.so+0x608aa),
    --     locked PDFs must not call getToc(), closed PDFs cache TOC once, and
    --     cached EPUB xpointer TOC resolves chapters after close even with zero highlights.
    writeBytes(zeno_book, "PK\3\4fake-epub")
    local cre_toc_called = false
    local cre_xp_called = false
    local locked_toc_called = false
    local locked_closed = false
    local pdf_open_count = 0
    local pdf_close_count = 0
    local closed_pdf = INK_WORK .. "/books/DraculaClosed.pdf"
    local closed_pdf_sdr = closed_pdf .. ".sdr"
    local locked_pdf = INK_WORK .. "/books/Locked.pdf"
    local locked_pdf_sdr = locked_pdf .. ".sdr"
    util.makePath(closed_pdf_sdr)
    util.makePath(locked_pdf_sdr)
    writeBytes(closed_pdf, "%PDF-1.4 fake")
    writeBytes(locked_pdf, "%PDF-1.4 locked")
    writeBytes(closed_pdf_sdr .. "/inkaway.lua", [[return {
        ["version"]=1,
        ["items"]={
            {["op"]={["kind"]="ink",["width"]=3,["pts"]={0,0,10,10,},},["a"]={["pg"]=4,["fx"]=0,["fy"]=0,},},
            {["op"]={["kind"]="ink",["width"]=3,["pts"]={0,0,10,10,},},["a"]={["pg"]=7,["fx"]=0,["fy"]=0,},},
        },
    }]])
    writeBytes(locked_pdf_sdr .. "/inkaway.lua", [[return {
        ["version"]=1,
        ["items"]={
            {["op"]={["kind"]="ink",["width"]=3,["pts"]={0,0,10,10,},},["a"]={["pg"]=2,["fx"]=0,["fy"]=0,},},
        },
    }]])

    local prev_dr = package.loaded["document/documentregistry"]
    package.loaded["document/documentregistry"] = {
        getProvider = function(_, path)
            if path:match("%.epub$") then
                return { loadDocument = function() end, info = { has_pages = false } }
            end
            return { info = { has_pages = true } }
        end,
        openDocument = function(_, path)
            if path:match("%.epub$") then
                return {
                    loadDocument = function() end,
                    been_rendered = false,
                    info = { has_pages = false },
                    getToc = function()
                        cre_toc_called = true
                        error("SIGSEGV in libkoreader-cre.so+0x608aa")
                    end,
                    close = function() end,
                }
            elseif path == locked_pdf then
                return {
                    is_locked = true,
                    info = { has_pages = true },
                    getToc = function()
                        locked_toc_called = true
                        return {}
                    end,
                    close = function()
                        locked_closed = true
                    end,
                }
            elseif path == closed_pdf then
                pdf_open_count = pdf_open_count + 1
                return {
                    is_locked = false,
                    info = { has_pages = true },
                    getToc = function()
                        return {
                            { page = 3, depth = 1, title = "Prefazione" },
                            { page = 6, depth = 1, title = "Capitolo I" },
                        }
                    end,
                    close = function()
                        pdf_close_count = pdf_close_count + 1
                    end,
                }
            end
            return nil
        end,
    }

    -- 4f.1: Closed EPUB on disk must not invoke getToc() on unloaded CreDocument
    local zeno_closed_hw = Export:cleanHandwritten(zeno_book, nil, zeno_raw, nil, nil)
    Export:assignHandwrittenChapters(zeno_closed_hw, Export:cleanAnnotations(zeno_raw))
    T.check(not cre_toc_called,
        "4f.1: closed EPUB on disk never calls getToc() on unloaded CreDocument")
    T.check(zeno_closed_hw[1].chapter == "The Last Cigarette"
            and zeno_closed_hw[2].chapter == "The Death of My Father",
        "4f.1: closed EPUB still resolves chapters from highlight DocFragments and Book notes")

    -- 4f.2: Unrendered live CreDocument passed directly must not invoke C++ getToc/getPageFromXPointer
    local unrendered_cre = {
        loadDocument = function() end,
        been_rendered = false,
        info = { has_pages = false },
        getToc = function() cre_toc_called = true; return {} end,
        getPageFromXPointer = function() cre_xp_called = true; return 5 end,
    }
    Export:cleanHandwritten(zeno_book, nil, zeno_raw, unrendered_cre, {
        fillToc = function() cre_toc_called = true end,
        getTocTitleByPage = function() cre_toc_called = true; return "Bad" end,
    })
    T.check(not cre_toc_called and not cre_xp_called,
        "4f.2: unrendered live CreDocument never triggers getToc, fillToc, or getPageFromXPointer")

    -- 4f.3: Password-locked PDF opened offscreen closes cleanly without calling getToc
    Export:cleanHandwritten(locked_pdf, nil, nil, nil, nil)
    T.check(not locked_toc_called and locked_closed,
        "4f.3: locked PDF opened via DocumentRegistry never calls getToc() and still closes")

    -- 4f.4: Closed PDF resolves chapters via DocumentRegistry once and caches TOC
    local drac1 = Export:cleanHandwritten(closed_pdf, nil, nil, nil, nil)
    local drac2 = Export:cleanHandwritten(closed_pdf, nil, nil, nil, nil)
    T.check(drac1[1].chapter == "Prefazione" and drac1[2].chapter == "Capitolo I"
            and drac2[1].chapter == "Prefazione" and drac2[2].chapter == "Capitolo I",
        "4f.4: closed PDF resolves Prefazione (p. 4) and Capitolo I (p. 7) without text highlights")
    T.check(pdf_open_count == 1 and pdf_close_count == 1,
        "4f.4: closed PDF TOC is cached after first lookup (open_count=" .. tostring(pdf_open_count) .. ")")

    -- 4f.5: Closed EPUB with zero text highlights resolves chapters after cacheBookToc on close
    local nohl_epub = INK_WORK .. "/books/NoHighlights.epub"
    local nohl_sdr = nohl_epub .. ".sdr"
    util.makePath(nohl_sdr)
    writeBytes(nohl_epub, "PK\3\4fake-epub-2")
    writeBytes(nohl_sdr .. "/inkaway.lua", [[return {
        ["version"]=1,
        ["items"]={
            {["op"]={["kind"]="ink",["width"]=3,["pts"]={0,0,10,10,},},["a"]={["xp0"]="/body/DocFragment[6]/body/section/p[145]/text().113",["dx"]=10,["dy"]=0,},},
            {["op"]={["kind"]="ink",["width"]=3,["pts"]={0,0,10,10,},},["a"]={["xp0"]="/body/DocFragment[7]/body/section/p[3]/text().700",["dx"]=10,["dy"]=0,},},
        },
    }]])
    local rendered_cre = {
        loadDocument = function() end,
        been_rendered = true,
        info = { has_pages = false },
        getToc = function()
            return {
                { page = 8,  depth = 1, title = "The Last Cigarette",     xpointer = "/body/DocFragment[6]/body/h1[1]" },
                { page = 21, depth = 1, title = "The Death of My Father", xpointer = "/body/DocFragment[7]/body/h1[1]" },
            }
        end,
    }
    T.check(type(Handwritten.cacheBookToc) == "function",
        "4f.5: Handwritten.cacheBookToc exists for caching live TOC before close")
    if type(Handwritten.cacheBookToc) == "function" then
        Handwritten.cacheBookToc(nohl_epub, rendered_cre, nil)
    end
    local nohl_hw = Export:cleanHandwritten(nohl_epub, nil, {}, nil, nil)
    T.check(nohl_hw[1] and nohl_hw[1].chapter == "The Last Cigarette"
            and nohl_hw[2] and nohl_hw[2].chapter == "The Death of My Father"
            and not cre_toc_called,
        "4f.5: closed EPUB with zero highlights resolves chapters from cached xpointer TOC without opening CreDocument")

    package.loaded["document/documentregistry"] = prev_dr

    -- 4g. Unified InkAway EPUB annotation grouping (arrow + box + multi-word "This"),
    --     multi-word horizontal spacing, two-note vertical separation, stable IDs +
    --     stale SVG cleanup, and full InkAway op fidelity (highlighter, breaks, fill_color, fill, sym, continuation pages)
    local arrow_epub = INK_WORK .. "/books/ArrowThis.epub"
    local arrow_sdr = arrow_epub .. ".sdr"
    util.makePath(arrow_sdr)
    writeBytes(arrow_sdr .. "/inkaway.lua", [[return {
        ["version"]=1,
        ["items"]={
            {["a"]={["dx"]=132,["dy"]=-1,["xp0"]="/body/DocFragment[7]/body/section/p[48]/text().421",["xp1"]="/body/DocFragment[7]/body/section/p[48]/text().426",},["op"]={["alpha"]=255,["color"]={0,0,0},["fill"]=false,["kind"]="shape",["pts"]={9.6,9.5,69.0,54.5},["shape"]="rect",["width"]=9,},},
            {["a"]={["dx"]=232,["dy"]=-25,["xp0"]="/body/DocFragment[7]/body/section/p[49]/text().28",["xp1"]="/body/DocFragment[7]/body/section/p[49]/text().38",},["op"]={["alpha"]=255,["arrow"]="end",["color"]={0,0,0},["fill"]=false,["head"]=39,["kind"]="shape",["pts"]={9.3,25.9,115.5,27.7},["shape"]="line",["width"]=9,},},
            {["a"]={["dx"]=387,["dy"]=-20,["xp0"]="/body/DocFragment[7]/body/section/p[49]/text().28",["xp1"]="/body/DocFragment[7]/body/section/p[49]/text().38",},["op"]={["alpha"]=255,["color"]={0,0,0},["kind"]="ink",["pts"]={9.1,9.2,18.0,25.0,27.1,42.5},["style"]="solid",["width"]=9,},},
            {["a"]={["dx"]=343,["dy"]=-5,["xp0"]="/body/DocFragment[7]/body/section/p[48]/text().421",["xp1"]="/body/DocFragment[7]/body/section/p[48]/text().426",},["op"]={["alpha"]=255,["color"]={0,0,0},["kind"]="ink",["pts"]={9.2,10.8,81.2,11.7},["style"]="solid",["width"]=9,},},
            {["a"]={["dx"]=427,["dy"]=2,["xp0"]="/body/DocFragment[7]/body/section/p[48]/text().421",["xp1"]="/body/DocFragment[7]/body/section/p[48]/text().426",},["op"]={["alpha"]=255,["color"]={0,0,0},["kind"]="ink",["pts"]={8.9,9.2,28.7,42.5},["style"]="solid",["width"]=9,},},
            {["a"]={["dy"]=-29,["mr"]=277,["xp0"]="/body/DocFragment[7]/body/section/p[49]/text().28",["xp1"]="/body/DocFragment[7]/body/section/p[49]/text().38",},["op"]={["alpha"]=255,["color"]={0,0,0},["kind"]="ink",["pts"]={29.8,9.2,22.6,40.7},["style"]="solid",["width"]=9,},},
        },
    }]])
    local arrow_doc = {
        loadDocument = function() return true end,
        been_rendered = true,
        info = { has_pages = false },
        getPageFromXPointer = function() return 57 end,
        gotoPage = function() end,
        getCurrentPage = function() return 1 end,
        getScreenWidth = function() return 1261 end,
        getScreenBoxesFromPositions = function(_, xp0)
            if xp0:find("p%[48%]") then
                return { { x = 109, y = 554, w = 49, h = 26 } }
            end
            return { { x = 326, y = 580, w = 98, h = 26 } }
        end,
    }
    local arrow_hw = Export:cleanHandwritten(arrow_epub, nil, {}, arrow_doc, nil)
    T.check(#arrow_hw == 1,
        "4g.1: rectangle + arrow + 'This' across p[48] & p[49] merge into 1 single annotation (got " .. tostring(#arrow_hw) .. ")")
    if arrow_hw[1] and arrow_hw[1].drawing_strokes then
        local st = arrow_hw[1].drawing_strokes
        -- rect (1) + arrow shaft & 2 barbs (3) + 4 letter strokes = 8 strokes
        T.check(#st == 8,
            "4g.1: unified annotation keeps all 8 vector strokes (rect, arrow shaft + 2 barbs, 'This' letters): got " .. tostring(#st))
        local rect_x = st[1].points[1].x
        local s_x = st[#st].points[1].x
        T.check(s_x > rect_x + 500,
            "4g.1: right-margin stroke 's' (mr=277 on W=1261) placed to the right of rectangle (s_x=" .. tostring(s_x) .. ", rect_x=" .. tostring(rect_x) .. ")")
    end
    local arrow_offline = Export:cleanHandwritten(arrow_epub, nil, {}, nil, nil)
    T.check(#arrow_offline == 1,
        "4g.1b: offline fallback also merges rectangle + arrow + 'This' across p[48]/p[49] into 1 single annotation (got " .. tostring(#arrow_offline) .. ")")

    -- 4g.2: Multi-word handwritten sentence across .16, .29, .39, .47 + h2 (dyb) merges into 1 annotation without piling letters at x=0
    local word_epub = INK_WORK .. "/books/MultiWord.epub"
    local word_sdr = word_epub .. ".sdr"
    util.makePath(word_sdr)
    writeBytes(word_sdr .. "/inkaway.lua", [[return {
        ["version"]=1,
        ["items"]={
            {["a"]={["dx"]=27,["dy"]=-54,["xp0"]="/body/DocFragment[8]/body/section/p[1]/text().16",["xp1"]="/body/DocFragment[8]/body/section/p[1]/text().22",},["op"]={["kind"]="ink",["pts"]={9,31,45,9},["width"]=9,},},
            {["a"]={["dx"]=-28,["dy"]=-61,["xp0"]="/body/DocFragment[8]/body/section/p[1]/text().29",["xp1"]="/body/DocFragment[8]/body/section/p[1]/text().34",},["op"]={["kind"]="ink",["pts"]={8,22,40,35},["width"]=9,},},
            {["a"]={["dx"]=-1,["dy"]=-65,["xp0"]="/body/DocFragment[8]/body/section/p[1]/text().39",["xp1"]="/body/DocFragment[8]/body/section/p[1]/text().43",},["op"]={["kind"]="ink",["pts"]={18,9,9,28},["width"]=9,},},
            {["a"]={["dx"]=0,["dy"]=-63,["xp0"]="/body/DocFragment[8]/body/section/p[1]/text().47",["xp1"]="/body/DocFragment[8]/body/section/p[1]/text().57",},["op"]={["kind"]="ink",["pts"]={9,9,58,44},["width"]=9,},},
            {["a"]={["dx"]=85,["dyb"]=20,["xp0"]="/body/DocFragment[8]/body/section/h2/text().16",["xp1"]="/body/DocFragment[8]/body/section/h2/text().24",},["op"]={["kind"]="ink",["pts"]={9,9,78,44},["width"]=9,},},
        },
    }]])
    local word_offline = Export:cleanHandwritten(word_epub, nil, {}, nil, nil)
    T.check(#word_offline == 1,
        "4g.2: multi-word sentence across .16/.29/.39/.47 + adjacent h2 merges into 1 annotation offline (got " .. tostring(#word_offline) .. ")")
    if word_offline[1] and word_offline[1].drawing_strokes and #word_offline[1].drawing_strokes >= 4 then
        local x_first = word_offline[1].drawing_strokes[1].points[1].x
        local x_fourth = word_offline[1].drawing_strokes[4].points[1].x
        T.check(x_fourth > x_first + 150,
            "4g.2: offline char-offset estimator spaces .47 well to the right of .16 (x1=" .. tostring(x_first) .. ", x4=" .. tostring(x_fourth) .. ")")
    end

    -- 4g.3: Two distinct margin notes far apart vertically on same PDF page (y=60 vs y=900) stay 2 separate annotations
    local two_pdf = INK_WORK .. "/books/TwoNotes.pdf"
    local two_sdr = two_pdf .. ".sdr"
    util.makePath(two_sdr)
    writeBytes(two_sdr .. "/inkaway.lua", [[return {
        ["version"]=1,
        ["items"]={
            {["a"]={["page"]=5,["x"]=40,["y"]=60,},["op"]={["kind"]="ink",["pts"]={0,0,50,15},["width"]=3,},},
            {["a"]={["page"]=5,["x"]=40,["y"]=900,},["op"]={["kind"]="ink",["pts"]={0,0,50,15},["width"]=3,},},
        },
    }]])
    local two_hw = Export:cleanHandwritten(two_pdf, nil, {}, nil, nil)
    T.check(#two_hw == 2,
        "4g.3: two notes 840px apart vertically on same page stay 2 separate compact annotations (got " .. tostring(#two_hw) .. ")")

    -- 4g.4: Stable reflowable drawing_id across page-number changes & orphan SVG cleanup
    local hw_p19 = Export:cleanHandwritten(arrow_epub, nil, {}, {
        loadDocument = function() return true end,
        been_rendered = true,
        getPageFromXPointer = function() return 19 end,
    }, nil)
    local hw_p41 = Export:cleanHandwritten(arrow_epub, nil, {}, {
        loadDocument = function() return true end,
        been_rendered = true,
        getPageFromXPointer = function() return 41 end,
    }, nil)
    local hw_closed = Export:cleanHandwritten(arrow_epub, nil, {}, nil, nil)
    T.check(hw_p19[1] and hw_p41[1] and hw_closed[1]
            and hw_p19[1].drawing_id == hw_p41[1].drawing_id
            and hw_p19[1].drawing_id == hw_closed[1].drawing_id,
        "4g.4: EPUB drawing_id stays identical across p.19 -> p.41 -> closed (" ..
        tostring(hw_p19[1] and hw_p19[1].drawing_id) .. " vs " .. tostring(hw_closed[1] and hw_closed[1].drawing_id) .. ")")

    local vault_dir = INK_WORK .. "/vault"
    util.makePath(vault_dir .. "/drawings")
    writeBytes(vault_dir .. "/drawings/ArrowThis - p19-1.svg", "<svg/>")
    writeBytes(vault_dir .. "/drawings/ArrowThis - note-8.svg", "<svg/>")
    writeBytes(vault_dir .. "/drawings/ArrowThis - Sequel - p1-1.svg", "<svg/>")
    Handwritten.ensureDrawings({ base = "ArrowThis", annotations = hw_p41 }, vault_dir, "drawings")
    T.check(lfs.attributes(vault_dir .. "/drawings/ArrowThis - p19-1.svg", "mode") == nil
            and lfs.attributes(vault_dir .. "/drawings/ArrowThis - note-8.svg", "mode") == nil
            and lfs.attributes(vault_dir .. "/drawings/ArrowThis - Sequel - p1-1.svg", "mode") == "file",
        "4g.4b: ensureDrawings removes stale drawings of same book while preserving neighbouring book titles")

    -- 4g.5: Highlighter translucency, eraser breaks, shape fill_color, paint-bucket fill, symmetry, and Book notes continuation page
    local rich_pdf = INK_WORK .. "/books/RichOps.pdf"
    local rich_sdr = rich_pdf .. ".sdr"
    local rich_nb = INK_WORK .. "/Book notes/RichOps.inkaway"
    util.makePath(rich_sdr)
    writeBytes(rich_nb, [[return {
        ["v"]=2,["w"]=200,["h"]=100,
        ["pages"]={
            {
                ["title"]="Chapter One",
                ["book"]={["toc"]=1,},
                ["ops"]={
                    {["kind"]="ink",["style"]="solid",["sym"]="vert",["width"]=3,["pts"]={10,10,30,30,},},
                },
            },
            {
                ["ops"]={
                    {["kind"]="fill",["color"]={50,110,220},["alpha"]=255,["runs"]={10,20,15,10,21,15},},
                },
            },
        },
    }]])
    writeBytes(rich_sdr .. "/inkaway.lua", string.format([[return {
        ["version"]=1,
        ["notes"]=%q,
        ["items"]={
            {["a"]={["page"]=1,["x"]=0,["y"]=0,},["op"]={["kind"]="ink",["style"]="highlighter",["color"]={255,235,59},["alpha"]=255,["width"]=28,["pts"]={10,20,120,20},},},
            {["a"]={["page"]=1,["x"]=0,["y"]=40,},["op"]={["kind"]="ink",["style"]="solid",["color"]={0,0,0},["alpha"]=255,["width"]=4,["breaks"]={3},["pts"]={10,10,30,10,80,10,100,10},},},
            {["a"]={["page"]=1,["x"]=0,["y"]=80,},["op"]={["kind"]="shape",["shape"]="rect",["fill"]=false,["fill_color"]={255,236,128},["color"]={38,38,38},["alpha"]=255,["width"]=3,["pts"]={10,10,60,40},},},
        },
    }]], rich_nb))
    local rich_hw = Export:cleanHandwritten(rich_pdf, nil, {}, nil, nil)
    Handwritten.ensureDrawings({ base = "RichOps", annotations = rich_hw }, vault_dir, "drawings")
    local rich_by_id = {}
    for __, rh in ipairs(rich_hw) do
        rich_by_id[rh.drawing_id] = rh
    end
    local p1_item = rich_by_id["p1-1"]
    local nb1_item = rich_by_id["nb-1"]
    local nb2_item = rich_by_id["nb-2"]
    local page1_svg = T.readFile(vault_dir .. "/" .. tostring(p1_item and p1_item.drawing))
    T.check(page1_svg and page1_svg:find('opacity="0.42"', 1, true) ~= nil,
        "4g.5a: highlighter stroke with alpha=255 renders with translucent opacity=0.42")
    T.check(page1_svg and not page1_svg:find("L 30 50 L 80 50", 1, true)
            and page1_svg:find("M 80 50", 1, true) ~= nil,
        "4g.5b: eraser-cut stroke (breaks={3}) splits into separate subpaths without bridging erased gap")
    T.check(page1_svg and page1_svg:find('fill="#ffec80"', 1, true) ~= nil
            and page1_svg:find('stroke="#262626"', 1, true) ~= nil,
        "4g.5c: sticker/bucket-filled shape renders both fill_color interior and stroke outline")
    T.check(nb1_item and nb1_item.chapter == "Chapter One" and #nb1_item.drawing_strokes == 2,
        "4g.5d: sym='vert' notebook stroke emits original + mirrored stroke")
    T.check(nb2_item and nb2_item.chapter == "Chapter One" and #nb2_item.drawing_strokes >= 1,
        "4g.5e: untagged Book notes continuation page inherits 'Chapter One' and exports flood-fill runs")

    T.rmrf(INK_WORK)
end

T.finish("test_handwritten")
