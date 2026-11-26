--[[
Handwritten & stylus annotations support for tomedown.koplugin.

Supports freehand notes, margin sketches, and stylus drawings created on
e-readers (Kobo Libra Colour, Kobo Sage, Kobo Elipsa, Onyx Boox, Android)
via KOReader stylus plugins such as `pencil.koplugin` (raster PNG previews
and bookmark entries inside the book's `.sdr` sidecar directory) and
`stylus-annotations.koplugin` (raw vector stroke coordinates).

When an export runs:
1. `handwritten.collect` inspects the document settings and `.sdr` folder
   for freehand items (PNG previews or vector stroke tables).
2. `handwritten.ensureDrawings` copies the PNG previews or serializes vector
   strokes into lightweight, self-contained `.svg` files inside the vault's
   `drawings/` folder (or a custom folder chosen by the reader).
3. Uploaded drawing files follow the same transient rule as book covers:
   once uploaded to the cloud they are cleaned up from the local transfer
   buffer, while local-only setups keep them in the export folder.
]]

local DocSettings = require("docsettings")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local shared = require("tomedown_shared")
local util = require("util")

local handwritten = {}

local DEFAULT_FOLDER = "drawings"

local function trim(s)
    if type(s) ~= "string" then
        return nil
    end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then
        return nil
    end
    return s
end

--- Compute the sidecar `.sdr` directory path for `file`.
function handwritten.getSidecarDir(file)
    if type(file) ~= "string" or file == "" then
        return nil
    end
    if DocSettings and type(DocSettings.getSidecarDir) == "function" then
        local ok, sdr = pcall(DocSettings.getSidecarDir, DocSettings, file)
        if ok and type(sdr) == "string" and sdr ~= "" then
            if lfs.attributes(sdr, "mode") == "directory" then
                return sdr
            end
        end
    end
    local fallback = file .. ".sdr"
    if lfs.attributes(fallback, "mode") == "directory" then
        return fallback
    end
    local no_ext = file:gsub("%.[^%.%/]+$", "") .. ".sdr"
    if no_ext ~= fallback and lfs.attributes(no_ext, "mode") == "directory" then
        return no_ext
    end
    return nil
end

--- The relative path a drawing occupies inside the vault (POSIX "/").
-- @string book_leaf sanitized base filename of the book (without subdir)
-- @string drawing_id short identifier (e.g. "p42-1")
-- @string ext file extension ("png" or "svg")
-- @string folder target subfolder name (defaults to "drawings")
function handwritten.relPath(book_leaf, drawing_id, ext, folder)
    local sub = (type(folder) == "string" and folder ~= "") and folder or DEFAULT_FOLDER
    local clean_ext = (type(ext) == "string" and ext ~= "") and ext:gsub("^%.", "") or "png"
    local leaf = tostring(book_leaf or "book"):match("([^/]+)$") or "book"
    local id = tostring(drawing_id or "1"):gsub("[^%w_%-]", "-")
    return sub .. "/" .. leaf .. " - " .. id .. "." .. clean_ext
end

--- Is this absolute path an exported drawing inside `dir`?
function handwritten.isDrawingPath(path, dir, folder)
    local sub = (type(folder) == "string" and folder ~= "") and folder or DEFAULT_FOLDER
    local prefix = dir .. "/" .. sub .. "/"
    return type(path) == "string" and path:sub(1, #prefix) == prefix
end

--- Extract point coordinates `(x, y)` from either `{ x = 10, y = 20 }` or `{ 10, 20 }`.
local function pointXY(pt)
    if type(pt) ~= "table" then
        return nil, nil
    end
    local x = tonumber(pt.x or pt[1])
    local y = tonumber(pt.y or pt[2])
    if x and y then
        return x, y
    end
    return nil, nil
end

--- Normalize a stroke entry into `{ points = { {x, y}, ... }, width = number, color = string }`.
local function normalizeStroke(stroke)
    if type(stroke) ~= "table" then
        return nil
    end
    local raw_pts = type(stroke.points) == "table" and stroke.points
        or (type(stroke.path) == "table" and stroke.path)
        or stroke
    local pts = {}
    for __, pt in ipairs(raw_pts) do
        local x, y = pointXY(pt)
        if x and y then
            pts[#pts + 1] = { x = x, y = y }
        end
    end
    if #pts == 0 then
        return nil
    end
    local width = tonumber(stroke.width or stroke.size or stroke.stroke_width) or 2.5
    if width <= 0 then
        width = 2.5
    end
    local color = type(stroke.color) == "string" and stroke.color ~= "" and stroke.color or "#1e1e1e"
    return {
        points = pts,
        width = width,
        color = color,
    }
end

local function fmtCoord(n)
    local rounded = math.floor(n * 10 + 0.5) / 10
    if rounded == math.floor(rounded) then
        return tostring(math.floor(rounded))
    end
    return string.format("%.1f", rounded)
end

--- Serialize a list of vector strokes into a standalone SVG string.
-- Automatically computes a tight bounding box with padding when explicit
-- canvas dimensions (`width`, `height`) are not provided.
-- @tparam table strokes list of strokes
-- @tparam[opt] number width canvas width
-- @tparam[opt] number height canvas height
-- @treturn string|nil SVG document string, or nil when no valid points exist
function handwritten.renderStrokesToSvg(strokes, width, height)
    if type(strokes) ~= "table" or #strokes == 0 then
        return nil
    end
    local norm_strokes = {}
    local single = normalizeStroke(strokes)
    if single and type(strokes[1]) == "table" and (strokes[1].x ~= nil or type(strokes[1][1]) == "number") then
        -- `strokes` was passed as a single stroke's point array
        norm_strokes[1] = single
    else
        for __, s in ipairs(strokes) do
            local ns = normalizeStroke(s)
            if ns then
                norm_strokes[#norm_strokes + 1] = ns
            end
        end
    end
    if #norm_strokes == 0 then
        return nil
    end

    local min_x, min_y = math.huge, math.huge
    local max_x, max_y = -math.huge, -math.huge
    local max_w = 2.5
    for __, s in ipairs(norm_strokes) do
        if s.width > max_w then
            max_w = s.width
        end
        for __, pt in ipairs(s.points) do
            if pt.x < min_x then min_x = pt.x end
            if pt.y < min_y then min_y = pt.y end
            if pt.x > max_x then max_x = pt.x end
            if pt.y > max_y then max_y = pt.y end
        end
    end
    if min_x == math.huge then
        return nil
    end

    local pad = math.ceil(max_w * 2 + 12)
    local vx, vy, vw, vh
    if type(width) == "number" and width > 0 and type(height) == "number" and height > 0 then
        vx, vy = 0, 0
        vw, vh = math.ceil(width), math.ceil(height)
    else
        vx = math.floor(min_x - pad)
        vy = math.floor(min_y - pad)
        vw = math.max(32, math.ceil((max_x - min_x) + pad * 2))
        vh = math.max(32, math.ceil((max_y - min_y) + pad * 2))
    end

    local lines = {
        string.format(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="%d %d %d %d" width="%d" height="%d">',
            vx, vy, vw, vh, vw, vh),
    }
    for __, s in ipairs(norm_strokes) do
        local color = tostring(s.color):gsub('"', "")
        local w_str = fmtCoord(s.width)
        if #s.points == 1 then
            local p = s.points[1]
            lines[#lines + 1] = string.format(
                '  <circle cx="%s" cy="%s" r="%s" fill="%s"/>',
                fmtCoord(p.x), fmtCoord(p.y), fmtCoord(s.width / 2), color)
        else
            local d = { "M " .. fmtCoord(s.points[1].x) .. " " .. fmtCoord(s.points[1].y) }
            for i = 2, #s.points do
                d[#d + 1] = "L " .. fmtCoord(s.points[i].x) .. " " .. fmtCoord(s.points[i].y)
            end
            lines[#lines + 1] = string.format(
                '  <path d="%s" fill="none" stroke="%s" stroke-width="%s" stroke-linecap="round" stroke-linejoin="round"/>',
                table.concat(d, " "), color, w_str)
        end
    end
    lines[#lines + 1] = "</svg>\n"
    return table.concat(lines, "\n")
end

--- Resolve an image path (absolute or relative to `sdr_dir`) if it exists on disk.
local function resolveImageFile(img_path, sdr_dir)
    if type(img_path) ~= "string" or img_path == "" then
        return nil
    end
    if lfs.attributes(img_path, "mode") == "file" then
        return img_path
    end
    if sdr_dir then
        local in_sdr = sdr_dir .. "/" .. img_path:gsub("^[/\\]+", "")
        if lfs.attributes(in_sdr, "mode") == "file" then
            return in_sdr
        end
        local in_pencil = sdr_dir .. "/pencil/" .. img_path:gsub("^[/\\]+", "")
        if lfs.attributes(in_pencil, "mode") == "file" then
            return in_pencil
        end
    end
    return nil
end

--- Scan `sdr_dir` (and `sdr_dir/pencil`) for raster/vector drawing files.
-- Returns a sorted list of `{ path = abs_path, name = filename, page = page_or_nil, ext = ext }`.
local function scanSdrDrawings(sdr_dir)
    local found = {}
    if not sdr_dir or lfs.attributes(sdr_dir, "mode") ~= "directory" then
        return found
    end
    local function scanFolder(folder, require_prefix)
        if lfs.attributes(folder, "mode") ~= "directory" then
            return
        end
        local ok_iter, iter, obj = pcall(lfs.dir, folder)
        if not ok_iter or not iter then
            return
        end
        for entry in iter, obj do
            if entry ~= "." and entry ~= ".." then
                local lower = entry:lower()
                local ext = lower:match("%.(png)$") or lower:match("%.(svg)$") or lower:match("%.(jpg)$")
                if ext then
                    local is_pencil = not require_prefix
                        or lower:match("^pencil")
                        or lower:match("^drawing")
                        or lower:match("^stylus")
                        or lower:match("^handwritten")
                        or lower:match("^ink")
                    if is_pencil then
                        local full = folder .. "/" .. entry
                        if lfs.attributes(full, "mode") == "file" then
                            local pnum = tonumber(
                                lower:match("page[_%-]?(%d+)")
                                or lower:match("p(%d+)")
                                or lower:match("[_%-](%d+)"))
                            found[#found + 1] = {
                                path = full,
                                name = entry,
                                page = pnum,
                                ext = ext,
                                mtime = lfs.attributes(full, "modification") or 0,
                            }
                        end
                    end
                end
            end
        end
    end
    scanFolder(sdr_dir, true)
    scanFolder(sdr_dir .. "/pencil", false)
    scanFolder(sdr_dir .. "/drawings", false)
    scanFolder(sdr_dir .. "/stylus", false)
    table.sort(found, function(a, b)
        if (a.page or 0) ~= (b.page or 0) then
            return (a.page or 0) < (b.page or 0)
        end
        return a.name < b.name
    end)
    return found
end

--- Check if a bookmark/annotation note matches `pencil.koplugin`'s marker
-- ("Pencil annotation on page X").
function handwritten.isPencilBookmarkNote(text)
    if type(text) ~= "string" then
        return false
    end
    local lower = text:lower()
    return lower:match("^pencil annotation") ~= nil
        or lower:match("^handwritten annotation") ~= nil
        or lower:match("^stylus annotation") ~= nil
end

--- Collect all handwritten/stylus annotations for `file`.
-- @string file book file path
-- @tparam table ds DocSettings instance
-- @tparam table|nil raw raw `annotations` table from DocSettings
-- @treturn table list of raw handwritten descriptors
function handwritten.collect(file, ds, raw)
    local out = {}
    if not ds and not raw then
        return out
    end
    local sdr_dir = handwritten.getSidecarDir(file)
    local sdr_files = scanSdrDrawings(sdr_dir)
    local used_files = {}
    local seq_by_page = {}

    local function nextDrawingId(pageno)
        local p = tonumber(pageno) or 0
        seq_by_page[p] = (seq_by_page[p] or 0) + 1
        if p > 0 then
            return string.format("p%d-%d", p, seq_by_page[p])
        end
        return string.format("note-%d", seq_by_page[p])
    end

    local function findSdrFileForPage(pageno)
        local p = tonumber(pageno)
        for __, f in ipairs(sdr_files) do
            if not used_files[f.path] and p and f.page == p then
                used_files[f.path] = true
                return f
            end
        end
        return nil
    end

    local function addEntry(item, img_file, strokes)
        local pageno = tonumber(item.pageno)
            or (type(item.page) == "number" and item.page)
            or (img_file and img_file.page)
            or 0
        if pageno == 0 and type(item.text) == "string" then
            pageno = tonumber(item.text:match("page%s+(%d+)")) or 0
        end
        if pageno == 0 and type(item.note) == "string" then
            pageno = tonumber(item.note:match("page%s+(%d+)")) or 0
        end
        local datetime = item.datetime_updated or item.datetime
        if not datetime and img_file and img_file.mtime and img_file.mtime > 0 then
            datetime = os.date("%Y-%m-%d %H:%M:%S", img_file.mtime)
        end
        local raw_note = trim(item.note) or trim(item.notes)
        local raw_text = trim(item.text)
        if raw_note and handwritten.isPencilBookmarkNote(raw_note) then
            raw_note = nil
        end
        if raw_text and handwritten.isPencilBookmarkNote(raw_text) then
            raw_text = nil
        end
        -- If there is highlighted text alongside a note, keep both; if text is
        -- just a label and note is nil, treat text as user note only when it
        -- isn't the default placeholder.
        local user_note = raw_note or raw_text
        local ext = (img_file and img_file.ext) or "svg"
        local drawing_id = nextDrawingId(pageno)
        out[#out + 1] = {
            pageno = pageno,
            pageref = item.pageref or (pageno > 0 and tostring(pageno) or nil),
            page = item.page,
            pos0 = item.pos0,
            chapter = trim(item.chapter),
            datetime = datetime,
            datetime_updated = item.datetime_updated,
            note = user_note,
            special = item.tomedown_special or nil,
            drawing_source = img_file and img_file.path or nil,
            drawing_strokes = strokes,
            drawing_width = tonumber(item.width or item.page_width or item.screen_width),
            drawing_height = tonumber(item.height or item.page_height or item.screen_height),
            drawing_ext = ext,
            drawing_id = drawing_id,
        }
    end

    -- 1. Inspect items in `raw` (`annotations` table)
    if type(raw) == "table" then
        for __, item in ipairs(raw) do
            if type(item) == "table" and not item.deleted then
                local img_path = item.pencil_image or item.drawing or item.image or item.image_path
                local resolved = resolveImageFile(img_path, sdr_dir)
                local has_strokes = type(item.strokes) == "table" and #item.strokes > 0
                local is_pencil_drawer = item.drawer == "pencil" or item.drawer == "stylus" or item.handwritten == true
                local is_pencil_bm = not item.drawer
                    and (handwritten.isPencilBookmarkNote(item.note) or handwritten.isPencilBookmarkNote(item.text))

                if resolved then
                    used_files[resolved] = true
                    local ext = resolved:lower():match("%.([%w]+)$") or "png"
                    addEntry(item, { path = resolved, ext = ext }, nil)
                elseif has_strokes then
                    addEntry(item, nil, item.strokes)
                elseif is_pencil_drawer or is_pencil_bm then
                    local p = tonumber(item.pageno) or tonumber(item.page)
                        or tonumber(tostring(item.note or item.text or ""):match("page%s+(%d+)"))
                    local matched = findSdrFileForPage(p)
                    if matched then
                        addEntry(item, matched, nil)
                    elseif is_pencil_drawer and type(item.points) == "table" and #item.points > 0 then
                        addEntry(item, nil, { item })
                    end
                end
            end
        end
    end

    -- 2. Inspect dedicated stylus/pencil settings keys in DocSettings
    if ds and type(ds.readSetting) == "function" then
        local keys = { "pencil_annotations", "stylus_annotations", "pencil", "handwritten_notes", "strokes" }
        for __, key in ipairs(keys) do
            local tbl = ds:readSetting(key)
            if type(tbl) == "table" then
                -- Can be an array of annotation entries or a map keyed by page number
                local handled_array = false
                if #tbl > 0 then
                    for __, entry in ipairs(tbl) do
                        if type(entry) == "table" and not entry.deleted then
                            local img_path = entry.pencil_image or entry.image or entry.file or entry.path
                            local resolved = resolveImageFile(img_path, sdr_dir)
                            if resolved and not used_files[resolved] then
                                used_files[resolved] = true
                                local ext = resolved:lower():match("%.([%w]+)$") or "png"
                                addEntry(entry, { path = resolved, ext = ext }, nil)
                                handled_array = true
                            elseif type(entry.strokes) == "table" and #entry.strokes > 0 then
                                addEntry(entry, nil, entry.strokes)
                                handled_array = true
                            elseif type(entry.points) == "table" and #entry.points > 0 then
                                addEntry(entry, nil, { entry })
                                handled_array = true
                            end
                        end
                    end
                end
                if not handled_array then
                    local pages = {}
                    for k, v in pairs(tbl) do
                        local pnum = tonumber(k)
                        if pnum and type(v) == "table" then
                            pages[#pages + 1] = { p = pnum, val = v }
                        end
                    end
                    table.sort(pages, function(a, b) return a.p < b.p end)
                    for __, pv in ipairs(pages) do
                        local v = pv.val
                        local img_path = type(v.image) == "string" and v.image
                            or (type(v.file) == "string" and v.file)
                        local resolved = resolveImageFile(img_path, sdr_dir)
                        if resolved and not used_files[resolved] then
                            used_files[resolved] = true
                            local ext = resolved:lower():match("%.([%w]+)$") or "png"
                            addEntry({
                                pageno = pv.p,
                                chapter = v.chapter,
                                datetime = v.datetime,
                                note = v.note,
                            }, { path = resolved, ext = ext, page = pv.p }, nil)
                        elseif type(v.strokes) == "table" and #v.strokes > 0 then
                            addEntry({
                                pageno = pv.p,
                                chapter = v.chapter,
                                datetime = v.datetime,
                                note = v.note,
                                width = v.width,
                                height = v.height,
                            }, nil, v.strokes)
                        elseif #v > 0 and normalizeStroke(v[1]) then
                            addEntry({ pageno = pv.p }, nil, v)
                        end
                    end
                end
            end
        end
    end

    -- 3. Any remaining unmatched image files in `<sdr>/pencil` or `pencil_*.png`
    for __, f in ipairs(sdr_files) do
        if not used_files[f.path] then
            used_files[f.path] = true
            addEntry({ pageno = f.page or 0 }, f, nil)
        end
    end

    return out
end

local function copyBinaryFile(src, dst)
    if type(ffiUtil) == "table" and type(ffiUtil.copyFile) == "function" then
        local ok, res = pcall(ffiUtil.copyFile, src, dst)
        if ok and res == true and lfs.attributes(dst, "mode") == "file" then
            return true
        end
    end
    local f_in = io.open(src, "rb")
    if not f_in then
        return false
    end
    local bytes = f_in:read("*a")
    f_in:close()
    if not bytes then
        return false
    end
    local f_out = io.open(dst, "wb")
    if not f_out then
        return false
    end
    local written = f_out:write(bytes)
    f_out:close()
    return written ~= nil and written ~= false and lfs.attributes(dst, "mode") == "file"
end

--- Copy or serialize all handwritten drawings of `book` into `<dir>/<folder>/`.
-- Updates each handwritten annotation's `drawing` (vault-relative for the book
-- note, accounting for subfolder layout) and `drawing_vault_rel` (root-relative
-- for the Reading Digest).
-- @tparam table book built book table
-- @string dir local export root directory
-- @string folder target subfolder name (e.g. "drawings")
-- @treturn table list of absolute file paths written/present for cloud sync
function handwritten.ensureDrawings(book, dir, folder)
    local written = {}
    if type(book) ~= "table" or type(book.annotations) ~= "table" then
        return written
    end
    local sub = (type(folder) == "string" and folder ~= "") and folder or DEFAULT_FOLDER
    local base = tostring(book.base or "book")
    local leaf = base:match("([^/]+)$") or base
    local in_subdir = base:find("/", 1, true) ~= nil

    for __, a in ipairs(book.annotations) do
        if a.handwritten and a.drawing_id then
            local rel = handwritten.relPath(leaf, a.drawing_id, a.drawing_ext, sub)
            local abs_target = dir .. "/" .. rel
            local ok_file = lfs.attributes(abs_target, "mode") == "file"
            if not ok_file then
                local target_dir = abs_target:match("^(.*)/[^/]+$")
                if target_dir then
                    util.makePath(target_dir)
                end
                if a.drawing_source and lfs.attributes(a.drawing_source, "mode") == "file" then
                    ok_file = copyBinaryFile(a.drawing_source, abs_target)
                elseif a.drawing_strokes then
                    local svg = handwritten.renderStrokesToSvg(
                        a.drawing_strokes, a.drawing_width, a.drawing_height)
                    if svg then
                        local ok_w = util.writeToFile(svg, abs_target, true, false, true)
                        ok_file = ok_w == true and lfs.attributes(abs_target, "mode") == "file"
                    end
                end
            end
            if ok_file then
                a.drawing_vault_rel = rel
                a.drawing = in_subdir and ("../" .. rel) or rel
                written[#written + 1] = abs_target
            end
        end
    end
    return written
end

--- Remove uploaded drawing files from the local transfer buffer (same rule as covers).
function handwritten.deleteUploaded(paths, dir, folder)
    local removed = 0
    for __, path in ipairs(paths or {}) do
        if handwritten.isDrawingPath(path, dir, folder) and os.remove(path) then
            removed = removed + 1
            logger.info("tomedown: uploaded drawing removed:", path)
        end
    end
    return removed
end

--- Move an old drawings folder to the new folder name and remove the old directory.
function handwritten.migrateFolder(dir, old_folder, new_folder)
    local shared_with_covers = (old_folder == shared.getCoversFolder())
    local ok = shared.migrateAssetFolder(dir, old_folder, new_folder,
        function(entry)
            local ext = entry:lower():match("%.([^%.]+)$")
            if ext == "png" or ext == "svg" then
                return true
            end
            if not shared_with_covers and (ext == "jpg" or ext == "jpeg") then
                return true
            end
            return false
        end,
        copyBinaryFile)
    if ok then
        logger.info("tomedown: migrated drawings folder from", old_folder, "to", new_folder)
    end
    return ok
end

return handwritten
