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
    T.check(T.contains(md, "**NOTE:** *Margin arrow & star*"),
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
    shared.setDrawingsFolder("drawings")
    T.check(store.tomedown.drawings_folder == nil, "setting default folder clears key to nil")

    T.check(shared.getIncludeHandwritten() == true, "include_handwritten is enabled by default")
    shared.setBookStyleOverride("/book.epub", "include_handwritten", false)
    T.check(shared.getIncludeHandwritten("/book.epub") == false
            and shared.getIncludeHandwritten("/other.epub") == true,
        "per-book include_handwritten override works independently")
    shared.clearBookStyleOverrides("/book.epub")
end

T.finish("test_handwritten")
