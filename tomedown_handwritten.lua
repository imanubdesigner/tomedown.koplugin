--[[
Handwritten & stylus annotations support for tomedown.koplugin.

Supports freehand notes, margin sketches, and stylus drawings created on
e-readers (Kindle Scribe, Kobo Libra Colour, Kobo Sage, Kobo Elipsa, Onyx Boox,
Android) via KOReader stylus plugins such as `ink-away.koplugin` (`inkaway.lua`
sidecar strokes, shapes, text boxes, and linked `.inkaway` book/highlight
notebooks), `pencil.koplugin` (raster PNG previews and bookmark entries inside
the book's `.sdr` sidecar directory), and `stylus-annotations.koplugin` (raw
vector stroke coordinates).

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
local toc_cache = {}

local function isDocTocReady(doc)
    if type(doc) ~= "table" or doc.is_locked then
        return false
    end
    -- CreDocument (`doc.loadDocument` exists, `doc.info.has_pages == false`)
    -- creates an unloaded C++ LVDocView in `init()`. Calling `getToc()` or
    -- `getPageFromXPointer()` before `render()` (`been_rendered == true`)
    -- dereferences a NULL pointer in `libkoreader-cre.so`.
    if doc.loadDocument ~= nil and not doc.been_rendered then
        return false
    end
    if type(doc.info) == "table" and doc.info.has_pages == false and not doc.been_rendered then
        return false
    end
    return true
end

local function tocCacheKey(file)
    if type(file) ~= "string" or file == "" then
        return nil
    end
    local attr = lfs.attributes(file)
    if type(attr) == "table" and attr.mode == "file" then
        return string.format("%s\31%s\31%s", file, tostring(attr.modification or 0), tostring(attr.size or 0))
    end
    return file
end

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

local function formatColor(c)
    if type(c) == "string" and c ~= "" then
        return c
    end
    if type(c) == "table" then
        local r, g, b = tonumber(c[1] or c.r), tonumber(c[2] or c.g), tonumber(c[3] or c.b)
        if r and g and b then
            r = math.max(0, math.min(255, math.floor(r + 0.5)))
            g = math.max(0, math.min(255, math.floor(g + 0.5)))
            b = math.max(0, math.min(255, math.floor(b + 0.5)))
            return string.format("#%02x%02x%02x", r, g, b)
        end
    end
    return "#1e1e1e"
end

--- Normalize a stroke entry into `{ points = { {x, y}, ... }, width = number, color = string, ... }`.
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
    local opacity = tonumber(stroke.opacity)
    if not opacity then
        local alpha = tonumber(stroke.alpha)
        if alpha and alpha > 0 and alpha < 255 then
            opacity = alpha / 255
        end
    end
    if opacity and (opacity <= 0 or opacity >= 0.995) then
        opacity = nil
    end
    return {
        points = pts,
        width = width,
        color = formatColor(stroke.color),
        opacity = opacity,
        closed = stroke.closed == true,
        fill = stroke.fill == true,
    }
end

local function fmtCoord(n)
    local rounded = math.floor(n * 10 + 0.5) / 10
    if rounded == math.floor(rounded) then
        return tostring(math.floor(rounded))
    end
    return string.format("%.1f", rounded)
end

local function adler32Hex(s)
    if type(s) ~= "string" or s == "" then
        return nil
    end
    local s1, s2 = 1, 0
    for i = 1, #s do
        s1 = (s1 + s:byte(i)) % 65521
        s2 = (s2 + s1) % 65521
    end
    return string.format("%04x%04x", s2, s1)
end

local function readFileBytes(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local bytes = f:read("*a")
    f:close()
    return bytes
end

--- Load a serialized Lua data table (`return { ... }`) in an empty-env sandbox
-- compatible with Lua 5.1, LuaJIT (including InkAway split-constant chunks), and Lua 5.4.
local function loadLuaData(str)
    if type(str) ~= "string" or str == "" or str:byte(1) == 27 then
        return nil
    end
    local chunk
    if setfenv and loadstring then
        chunk = loadstring(str, "inkaway")
        if chunk then
            setfenv(chunk, {})
        end
    else
        chunk = load(str, "inkaway", "t", {})
    end
    if not chunk then
        return nil
    end
    local ok, data = pcall(chunk)
    if ok and type(data) == "table" then
        return data
    end
    return nil
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
        local op_attr = s.opacity and string.format(' opacity="%.2f"', s.opacity) or ""
        if #s.points == 1 then
            local p = s.points[1]
            lines[#lines + 1] = string.format(
                '  <circle cx="%s" cy="%s" r="%s" fill="%s"%s/>',
                fmtCoord(p.x), fmtCoord(p.y), fmtCoord(s.width / 2), color, op_attr)
        else
            local d = { "M " .. fmtCoord(s.points[1].x) .. " " .. fmtCoord(s.points[1].y) }
            for i = 2, #s.points do
                d[#d + 1] = "L " .. fmtCoord(s.points[i].x) .. " " .. fmtCoord(s.points[i].y)
            end
            if s.closed and #s.points >= 3 then
                d[#d + 1] = "Z"
            end
            if s.fill and s.closed then
                lines[#lines + 1] = string.format(
                    '  <path d="%s" fill="%s" stroke="none"%s/>',
                    table.concat(d, " "), color, op_attr)
            else
                lines[#lines + 1] = string.format(
                    '  <path d="%s" fill="none" stroke="%s" stroke-width="%s" stroke-linecap="round" stroke-linejoin="round"%s/>',
                    table.concat(d, " "), color, w_str, op_attr)
            end
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

--- Convert an InkAway `op` (`ink-away.koplugin`) at offset `(ox, oy)` into
-- vector strokes or extracted text paragraphs.
local function flatPtsToPoints(flat, ox, oy)
    local pts = {}
    if type(flat) ~= "table" then
        return pts
    end
    for i = 1, #flat - 1, 2 do
        local x, y = tonumber(flat[i]), tonumber(flat[i + 1])
        if x and y then
            pts[#pts + 1] = { x = x + ox, y = y + oy }
        end
    end
    return pts
end

local function inkAwayShapeStrokes(op, ox, oy)
    local p = op.pts
    if type(p) ~= "table" or #p < 4 then
        return {}
    end
    local x0, y0, x1, y1 = tonumber(p[1]), tonumber(p[2]), tonumber(p[3]), tonumber(p[4])
    if not (x0 and y0 and x1 and y1) then
        return {}
    end
    local kind = op.shape
    local poly, closed = {}, true
    if kind == "line" then
        poly = { x0, y0, x1, y1 }
        closed = false
    elseif kind == "curve" then
        local cx = tonumber(p[5]) or (x0 + x1) / 2
        local cy = tonumber(p[6]) or (y0 + y1) / 2
        for i = 0, 24 do
            local t = i / 24
            local mt = 1 - t
            local a, b, c = mt * mt, 2 * mt * t, t * t
            poly[#poly + 1] = a * x0 + b * cx + c * x1
            poly[#poly + 1] = a * y0 + b * cy + c * y1
        end
        closed = false
    elseif kind == "rect" then
        local ax0, ay0 = math.min(x0, x1), math.min(y0, y1)
        local ax1, ay1 = math.max(x0, x1), math.max(y0, y1)
        poly = { ax0, ay0, ax1, ay0, ax1, ay1, ax0, ay1 }
    elseif kind == "triangle" then
        local ax0, ay0 = math.min(x0, x1), math.min(y0, y1)
        local ax1, ay1 = math.max(x0, x1), math.max(y0, y1)
        poly = { (ax0 + ax1) / 2, ay0, ax0, ay1, ax1, ay1 }
    elseif kind == "ellipse" then
        local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        local rx, ry = math.abs(x1 - x0) / 2, math.abs(y1 - y0) / 2
        local steps = math.max(24, math.min(64, math.floor(rx + ry)))
        for i = 0, steps - 1 do
            local a = (i / steps) * 2 * math.pi
            poly[#poly + 1] = cx + rx * math.cos(a)
            poly[#poly + 1] = cy + ry * math.sin(a)
        end
    elseif kind == "poly" then
        for i = 1, #p do
            poly[i] = tonumber(p[i]) or 0
        end
        closed = op.closed == true
    else
        return {}
    end

    local ang = tonumber(op.angle)
    if ang and ang ~= 0 and #poly >= 2 then
        local cx, cy
        if kind == "poly" then
            local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
            for i = 1, #poly - 1, 2 do
                if poly[i] < minx then minx = poly[i] end
                if poly[i] > maxx then maxx = poly[i] end
                if poly[i + 1] < miny then miny = poly[i + 1] end
                if poly[i + 1] > maxy then maxy = poly[i + 1] end
            end
            cx, cy = (minx + maxx) / 2, (miny + maxy) / 2
        else
            cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        end
        local ca, sa = math.cos(ang), math.sin(ang)
        for i = 1, #poly - 1, 2 do
            local dx, dy = poly[i] - cx, poly[i + 1] - cy
            poly[i] = cx + dx * ca - dy * sa
            poly[i + 1] = cy + dx * sa + dy * ca
        end
    end

    local pts = flatPtsToPoints(poly, ox, oy)
    if #pts == 0 then
        return {}
    end
    local color = formatColor(op.color)
    local width = tonumber(op.width) or 2
    local filled = (op.fill == true and closed)
    local out = {
        {
            points = pts,
            width = width,
            color = color,
            alpha = op.alpha,
            closed = closed,
            fill = filled,
        },
    }
    if not filled and (op.arrow == "end" or op.arrow == "both")
            and (kind == "line" or kind == "curve") and #poly >= 4 then
        local n = math.floor(#poly / 2)
        local head = tonumber(op.head) or math.max(12, width * 3)
        local ca, sa = math.cos(0.4887), math.sin(0.4887)
        local function addTip(txi, tyi, fxi, fyi)
            local tx, ty = poly[txi], poly[tyi]
            local dx, dy = tx - poly[fxi], ty - poly[fyi]
            local len = math.sqrt(dx * dx + dy * dy)
            if len < 1e-3 then
                return
            end
            dx, dy = dx / len, dy / len
            out[#out + 1] = {
                points = {
                    { x = tx + ox, y = ty + oy },
                    { x = tx - head * (dx * ca - dy * sa) + ox, y = ty - head * (dx * sa + dy * ca) + oy },
                },
                width = width,
                color = color,
                alpha = op.alpha,
            }
            out[#out + 1] = {
                points = {
                    { x = tx + ox, y = ty + oy },
                    { x = tx - head * (dx * ca + dy * sa) + ox, y = ty + head * (dx * sa - dy * ca) + oy },
                },
                width = width,
                color = color,
                alpha = op.alpha,
            }
        end
        addTip(2 * n - 1, 2 * n, 2 * n - 3, 2 * n - 2)
        if op.arrow == "both" then
            addTip(1, 2, 3, 4)
        end
    end
    return out
end

local function inkAwayExtractText(op)
    if type(op.paras) ~= "table" then
        return nil
    end
    local lines = {}
    for __, para in ipairs(op.paras) do
        if type(para) == "table" and type(para.spans) == "table" then
            local parts = {}
            for ___, span in ipairs(para.spans) do
                if type(span) == "table" and type(span.t) == "string" then
                    parts[#parts + 1] = span.t
                end
            end
            local line = trim(table.concat(parts))
            if line then
                lines[#lines + 1] = line
            end
        end
    end
    if #lines == 0 then
        return nil
    end
    return table.concat(lines, "\n")
end

local function inkAwayAppendOp(strokes, texts, op, ox, oy)
    if type(op) ~= "table" or op.hidden then
        return
    end
    local kind = op.kind
    if kind == "erase" or kind == "smudge" or kind == "link" or kind == "image" or kind == "fill" then
        return
    end
    if kind == "text" then
        local txt = inkAwayExtractText(op)
        if txt then
            texts[#texts + 1] = txt
        end
        return
    end
    if kind == "shape" then
        for __, s in ipairs(inkAwayShapeStrokes(op, ox, oy)) do
            strokes[#strokes + 1] = s
        end
        return
    end
    if (kind == nil or kind == "ink") and type(op.pts) == "table" and #op.pts >= 2 then
        local pts = flatPtsToPoints(op.pts, ox, oy)
        if #pts > 0 then
            strokes[#strokes + 1] = {
                points = pts,
                width = tonumber(op.width) or 2.5,
                color = formatColor(op.color),
                alpha = op.alpha,
            }
        end
    end
end

local function resolveInkAwayNotebookPath(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    if lfs.attributes(path, "mode") == "file" then
        return path
    end
    local roots = {}
    if G_reader_settings and type(G_reader_settings.readSetting) == "function" then
        local custom = G_reader_settings:readSetting("inkaway_library_dir")
        if type(custom) == "string" and custom ~= "" then
            roots[#roots + 1] = custom
        end
    end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage then
        if type(DataStorage.getDataDir) == "function" then
            roots[#roots + 1] = DataStorage:getDataDir() .. "/ink away"
        end
        if type(DataStorage.getSettingsDir) == "function" then
            roots[#roots + 1] = DataStorage:getSettingsDir() .. "/ink away"
        end
    end
    local leaf = path:match("([^/\\]+)$")
    for __, root in ipairs(roots) do
        if leaf then
            local in_bn = root .. "/Book notes/" .. leaf
            if lfs.attributes(in_bn, "mode") == "file" then
                return in_bn
            end
            local in_root = root .. "/" .. leaf
            if lfs.attributes(in_root, "mode") == "file" then
                return in_root
            end
        end
    end
    return nil
end

local function loadInkAwaySidecar(sdr_dir)
    if not sdr_dir then
        return nil, nil
    end
    for __, name in ipairs({ "inkaway.lua", "inkaway.lua.old" }) do
        local p = sdr_dir .. "/" .. name
        if lfs.attributes(p, "mode") == "file" then
            local data = loadLuaData(readFileBytes(p))
            if data and type(data.items) == "table" then
                return data, p
            end
        end
    end
    return nil, nil
end

local function collectInkAway(sdr_dir, raw, document, addEntry)
    local data, ink_path = loadInkAwaySidecar(sdr_dir)
    if not data then
        return
    end
    local mtime = ink_path and lfs.attributes(ink_path, "modification") or 0
    local fallback_dt = (mtime and mtime > 0) and os.date("%Y-%m-%d %H:%M:%S", mtime) or nil

    local groups, by_key = {}, {}
    local function getGroup(key, pageno, pos0)
        local g = by_key[key]
        if not g then
            g = { key = key, pageno = pageno or 0, pos0 = pos0, strokes = {}, texts = {} }
            by_key[key] = g
            groups[#groups + 1] = g
        end
        return g
    end

    for idx, item in ipairs(data.items) do
        if type(item) == "table" and type(item.op) == "table" and type(item.a) == "table" then
            local a = item.a
            local key, pageno, pos0, ox, oy = nil, 0, nil, 0, 0
            if type(a.page) == "number" then
                pageno = a.page
                key = "page:" .. tostring(pageno)
                ox = tonumber(a.x) or 0
                oy = tonumber(a.y) or 0
            elseif type(a.pg) == "number" then
                pageno = a.pg
                key = "pg:" .. tostring(pageno)
                ox = (tonumber(a.fx) or 0) * 800
                oy = (tonumber(a.fy) or 0) * 1200
            elseif a.room and not a.xp0 then
                key = "room:" .. tostring(a.room)
                ox = tonumber(a.rx) or 0
                oy = tonumber(a.ry) or 0
            elseif type(a.pxp) == "string" then
                pos0 = a.pxp
                key = "pxp:" .. pos0
                ox = tonumber(a.dx) or 0
                oy = tonumber(a.dy) or 0
            elseif type(a.xp0) == "string" then
                pos0 = ((tonumber(a.seg) or 1) > 1 and type(a.xp1) == "string") and a.xp1 or a.xp0
                key = "xp:" .. a.xp0
                ox = tonumber(a.dx) or tonumber(a.ml)
                    or (tonumber(a.mr) and (800 - tonumber(a.mr)))
                    or tonumber(a.rx) or 0
                oy = tonumber(a.dy)
                    or (tonumber(a.dyb) and (24 + tonumber(a.dyb)))
                    or tonumber(a.ry) or 0
            else
                key = "idx:" .. tostring(idx)
            end
            if pageno == 0 and pos0 and isDocTocReady(document) and type(document.getPageFromXPointer) == "function" then
                local ok_p, rp = pcall(document.getPageFromXPointer, document, pos0)
                if ok_p and tonumber(rp) and tonumber(rp) > 0 then
                    pageno = tonumber(rp)
                end
            end
            local g = getGroup(key, pageno, pos0)
            if g.pageno == 0 and pageno > 0 then
                g.pageno = pageno
            end
            inkAwayAppendOp(g.strokes, g.texts, item.op, ox, oy)
        end
    end

    for __, g in ipairs(groups) do
        if #g.strokes > 0 or #g.texts > 0 then
            local note = #g.texts > 0 and table.concat(g.texts, "\n") or nil
            addEntry({
                pageno = g.pageno,
                pos0 = g.pos0,
                datetime = fallback_dt,
                note = note,
            }, nil, #g.strokes > 0 and g.strokes or nil)
        end
    end

    -- Linked `.inkaway` book notebook (`data.notes`: chapter pages + highlight handwritten notes)
    local nb_path = resolveInkAwayNotebookPath(data.notes)
    if nb_path then
        local nb = loadLuaData(readFileBytes(nb_path))
        local pages = nb and (type(nb.pages) == "table" and nb.pages
            or (type(nb.ops) == "table" and { { ops = nb.ops } }))
        if type(pages) == "table" then
            local nb_mtime = lfs.attributes(nb_path, "modification") or 0
            local nb_dt = (nb_mtime and nb_mtime > 0) and os.date("%Y-%m-%d %H:%M:%S", nb_mtime) or fallback_dt
            local hl_by_dt, hl_by_pos = {}, {}
            if type(raw) == "table" then
                for __, r in ipairs(raw) do
                    if type(r) == "table" and not r.deleted then
                        if type(r.datetime) == "string" then
                            hl_by_dt[r.datetime] = r
                        end
                        if type(r.pos0) == "string" then
                            hl_by_pos[r.pos0] = r
                        end
                    end
                end
            end
            for __, pg in ipairs(pages) do
                if type(pg) == "table" and type(pg.ops) == "table" then
                    local strokes, texts = {}, {}
                    for ___, op in ipairs(pg.ops) do
                        inkAwayAppendOp(strokes, texts, op, 0, 0)
                    end
                    if #strokes > 0 or #texts > 0 then
                        local tag = type(pg.book) == "table" and pg.book or nil
                        local hl_tag = tag and type(tag.hl) == "table" and tag.hl or nil
                        local matched_hl = hl_tag and ((hl_tag.dt and hl_by_dt[hl_tag.dt])
                            or (hl_tag.pos0 and hl_by_pos[hl_tag.pos0])) or nil
                        local pos0 = (matched_hl and matched_hl.pos0)
                            or (hl_tag and type(hl_tag.pos0) == "string" and hl_tag.pos0) or nil
                        local pageno = matched_hl and (tonumber(matched_hl.pageno)
                            or (type(matched_hl.page) == "number" and matched_hl.page)) or 0
                        if pageno == 0 and pos0 and isDocTocReady(document) and type(document.getPageFromXPointer) == "function" then
                            local ok_p, rp = pcall(document.getPageFromXPointer, document, pos0)
                            if ok_p and tonumber(rp) and tonumber(rp) > 0 then
                                pageno = tonumber(rp)
                            end
                        end
                        local chapter = (matched_hl and trim(matched_hl.chapter))
                            or (not hl_tag and trim(pg.title)) or nil
                        local dt = (matched_hl and (matched_hl.datetime_updated or matched_hl.datetime))
                            or (hl_tag and type(hl_tag.dt) == "string" and hl_tag.dt)
                            or nb_dt
                        local note = #texts > 0 and table.concat(texts, "\n") or nil
                        addEntry({
                            pageno = pageno,
                            pos0 = pos0,
                            chapter = chapter,
                            toc_index = (not hl_tag and tag and tonumber(tag.toc)) or nil,
                            datetime = dt,
                            note = note,
                        }, nil, #strokes > 0 and strokes or nil)
                    end
                end
            end
        end
    end
end

local function cleanTocTitle(title)
    if type(title) ~= "string" then
        return nil
    end
    return trim(title:gsub("\13", ""))
end

local function lookupChapterInTocList(toc_list, pageno)
    local p = tonumber(pageno)
    if type(toc_list) ~= "table" or #toc_list == 0 or not p or p <= 0 then
        return nil
    end
    local prev_idx = nil
    for i, entry in ipairs(toc_list) do
        local ep = type(entry) == "table" and tonumber(entry.page) or nil
        if ep then
            if ep == p then
                prev_idx = i
                break
            elseif ep > p then
                break
            end
            prev_idx = i
        end
    end
    if prev_idx and toc_list[prev_idx] then
        return cleanTocTitle(toc_list[prev_idx].title)
    end
    return nil
end

local function xpTokens(s)
    local out = {}
    local i = 1
    while i <= #s do
        local d0, d1 = s:find("%d+", i)
        if not d0 then
            out[#out + 1] = { text = s:sub(i) }
            break
        end
        if d0 > i then
            out[#out + 1] = { text = s:sub(i, d0 - 1) }
        end
        out[#out + 1] = { num = tonumber(s:sub(d0, d1)) }
        i = d1 + 1
    end
    return out
end

local function xpCompare(a, b)
    local n = math.min(#a, #b)
    for k = 1, n do
        local x, y = a[k], b[k]
        if x.num and y.num then
            if x.num ~= y.num then
                return x.num < y.num and -1 or 1
            end
        elseif x.num or y.num then
            return x.num and -1 or 1
        elseif x.text ~= y.text then
            return x.text < y.text and -1 or 1
        end
    end
    if #a == #b then
        return 0
    end
    return #a < #b and -1 or 1
end

local function lookupChapterByXPointer(toc_list, pos0)
    if type(toc_list) ~= "table" or #toc_list == 0 or type(pos0) ~= "string" or pos0 == "" then
        return nil
    end
    local target_tok = xpTokens(pos0)
    local target_frag = tonumber(pos0:match("DocFragment%[(%d+)%]"))
    local prev_idx = nil
    local first_same_frag = nil
    local matched_same_frag = false
    for i, entry in ipairs(toc_list) do
        local xp = type(entry) == "table" and entry.xpointer or nil
        if type(xp) == "string" and xp ~= "" then
            local efrag = tonumber(xp:match("DocFragment%[(%d+)%]"))
            if target_frag and efrag then
                if efrag > target_frag then
                    break
                elseif efrag < target_frag then
                    prev_idx = i
                else
                    first_same_frag = first_same_frag or i
                    if xpCompare(xpTokens(xp), target_tok) <= 0 then
                        prev_idx = i
                        matched_same_frag = true
                    end
                end
            else
                if xpCompare(xpTokens(xp), target_tok) <= 0 then
                    prev_idx = i
                end
            end
        end
    end
    if target_frag and first_same_frag and not matched_same_frag then
        prev_idx = first_same_frag
    end
    if prev_idx and toc_list[prev_idx] then
        return cleanTocTitle(toc_list[prev_idx].title)
    end
    return nil
end

local function hasSidecarHandwrittenFiles(file)
    local sdr = handwritten.getSidecarDir(file)
    if not sdr then
        return false
    end
    if lfs.attributes(sdr .. "/inkaway.lua", "mode") == "file"
            or lfs.attributes(sdr .. "/inkaway.lua.old", "mode") == "file"
            or lfs.attributes(sdr .. "/pencil", "mode") == "directory"
            or lfs.attributes(sdr .. "/drawings", "mode") == "directory"
            or lfs.attributes(sdr .. "/stylus", "mode") == "directory" then
        return true
    end
    return #scanSdrDrawings(sdr) > 0
end

--- Cache a live book's Table of Contents in memory while its ReaderUI document
-- is still open and rendered, so delayed close-exports (`onCloseDocument`) or
-- FileManager batch exports can resolve EPUB xpointer chapters without ever
-- opening an unrendered `CreDocument` offscreen.
function handwritten.cacheBookToc(file, document, toc_module, opts)
    local key = tocCacheKey(file)
    if not key then
        return nil
    end
    if type(toc_module) == "table" and type(toc_module.toc) == "table" and #toc_module.toc > 0 then
        toc_cache[key] = toc_module.toc
        return toc_module.toc
    end
    if opts and opts.only_if_needed and not hasSidecarHandwrittenFiles(file) then
        return nil
    end
    local doc_ready = (document == nil) or isDocTocReady(document)
    if not doc_ready then
        return nil
    end
    if type(toc_module) == "table" and type(toc_module.fillToc) == "function" then
        pcall(toc_module.fillToc, toc_module)
        if type(toc_module.toc) == "table" and #toc_module.toc > 0 then
            toc_cache[key] = toc_module.toc
            return toc_module.toc
        end
    end
    if isDocTocReady(document) and type(document.getToc) == "function" then
        local ok_t, t = pcall(document.getToc, document)
        if ok_t and type(t) == "table" and #t > 0 then
            toc_cache[key] = t
            return t
        end
    end
    return nil
end

local function loadBookTocList(file, ds, document, toc_module)
    local cache_key = tocCacheKey(file)
    local toc_ready = (document == nil) or isDocTocReady(document)
    if toc_ready and type(toc_module) == "table" then
        if type(toc_module.fillToc) == "function" and type(toc_module.toc) ~= "table" then
            pcall(toc_module.fillToc, toc_module)
        end
        if type(toc_module.toc) == "table" and #toc_module.toc > 0 then
            if cache_key then
                toc_cache[cache_key] = toc_module.toc
            end
            return toc_module.toc
        end
    end
    if ds and type(ds.readSetting) == "function" then
        if ds:readSetting("handmade_toc_enabled") == true then
            local hm = ds:readSetting("handmade_toc")
            if type(hm) == "table" and #hm > 0 then
                return hm
            end
        end
    end
    if isDocTocReady(document) and type(document.getToc) == "function" then
        local ok_t, t = pcall(document.getToc, document)
        if ok_t and type(t) == "table" and #t > 0 then
            if cache_key then
                toc_cache[cache_key] = t
            end
            return t
        end
    end
    if cache_key and toc_cache[cache_key] ~= nil then
        return toc_cache[cache_key] or nil
    end
    if type(file) == "string" and file ~= "" and lfs.attributes(file, "mode") == "file" then
        local ok_dr, DocumentRegistry = pcall(require, "document/documentregistry")
        if ok_dr and DocumentRegistry and type(DocumentRegistry.openDocument) == "function" then
            local can_open_offscreen = true
            if type(DocumentRegistry.getProvider) == "function" then
                local ok_prov, prov = pcall(DocumentRegistry.getProvider, DocumentRegistry, file)
                if not ok_prov or type(prov) ~= "table"
                        or prov.loadDocument ~= nil
                        or (type(prov.info) == "table" and prov.info.has_pages == false) then
                    can_open_offscreen = false
                end
            end
            if can_open_offscreen then
                local ok_doc, temp_doc = pcall(DocumentRegistry.openDocument, DocumentRegistry, file)
                if ok_doc and temp_doc then
                    local ok_t, t = nil, nil
                    if isDocTocReady(temp_doc) and type(temp_doc.getToc) == "function" then
                        ok_t, t = pcall(temp_doc.getToc, temp_doc)
                    end
                    if type(temp_doc.close) == "function" then
                        pcall(temp_doc.close, temp_doc)
                    end
                    if ok_t and type(t) == "table" then
                        if cache_key then
                            toc_cache[cache_key] = (#t > 0) and t or false
                        end
                        if #t > 0 then
                            return t
                        end
                    end
                end
            end
        end
    end
    return nil
end

--- Collect all handwritten/stylus annotations for `file`.
-- @string file book file path
-- @tparam table|nil ds DocSettings instance
-- @tparam table|nil raw raw `annotations` table from DocSettings
-- @tparam table|nil document open KOReader document instance (optional, for xpointer page/TOC lookup)
-- @tparam table|nil toc_module open KOReader ReaderToc instance (`ui.toc`, optional)
-- @treturn table list of raw handwritten descriptors
function handwritten.collect(file, ds, raw, document, toc_module)
    local out = {}
    if not file and not ds and not raw then
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
        local w_num = tonumber(item.width or item.page_width or item.screen_width)
        local h_num = tonumber(item.height or item.page_height or item.screen_height)
        local digest
        if strokes then
            local preview_svg = handwritten.renderStrokesToSvg(strokes, w_num, h_num)
            digest = adler32Hex((preview_svg or "") .. "\31" .. tostring(user_note or ""))
        end
        out[#out + 1] = {
            pageno = pageno > 0 and pageno or nil,
            pageref = item.pageref or (pageno > 0 and tostring(pageno) or nil),
            page = item.page,
            pos0 = item.pos0,
            chapter = trim(item.chapter),
            toc_index = item.toc_index,
            datetime = datetime,
            datetime_updated = item.datetime_updated,
            note = user_note,
            special = item.tomedown_special or nil,
            drawing_source = img_file and img_file.path or nil,
            drawing_strokes = strokes,
            drawing_width = w_num,
            drawing_height = h_num,
            drawing_ext = ext,
            drawing_id = drawing_id,
            drawing_digest = digest,
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

    -- 4. InkAway (`ink-away.koplugin`) sidecar `<sdr>/inkaway.lua` + linked `.inkaway` notebooks
    collectInkAway(sdr_dir, raw, document, addEntry)

    -- 5. Resolve missing chapter titles (and TOC positions for chapter notebook pages)
    --    via live `toc_module:getTocTitleByPage`, `document:getToc()`, `handmade_toc`,
    --    cached TOC, or fixed-page `DocumentRegistry`
    local toc_ready = (document == nil) or isDocTocReady(document)
    local needs_toc_list = false
    for __, item in ipairs(out) do
        if not item.chapter and toc_ready and type(toc_module) == "table"
                and type(toc_module.getTocTitleByPage) == "function" then
            local target = (type(item.pos0) == "string" and item.pos0 ~= "") and item.pos0 or item.pageno
            if target then
                local ok_c, chap = pcall(toc_module.getTocTitleByPage, toc_module, target)
                local cleaned = ok_c and cleanTocTitle(chap) or nil
                if not cleaned and target ~= item.pageno and item.pageno then
                    ok_c, chap = pcall(toc_module.getTocTitleByPage, toc_module, item.pageno)
                    cleaned = ok_c and cleanTocTitle(chap) or nil
                end
                if cleaned then
                    item.chapter = cleaned
                end
            end
        end
        if (item.toc_index and (not item.chapter or (not item.pageno and not item.pos0)))
                or (not item.chapter and (item.pageno or (type(item.pos0) == "string" and item.pos0 ~= ""))) then
            needs_toc_list = true
        end
    end
    if needs_toc_list then
        local toc_list = loadBookTocList(file, ds, document, toc_module)
        if toc_list then
            for __, item in ipairs(out) do
                if item.toc_index and type(toc_list[item.toc_index]) == "table" then
                    local te = toc_list[item.toc_index]
                    if not item.chapter then
                        item.chapter = cleanTocTitle(te.title)
                    end
                    if not item.pageno and tonumber(te.page) and tonumber(te.page) > 0 then
                        item.pageno = tonumber(te.page)
                    end
                    if not item.pos0 and type(te.xpointer) == "string" and te.xpointer ~= "" then
                        item.pos0 = te.xpointer
                    end
                end
                if not item.chapter and type(item.pos0) == "string" and item.pos0 ~= "" then
                    item.chapter = lookupChapterByXPointer(toc_list, item.pos0)
                end
                if not item.chapter and item.pageno then
                    item.chapter = lookupChapterInTocList(toc_list, item.pageno)
                end
            end
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
            local target_dir = abs_target:match("^(.*)/[^/]+$")
            if a.drawing_source and lfs.attributes(a.drawing_source, "mode") == "file" then
                if not ok_file then
                    if target_dir then
                        util.makePath(target_dir)
                    end
                    ok_file = copyBinaryFile(a.drawing_source, abs_target)
                end
            elseif a.drawing_strokes then
                local svg = handwritten.renderStrokesToSvg(
                    a.drawing_strokes, a.drawing_width, a.drawing_height)
                if svg then
                    local existing = ok_file and readFileBytes(abs_target) or nil
                    if existing ~= svg then
                        if target_dir then
                            util.makePath(target_dir)
                        end
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
